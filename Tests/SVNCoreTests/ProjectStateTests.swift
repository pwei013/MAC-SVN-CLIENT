import Darwin
import Foundation
import SVNCore

struct ProjectStateTests {
    func testRoundTripIsolatesCheckoutScopeAndSwitchedURL() async throws {
        let fixture = try ProjectStateFixture()
        defer { fixture.remove() }
        let store = SVNProjectStateStore(directory: fixture.storeDirectory)
        let one = try fixture.identity("working copy/中文 @", suffix: "trunk")
        let same = try SVNProjectIdentity(directory: fixture.root.appendingPathComponent("working copy/中文 @/child/.."),
            repositoryRootURL: "HTTPS://svn.example.invalid:443/repos/", directoryURL: "https://svn.example.invalid/repos/trunk/")
        try expect(one == same)
        let missing = try await store.load(identity: one)
        try expect(missing == nil && !FileManager.default.fileExists(atPath: fixture.storeDirectory.path),
                   "A missing-state read must not create storage")
        let state = SVNProjectState(commitMessage: "修复中文问题\n保留草稿", checkedPaths: [".", "src/中文 @文件.cs", "other.txt"],
                                    changeSearch: "中文", changeSelection: "src/中文 @文件.cs")
        let saved = try await store.save(state, identity: one)
        try expect(saved)
        let roundtrip = try await SVNProjectStateStore(directory: fixture.storeDirectory).load(identity: same)
        try expect(roundtrip == state, "A new actor instance must restore the entire state")
        for different in [try fixture.identity("another checkout", suffix: "trunk"),
                          try fixture.identity("working copy/中文 @/sub", suffix: "trunk/sub"),
                          try fixture.identity("working copy/中文 @", suffix: "branches/another")] {
            let absent = try await store.load(identity: different)
            try expect(absent == nil, "A different checkout, selected scope, or switched URL must not inherit a draft")
        }
    }

    func testMonotonicSavesAndCancellationDoNotOverwriteNewerDraft() async throws {
        let fixture = try ProjectStateFixture()
        defer { fixture.remove() }
        let store = SVNProjectStateStore(directory: fixture.storeDirectory)
        let identity = try fixture.identity("wc")
        let newest = SVNProjectState(commitMessage: "newest", checkedPaths: ["fresh.cs"])
        let accepted = try await store.save(newest, identity: identity, sequence: 42)
        let old = try await store.save(SVNProjectState(commitMessage: "old"), identity: identity, sequence: 41)
        let duplicate = try await store.save(SVNProjectState(commitMessage: "duplicate"), identity: identity, sequence: 42)
        try expect(accepted && !old && !duplicate)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.save(SVNProjectState(commitMessage: "cancelled"), identity: identity, sequence: 43)
        }
        do { _ = try await cancelled.value; throw CheckFailure.failed("A cancelled save must stop") }
        catch is CancellationError { }
        let restored = try await store.load(identity: identity)
        try expect(restored == newest)
        // Sequence numbers are session-local: a fresh store accepts a new sequence.
        let freshStore = SVNProjectStateStore(directory: fixture.storeDirectory)
        let fresh = try await freshStore.save(SVNProjectState(commitMessage: "new session"), identity: identity, sequence: 1)
        try expect(fresh)
    }

    func testCorruptionAndOversizeFallBackWithoutTruncatingExistingDraft() async throws {
        let fixture = try ProjectStateFixture()
        defer { fixture.remove() }
        let store = SVNProjectStateStore(directory: fixture.storeDirectory)
        let identity = try fixture.identity("wc")
        let original = SVNProjectState(commitMessage: "preserve")
        _ = try await store.save(original, identity: identity)
        let file = try fixture.singleRecord()
        let originalData = try Data(contentsOf: file)
        for invalid in [SVNProjectState(commitMessage: String(repeating: "x", count: 128 * 1_024 + 1)),
                        SVNProjectState(checkedPaths: ["../outside"]),
                        SVNProjectState(changeSelection: ".svn/wc.db"),
                        SVNProjectState(changeSearch: String(repeating: "x", count: 8_193))] {
            do { _ = try await store.save(invalid, identity: identity); throw CheckFailure.failed("Oversize or invalid state must be rejected") }
            catch let error as CheckFailure { throw error }
            catch is SVNError { }
            try expect(try Data(contentsOf: file) == originalData, "Validation must precede replacing an existing draft")
        }
        try Data("invalid JSON".utf8).write(to: file)
        let corrupt = try await store.load(identity: identity)
        try expect(corrupt == nil)
        try Data(repeating: 65, count: 512 * 1_024 + 1).write(to: file)
        let tooLarge = try await store.load(identity: identity)
        try expect(tooLarge == nil, "An oversized file must be rejected before unbounded reading")
        _ = try await store.save(original, identity: identity)
        var value = try require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var encodedIdentity = try require(value["identity"] as? [String: Any])
        encodedIdentity["directoryURL"] = "https://svn.example.invalid/repos/branches/foreign"
        value["identity"] = encodedIdentity
        try JSONSerialization.data(withJSONObject: value).write(to: file)
        let mismatched = try await store.load(identity: identity)
        try expect(mismatched == nil, "The full persisted mapping must be checked, not only its hashed filename")
    }

    func testRetentionKeepsRecentProjectsAndUnrelatedFiles() async throws {
        let fixture = try ProjectStateFixture()
        defer { fixture.remove() }
        let store = SVNProjectStateStore(directory: fixture.storeDirectory, maximumProjects: 2)
        let a = try fixture.identity("a"), b = try fixture.identity("b"), c = try fixture.identity("c")
        _ = try await store.save(SVNProjectState(commitMessage: "a"), identity: a)
        let aFile = try fixture.singleRecord()
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: aFile.path)
        let unrelated = fixture.storeDirectory.appendingPathComponent("keep.txt")
        try Data("unrelated".utf8).write(to: unrelated)
        let arbitraryJSON = fixture.storeDirectory.appendingPathComponent(String(repeating: "a", count: 64) + ".json")
        try Data("{\"unrelated\":true}".utf8).write(to: arbitraryJSON)
        _ = try await store.save(SVNProjectState(commitMessage: "b"), identity: b)
        _ = try await store.save(SVNProjectState(commitMessage: "c"), identity: c)
        let aState = try await store.load(identity: a), bState = try await store.load(identity: b), cState = try await store.load(identity: c)
        try expect(aState == nil && bState?.commitMessage == "b" && cState?.commitMessage == "c")
        try expect(try String(contentsOf: unrelated, encoding: .utf8) == "unrelated")
        try expect(try String(contentsOf: arbitraryJSON, encoding: .utf8) == "{\"unrelated\":true}")
        let filenames = try FileManager.default.contentsOfDirectory(atPath: fixture.storeDirectory.path)
        try expect(!filenames.contains { $0.hasPrefix(".pending-") }, "Atomic staging files must be removed")
    }

    func testPrivatePermissionsAndSymlinkProtection() async throws {
        let fixture = try ProjectStateFixture()
        defer { fixture.remove() }
        let identity = try fixture.identity("wc")
        let state = SVNProjectState(commitMessage: "private draft")
        let store = SVNProjectStateStore(directory: fixture.storeDirectory)
        _ = try await store.save(state, identity: identity)
        let file = try fixture.singleRecord()
        try expect((try FileManager.default.attributesOfItem(atPath: fixture.storeDirectory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        try expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let outside = fixture.root.appendingPathComponent("outside.txt")
        try Data("outside unchanged".utf8).write(to: outside)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        let linked = try await store.load(identity: identity)
        try expect(linked == nil, "State reads must not follow a record symlink")
        _ = try await store.save(state, identity: identity)
        try expect(try String(contentsOf: outside, encoding: .utf8) == "outside unchanged")
        try expect((try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType) == .typeRegular)
        let linkedDirectory = fixture.root.appendingPathComponent("linked-directory")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: fixture.storeDirectory)
        let unsafeStore = SVNProjectStateStore(directory: linkedDirectory)
        do { _ = try await unsafeStore.save(state, identity: identity); throw CheckFailure.failed("A symlink store directory must be rejected") }
        catch let error as CheckFailure { throw error }
        catch is SVNError { }
    }

    func testLargeSelectionAndSerializedRecordBudget() async throws {
        let fixture = try ProjectStateFixture()
        defer { fixture.remove() }
        let identity = try fixture.identity("wc")
        let store = SVNProjectStateStore(directory: fixture.storeDirectory)
        let paths = Set((0..<2_000).map { "src/目录 \($0)/file.cs" })
        let state = SVNProjectState(commitMessage: "large selection", checkedPaths: paths)
        _ = try await store.save(state, identity: identity)
        let restored = try await store.load(identity: identity)
        try expect(restored == state)
        let file = try fixture.singleRecord()
        let original = try Data(contentsOf: file)
        // Individually valid paths can still exceed the aggregate JSON budget.
        let enormous = Set((0..<2_000).map { "src/\($0)-" + String(repeating: "x", count: 300) + ".cs" })
        do {
            _ = try await store.save(SVNProjectState(checkedPaths: enormous), identity: identity)
            throw CheckFailure.failed("The aggregate serialized size must be bounded")
        } catch let error as CheckFailure { throw error }
        catch is SVNError { }
        try expect(try Data(contentsOf: file) == original)
    }

    func testIdentityRejectsCredentialsAndForeignRepositoryMapping() throws {
        let fixture = try ProjectStateFixture()
        defer { fixture.remove() }
        for (root, location) in [("https://user:password@svn.example.invalid/repos", "https://svn.example.invalid/repos/trunk"),
                                 ("https://svn.example.invalid/repos", "https://svn.example.invalid/other/trunk"),
                                 ("https://svn.example.invalid/repos", "https://svn.example.invalid/repos/../foreign")] {
            try expectThrows(SVNError.self) {
                try SVNProjectIdentity(directory: fixture.root.appendingPathComponent("wc"), repositoryRootURL: root, directoryURL: location)
            }
        }
    }
}

private struct ProjectStateFixture {
    let root: URL
    var storeDirectory: URL { root.appendingPathComponent("ProjectStates", isDirectory: true) }
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("svn-project-state-checks-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func identity(_ local: String, suffix: String = "trunk") throws -> SVNProjectIdentity {
        try SVNProjectIdentity(directory: root.appendingPathComponent(local, isDirectory: true),
            repositoryRootURL: "https://svn.example.invalid/repos", directoryURL: "https://svn.example.invalid/repos/" + suffix)
    }
    func singleRecord() throws -> URL {
        let records = try FileManager.default.contentsOfDirectory(at: storeDirectory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        try expect(records.count == 1)
        return try require(records.first)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
