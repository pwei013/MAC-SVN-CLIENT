import Foundation
import SVNCore

struct AutomaticCommitTests {
    func testMixedSelectionAddsNewTreesAndPreservesEverythingElse() async throws {
        let f = try ActionFixture(); defer { f.remove() }; try await f.prepare()
        try f.write("selected edit\n", "clean.txt"); try f.write("unselected edit\n", "outside.txt")
        for (name, value) in ["auto tree/中文 @.cs": "new source\n", "auto tree/nested/child.cs": "child\n",
                              "auto tree/skip-auto/file.cs": "ignored dir\n", "auto tree/cache.autotmp": "ignored file\n",
                              " new @.txt": "leading space\n", "preadded.txt": "unselected addition\n"] { try f.write(value, name) }
        _ = try await f.client.add(at: f.wc, paths: ["preadded.txt"])
        let client = SVNClient(executablePath: f.binary, additionalGlobalIgnores: ["skip-auto", "*.autotmp"], globalIgnoreConfigurationFiles: [])
        let events = AutomaticEvents()
        let result = try await client.commitIncludingUnversionedWithProgress(at: f.wc,
            paths: ["clean.txt", "auto tree", "auto tree/中文 @.cs", " new @.txt"], message: "mixed batch") { event in events.append(event) }
        try expect(result.revision == "2" && Set(result.paths) == ["clean.txt", "auto tree", "auto tree/中文 @.cs", "auto tree/nested", "auto tree/nested/child.cs", " new @.txt"])
        let remote = try f.svn(["list", "--recursive", "--", f.repo.absoluteString + "@"])
        try expect(remote.contains("中文 @.cs") && remote.contains("nested/child.cs") && remote.contains(" new @.txt"))
        try expect(!remote.contains("skip-auto") && !remote.contains("autotmp") && !remote.contains("preadded"))
        try expect(try f.svn(["cat", "--", f.repo.appendingPathComponent("outside.txt").absoluteString + "@"]) == "base outside\n")
        try expect(try f.read("auto tree/cache.autotmp") == "ignored file\n" && f.read("outside.txt") == "unselected edit\n")
        let after = try await client.status(at: f.wc)
        try expect(after.contains { $0.path == "preadded.txt" && $0.item == "added" })
        let rows = events.value.flatMap { event -> [SVNOperationRecord] in if case .output(let rows, _) = event { return rows }; return [] }
        try expect(rows.contains { $0.action == "Add" && $0.path == " new @.txt" })
        try expect(rows.contains { $0.action == "发送" && $0.path == "clean.txt" })
        try expect(Set(rows.map(\.id)).count == rows.count, "Add and upload rows must not reuse IDs")
        try expect(!events.value.contains { if case .notice = $0 { return true }; return false }, "Normal preparation is not a warning")
    }

    func testOnlyRequiredParentsAreIncludedForAnExplicitNewFile() async throws {
        let f = try ActionFixture(); defer { f.remove() }; try await f.prepare()
        try f.write("selected\n", "new-parent/nested/selected.cs")
        try f.write("keep sibling\n", "new-parent/nested/sibling.cs")
        try f.write("keep other\n", "new-parent/other.cs")
        let result = try await f.client.commitIncludingUnversionedWithProgress(at: f.wc,
            paths: ["new-parent/nested/selected.cs"], message: "one new file") { _ in }
        try expect(Set(result.paths) == ["new-parent", "new-parent/nested", "new-parent/nested/selected.cs"])
        let remote = try f.svn(["list", "--recursive", "--", f.repo.absoluteString + "@"])
        try expect(remote.contains("selected.cs") && !remote.contains("sibling.cs") && !remote.contains("other.cs"))
        let after = try await f.client.status(at: f.wc)
        try expect(after.contains { $0.path.hasSuffix("sibling.cs") && $0.item == "unversioned" })
        try expect(try f.read("new-parent/other.cs") == "keep other\n")
    }

    func testAlreadyAddedParentsDoNotPullInUnselectedAddedSiblings() async throws {
        let f = try ActionFixture(); defer { f.remove() }; try await f.prepare()
        try f.write("selected\n", "prior-add/selected.cs"); try f.write("unselected\n", "prior-add/sibling.cs")
        _ = try await f.client.add(at: f.wc, paths: ["prior-add"])
        let result = try await f.client.commitIncludingUnversionedWithProgress(at: f.wc,
            paths: ["prior-add/selected.cs"], message: "existing addition") { _ in }
        try expect(Set(result.paths) == ["prior-add", "prior-add/selected.cs"])
        let after = try await f.client.status(at: f.wc)
        try expect(after.contains { $0.path == "prior-add/sibling.cs" && $0.item == "added" })
        try expect(try f.youngest() == "2")
    }

    func testIgnoredAndMissingSelectionsStopBeforeAnyAddOrCommit() async throws {
        let f = try ActionFixture(); defer { f.remove() }; try await f.prepare()
        try f.write("new file\n", "ready.cs"); try f.write("ignored\n", "ignore-auto/nested.cs")
        let client = SVNClient(executablePath: f.binary, additionalGlobalIgnores: ["ignore-auto"], globalIgnoreConfigurationFiles: [])
        do {
            _ = try await client.commitIncludingUnversionedWithProgress(at: f.wc, paths: ["ready.cs", "ignore-auto/nested.cs"], message: "blocked") { _ in }
            throw CheckFailure.failed("Ignored ancestor must block automatic Add")
        } catch let error as SVNCommitSelectionFailure { try expect(error.localizedDescription.contains("上级目录")) }
        try FileManager.default.removeItem(at: f.wc.appendingPathComponent("clean.txt"))
        do {
            _ = try await client.commitIncludingUnversionedWithProgress(at: f.wc, paths: ["ready.cs", "clean.txt"], message: "blocked") { _ in }
            throw CheckFailure.failed("Missing selection must block automatic Add")
        } catch let error as SVNCommitSelectionFailure { try expect(error.paths.contains("clean.txt")) }
        let after = try await f.client.status(at: f.wc)
        try expect(!after.contains { $0.item == "added" } && f.youngest() == "1")
    }

    func testPartialAddFailureIsNotReplayedAndNeverStartsCommit() async throws {
        let f = try ActionFixture(); defer { f.remove() }; try await f.prepare(); try f.write("keep\n", "new.cs")
        let log = f.root.appendingPathComponent("calls"), wrapper = f.root.appendingPathComponent("svn-auto-wrapper")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$1" >> \(autoQuote(log.path))
        if [ "$1" = add ]; then
            \(autoQuote(f.binary)) "$@"
            printf 'svn: E200000: simulated Add failure\\n' >&2
            exit 1
        fi
        exec \(autoQuote(f.binary)) "$@"
        """
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let client = SVNClient(executablePath: wrapper.path, globalIgnoreConfigurationFiles: [])
        do {
            _ = try await client.commitIncludingUnversionedWithProgress(at: f.wc, paths: ["new.cs"], message: "should stop") { _ in }
            throw CheckFailure.failed("Partial Add failure must stop")
        } catch let failure as SVNAutomaticCommitFailure {
            try expect(!failure.additionCompleted && failure.localizedDescription.contains("尚未提交"))
        }
        let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        try expect(calls.filter { $0 == "add" }.count == 1 && !calls.contains("commit"))
        try expect(try f.read("new.cs") == "keep\n" && f.youngest() == "1")
        let after = try await f.client.status(at: f.wc)
        try expect(after.contains { $0.path == "new.cs" && $0.item == "added" })
    }

    func testRejectedCommitKeepsAddAndReportsTheExpandedScope() async throws {
        let f = try ActionFixture(); defer { f.remove() }; try await f.prepare()
        try f.write("new\n", "reject-new/nested.cs"); try f.write("edit\n", "clean.txt")
        let hook = f.repo.appendingPathComponent("hooks/pre-commit")
        try "#!/bin/sh\nprintf 'fixture hook rejects commit\\n' >&2\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        do {
            _ = try await f.client.commitIncludingUnversionedWithProgress(at: f.wc, paths: ["reject-new", "clean.txt"], message: "rejected") { _ in }
            throw CheckFailure.failed("Hook must reject")
        } catch let failure as SVNAutomaticCommitFailure {
            try expect(failure.additionCompleted && Set(failure.paths) == ["reject-new", "reject-new/nested.cs", "clean.txt"])
            try expect((failure.underlying as? SVNCommitFailure)?.kind == .hook)
        }
        try expect(try f.youngest() == "1" && f.read("reject-new/nested.cs") == "new\n")
        let after = try await f.client.status(at: f.wc)
        try expect(after.contains { $0.path == "reject-new/nested.cs" && $0.item == "added" })
    }

    func testCancellationAndSymlinkParentDoNotWrite() async throws {
        let f = try ActionFixture(); defer { f.remove() }; try await f.prepare(); try f.write("new\n", "new.cs")
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await f.client.commitIncludingUnversionedWithProgress(at: f.wc, paths: ["new.cs"], message: "cancelled") { _ in }
        }
        do { _ = try await cancelled.value; throw CheckFailure.failed("Cancelled before write") }
        catch is CancellationError { }
        let outside = f.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "outside\n".write(to: outside.appendingPathComponent("file.cs"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: f.wc.appendingPathComponent("link"), withDestinationURL: outside)
        do {
            _ = try await f.client.commitIncludingUnversionedWithProgress(at: f.wc, paths: ["link/file.cs"], message: "blocked") { _ in }
            throw CheckFailure.failed("Symlink parent must stop")
        } catch is SVNError { }
        try expect(try f.youngest() == "1" && f.read("new.cs") == "new\n")
    }

    func testInheritedNativeIgnoresApplyInsideNewParentsAndTrees() async throws {
        let f = try ActionFixture(); defer { f.remove() }; try await f.prepare()
        _ = try f.svn(["propset", "svn:global-ignores", "*.autonative", "--", ".@"], at: f.wc)
        try f.write("ignored leaf\n", "fresh-parent/file.autonative")
        do {
            _ = try await f.client.commitIncludingUnversionedWithProgress(at: f.wc,
                paths: ["fresh-parent/file.autonative"], message: "must stop") { _ in }
            throw CheckFailure.failed("Native ignore must be rechecked after creating an empty parent")
        } catch let failure as SVNAutomaticCommitFailure {
            try expect(!failure.additionCompleted && failure.localizedDescription.contains("被忽略"))
        }
        let partial = try await f.client.status(at: f.wc, showIgnored: true)
        try expect(partial.contains { $0.path == "fresh-parent/file.autonative" && $0.item == "ignored" })
        try expect(try f.youngest() == "1" && f.read("fresh-parent/file.autonative") == "ignored leaf\n")
        try f.write("include\n", "native-tree/include.cs"); try f.write("skip\n", "native-tree/skip.autonative")
        let result = try await f.client.commitIncludingUnversionedWithProgress(at: f.wc,
            paths: ["native-tree"], message: "only nonignored contents") { _ in }
        try expect(Set(result.paths) == ["native-tree", "native-tree/include.cs"])
        let remote = try f.svn(["list", "--recursive", "--", f.repo.absoluteString + "@"])
        try expect(!remote.contains("fresh-parent") && !remote.contains("skip.autonative"))
    }

    func testNestedWorkingCopyIsNeverSweptIntoTheNewTree() async throws {
        let f = try ActionFixture(); defer { f.remove() }; try await f.prepare()
        try f.write("selected\n", "mixed-tree/include.cs")
        let nested = f.wc.appendingPathComponent("mixed-tree/foreign")
        _ = try f.svn(["checkout", "--", f.repo.absoluteString, nested.path])
        do {
            _ = try await f.client.commitIncludingUnversionedWithProgress(at: f.wc, paths: ["mixed-tree"], message: "outer tree") { _ in }
        } catch let failure as SVNAutomaticCommitFailure {
            try expect(!failure.additionCompleted, "A nested checkout may reject Add, never enter remote commit")
        }
        let remote = try f.svn(["list", "--recursive", "--", f.repo.absoluteString + "@"])
        try expect(!remote.contains("foreign"))
        try expect(FileManager.default.fileExists(atPath: nested.appendingPathComponent(".svn/wc.db").path))
        try expect(try String(contentsOf: nested.appendingPathComponent("clean.txt"), encoding: .utf8) == "base clean\n")
    }
}

private func autoQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

private final class AutomaticEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SVNOperationEvent] = []
    func append(_ event: SVNOperationEvent) { lock.lock(); defer { lock.unlock() }; storage.append(event) }
    var value: [SVNOperationEvent] { lock.lock(); defer { lock.unlock() }; return storage }
}
