import Foundation
import SVNCore

struct LocalActionTests {
    func testUndoAddKeepsSpecialNamedFilesAndUnrelatedChanges() async throws {
        let f = try ActionFixture(); defer { f.remove() }; try await f.prepare()
        let unusual = "新建 @/D:\\Local\\internal-nlog-AspNetCore.txt"
        try f.write("keep log\n", unusual); try f.write("keep other addition\n", "other-added.txt")
        try f.write("unrelated edit\n", "outside.txt")
        _ = try await f.client.add(at: f.wc, paths: ["新建 @", "other-added.txt"])
        let plan = try await f.client.prepareLocalAction(.undoAdd, at: f.wc, paths: [unusual])
        try await f.client.applyLocalAction(plan)
        try expect(try f.read(unusual) == "keep log\n")
        try expect(try f.read("outside.txt") == "unrelated edit\n")
        let status = try await f.client.status(at: f.wc)
        try expect(status.contains { $0.path == unusual && $0.item == "unversioned" })
        try expect(status.contains { $0.path == "other-added.txt" && $0.item == "added" })
        try expect(status.contains { $0.path == "新建 @" && $0.item == "added" })
        try expect(try f.youngest() == "1")
    }

    func testUndoAddedDirectoryIsRecursiveAndKeepsExtraFiles() async throws {
        let f = try ActionFixture(); defer { f.remove() }; try await f.prepare()
        try f.write("new one\n", "new dir/a.txt"); try f.write("new two\n", "new dir/nested/中文 @.txt")
        _ = try await f.client.add(at: f.wc, paths: ["new dir"])
        try f.write("not added\n", "new dir/extra.log")
        let plan = try await f.client.prepareLocalAction(.undoAdd, at: f.wc, paths: ["new dir", "new dir/a.txt"])
        try expect(plan.targets == ["new dir"] && plan.items.count == 4)
        try await f.client.applyLocalAction(plan)
        for (p, text) in ["new dir/a.txt": "new one\n", "new dir/nested/中文 @.txt": "new two\n", "new dir/extra.log": "not added\n"] { try expect(try f.read(p) == text) }
        let status = try await f.client.status(at: f.wc)
        try expect(status.contains { $0.path == "new dir" && $0.item == "unversioned" })
        try expect(!status.contains { $0.item == "added" })
    }

    func testUndoAddRejectsCommittedCopiedAndMovedItems() async throws {
        let f = try ActionFixture(); defer { f.remove() }; try await f.prepare()
        try f.write("local tracked edit\n", "outside.txt")
        _ = try f.svn(["copy", "--", "folder/a.txt@", "copied.txt"], at: f.wc)
        _ = try f.svn(["move", "--", "folder/b.txt@", "moved.txt"], at: f.wc)
        for target in ["outside.txt", "copied.txt", "moved.txt"] {
            try await actionMustFail { _ = try await f.client.prepareLocalAction(.undoAdd, at: f.wc, paths: [target]) }
        }
        try expect(try f.read("outside.txt") == "local tracked edit\n")
        try expect(try f.read("copied.txt") == "base a\n")
        try expect(try f.read("moved.txt") == "base b\n")
    }

    func testDeleteKeepsModifiedAndUntrackedFilesUntilAndAfterCommit() async throws {
        let f = try ActionFixture(); defer { f.remove() }; try await f.prepare()
        try f.write("keep modified\n", "folder/a.txt"); try f.write("keep extra\n", "folder/extra.log")
        try f.write("unrelated change\n", "outside.txt")
        let plan = try await f.client.prepareLocalAction(.delete, at: f.wc, paths: ["folder"])
        try expect(plan.items.count == 3 && plan.modifiedCount == 1)
        try await f.client.applyLocalAction(plan, keepLocal: true)
        try expect(try f.read("folder/a.txt") == "keep modified\n")
        try expect(try f.read("folder/extra.log") == "keep extra\n")
        try expect(try f.youngest() == "1", "Scheduling deletion must not contact or change the repository")
        let status = try await f.client.status(at: f.wc)
        try expect(status.contains { $0.path == "folder" && $0.item == "deleted" })
        _ = try await f.client.commitWithProgress(at: f.wc, paths: plan.targets, message: "remove folder only") { _ in }
        let remote = try await f.client.list(url: f.repo.absoluteString)
        try expect(!remote.contains { $0.name == "folder" })
        try expect(try f.read("folder/a.txt") == "keep modified\n" && f.read("folder/extra.log") == "keep extra\n")
        try expect(try f.read("outside.txt") == "unrelated change\n")
    }

    func testDeleteCanRemoveCleanFilesButNeverForcesLocalChanges() async throws {
        let f = try ActionFixture(); defer { f.remove() }; try await f.prepare()
        let clean = try await f.client.prepareLocalAction(.delete, at: f.wc, paths: ["clean.txt"])
        try await f.client.applyLocalAction(clean, keepLocal: false)
        try expect(!FileManager.default.fileExists(atPath: f.wc.appendingPathComponent("clean.txt").path))
        try f.write("do not lose local changes\n", "outside.txt")
        let dirty = try await f.client.prepareLocalAction(.delete, at: f.wc, paths: ["outside.txt"])
        try await actionMustFail { try await f.client.applyLocalAction(dirty, keepLocal: false) }
        try expect(try f.read("outside.txt") == "do not lose local changes\n")
        try f.write("untracked retained\n", "folder/extra.txt")
        let directory = try await f.client.prepareLocalAction(.delete, at: f.wc, paths: ["folder"])
        try await actionMustFail { try await f.client.applyLocalAction(directory, keepLocal: false) }
        try expect(try f.read("folder/a.txt") == "base a\n" && f.read("folder/extra.txt") == "untracked retained\n")
        try expect(try f.youngest() == "1")
    }

    func testRevalidationBoundariesAndCancellationPreventWrites() async throws {
        let f = try ActionFixture(); defer { f.remove() }; try await f.prepare()
        for path in [".", "..", "../outside.txt", "/tmp/file", ".svn/entries", "folder//a.txt"] {
            try await actionMustFail { _ = try await f.client.prepareLocalAction(.delete, at: f.wc, paths: [path]) }
        }
        let outside = f.root.appendingPathComponent("outside"); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.wc.appendingPathComponent("link"), withDestinationURL: outside)
        try await actionMustFail { _ = try await f.client.prepareLocalAction(.delete, at: f.wc, paths: ["link/file.txt"]) }
        try f.write("first\n", "new/a.txt"); _ = try await f.client.add(at: f.wc, paths: ["new"])
        let plan = try await f.client.prepareLocalAction(.undoAdd, at: f.wc, paths: ["new"])
        try f.write("added after review\n", "new/b.txt"); _ = try await f.client.add(at: f.wc, paths: ["new/b.txt"])
        try await actionMustFail { try await f.client.applyLocalAction(plan) }
        let current = try await f.client.prepareLocalAction(.undoAdd, at: f.wc, paths: ["new"])
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; try await f.client.applyLocalAction(current) }
        do { try await task.value; throw CheckFailure.failed("Cancelled action must stop before writing") }
        catch is CancellationError { }
        let status = try await f.client.status(at: f.wc)
        try expect(status.contains { $0.path == "new/b.txt" && $0.item == "added" })
        try expect(try f.read("new/a.txt") == "first\n" && f.read("new/b.txt") == "added after review\n")
    }

    func testFailedLocalWriteIsNotReplayed() async throws {
        let f = try ActionFixture(); defer { f.remove() }; try await f.prepare()
        try f.write("keep addition\n", "new.txt"); _ = try await f.client.add(at: f.wc, paths: ["new.txt"])
        let marker = f.root.appendingPathComponent("write-calls"), wrapper = f.root.appendingPathComponent("svn-wrapper")
        let script = "#!/bin/sh\nif [ \"$1\" = revert ]; then printf x >> \(actionQuote(marker.path)); exit 1; fi\nexec \(actionQuote(f.binary)) \"$@\"\n"
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let client = SVNClient(executablePath: wrapper.path)
        let plan = try await client.prepareLocalAction(.undoAdd, at: f.wc, paths: ["new.txt"])
        try await actionMustFail { try await client.applyLocalAction(plan) }
        try expect(try String(contentsOf: marker, encoding: .utf8) == "x")
        try expect(try f.read("new.txt") == "keep addition\n")
    }

    func testCommitFailureCategoriesPreserveSpecificDiagnostics() throws {
        let values: [(String, SVNCommitFailureKind, Bool)] = [
            ("svn: E155011: file.txt out of date\nsvn: E160013: path not found", .outOfDate, true),
            ("svn: E170013: session failure\nsvn: E215004: authentication failed", .authorization, true),
            ("svn: E175013: forbidden", .authorization, true), ("svn: E165001: pre-commit hook failed", .hook, true),
            ("svn: E155015: conflict file.txt", .conflict, true), ("svn: E160013: path missing", .missingPath, true),
            ("svn: E160037: lock token", .locked, true), ("svn: E155004: working copy locked", .workingCopy, true),
            ("svn: E125001: invalid filename", .invalidPath, true), ("svn: E175002: Connection reset by peer", .network, false),
            ("svn: E165007: post-commit hook failed", .postCommit, false), ("svn: E999999: unexpected error", .unknown, false),
            ("svn: E000013: local access denied", .localFile, false)
        ]
        for (detail, kind, rejected) in values {
            let result = SVNCommitFailure.diagnose(SVNError.command(1, detail))
            try expect(result.kind == kind && result.definitelyRejected == rejected)
            try expect(result.details.contains(detail))
            if kind != .network { try expect(!(result.errorDescription ?? "").contains("网络中断")) }
        }
    }

    func testRealOutOfDateAndHookRejectionsAreSpecificAndKeepChanges() async throws {
        let f = try ActionFixture(); defer { f.remove() }; try await f.prepare()
        let peer = f.root.appendingPathComponent("peer")
        _ = try f.svn(["checkout", "--", f.repo.absoluteString, peer.path])
        try "remote\n".write(to: peer.appendingPathComponent("clean.txt"), atomically: true, encoding: .utf8)
        _ = try f.svn(["commit", "-m", "remote", "--", "clean.txt@"], at: peer)
        try f.write("local\n", "clean.txt")
        do {
            _ = try await f.client.commitWithProgress(at: f.wc, paths: ["clean.txt"], message: "must reject") { _ in }
            throw CheckFailure.failed("Out-of-date commit must fail")
        } catch let error as SVNCommitFailure { try expect(error.kind == .outOfDate && error.details.contains("clean.txt")) }
        let hook = f.repo.appendingPathComponent("hooks/pre-commit")
        try "#!/bin/sh\nprintf '%s\\n' 'fixture policy: issue number required; token=synthetic-hook-token' >&2\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        try f.write("local outside\n", "outside.txt")
        do {
            _ = try await f.client.commitWithProgress(at: f.wc, paths: ["outside.txt"], message: "must reject hook") { _ in }
            throw CheckFailure.failed("Hook rejection must fail")
        } catch let error as SVNCommitFailure {
            try expect(error.kind == .hook && error.details.contains("issue number required"))
            try expect(!error.details.contains("synthetic-hook-token"))
        }
        try expect(try f.read("clean.txt") == "local\n" && f.read("outside.txt") == "local outside\n")
        try expect(try f.youngest() == "2")
    }

    func testInvalidCommitListsFilesAndMissingAddedParentsBeforeSending() async throws {
        let f = try ActionFixture(); defer { f.remove() }; try await f.prepare()
        try f.write("untracked\n", "new.txt")
        do {
            _ = try await f.client.commitWithProgress(at: f.wc, paths: ["new.txt"], message: "invalid") { _ in }
            throw CheckFailure.failed("Unversioned file must not be committed")
        } catch let error as SVNCommitSelectionFailure { try expect(error.localizedDescription.contains("new.txt") && error.localizedDescription.contains("未跟踪")) }
        try f.write("new child\n", "added/child.txt"); _ = try await f.client.add(at: f.wc, paths: ["added"])
        do {
            _ = try await f.client.commitWithProgress(at: f.wc, paths: ["added/child.txt"], message: "missing parent") { _ in }
            throw CheckFailure.failed("Missing added parent must fail before sending")
        } catch let error as SVNCommitSelectionFailure { try expect(error.localizedDescription.contains("父目录") && error.localizedDescription.contains("added")) }
        try expect(try f.youngest() == "1")
    }

    func testConfirmedRevisionWithPostCommitWarningIsNotReportedAsRejected() async throws {
        let f = try ActionFixture(); defer { f.remove() }
        let wrapper = f.root.appendingPathComponent("mock-svn"), marker = f.root.appendingPathComponent("calls")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$1" >> \(actionQuote(marker.path))
        case "$1" in
          status) printf '%s' '<status><target path="."><entry path="file.txt"><wc-status item="modified" props="none"/></entry></target></status>' ;;
          commit) printf 'Sending file.txt\\nCommitted revision 9.\\n'; printf 'svn: E165007: post-commit hook failed\\n' >&2; exit 1 ;;
          *) exit 90 ;;
        esac
        """
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let events = ActionEventBox()
        let result = try await SVNClient(executablePath: wrapper.path).commitWithProgress(at: f.root, paths: ["file.txt"], message: "fixture") { events.append($0) }
        try expect(result.revision == "9")
        try expect(events.values.contains { if case .notice = $0 { return true }; return false })
        try expect(try String(contentsOf: marker, encoding: .utf8).split(separator: "\n").map(String.init) == ["status", "commit"])
    }
}

private final class ActionEventBox: @unchecked Sendable {
    private let lock = NSLock(); private var storage: [SVNOperationEvent] = []
    func append(_ event: SVNOperationEvent) { lock.lock(); defer { lock.unlock() }; storage.append(event) }
    var values: [SVNOperationEvent] { lock.lock(); defer { lock.unlock() }; return storage }
}

private func actionMustFail(_ action: () async throws -> Void) async throws {
    do { try await action(); throw CheckFailure.failed("Expected action to stop without writing") }
    catch let error as CheckFailure { throw error }
    catch { }
}

struct ActionFixture {
    let root: URL
    let binary: String
    var repo: URL { root.appendingPathComponent("repository") }
    var wc: URL { root.appendingPathComponent("working copy @") }
    var client: SVNClient { SVNClient(executablePath: binary, globalIgnoreConfigurationFiles: []) }
    init() throws {
        binary = try require(SVNClient.locateExecutable())
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SVNLocalActionChecks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func write(_ text: String, _ path: String) throws {
        let file = wc.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }
    func read(_ path: String) throws -> String { try String(contentsOf: wc.appendingPathComponent(path), encoding: .utf8) }
    func prepare() async throws {
        let admin = URL(fileURLWithPath: binary).deletingLastPathComponent().appendingPathComponent("svnadmin")
        _ = try process(admin.path, ["create", repo.path])
        let seed = root.appendingPathComponent("seed")
        for (path, text) in ["folder/a.txt": "base a\n", "folder/b.txt": "base b\n", "clean.txt": "base clean\n", "outside.txt": "base outside\n"] {
            let file = seed.appendingPathComponent(path); try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        _ = try svn(["import", "-m", "fixture", "--", seed.path, repo.absoluteString])
        _ = try svn(["checkout", "--", repo.absoluteString, wc.path])
    }
    func youngest() throws -> String {
        try process(URL(fileURLWithPath: binary).deletingLastPathComponent().appendingPathComponent("svnlook").path, ["youngest", repo.path]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    @discardableResult func svn(_ arguments: [String], at directory: URL? = nil) throws -> String {
        try process(binary, ["--non-interactive", "--no-auth-cache"] + arguments, at: directory)
    }
    private func process(_ executable: String, _ arguments: [String], at directory: URL? = nil) throws -> String {
        let task = Process(); task.executableURL = URL(fileURLWithPath: executable); task.arguments = arguments; task.currentDirectoryURL = directory
        let stdout = Pipe(), stderr = Pipe(); task.standardOutput = stdout; task.standardError = stderr; task.standardInput = FileHandle.nullDevice
        try task.run(); let output = stdout.fileHandleForReading.readDataToEndOfFile(); let errors = stderr.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw CheckFailure.failed("Fixture command failed: \(String(decoding: errors, as: UTF8.self))") }
        return String(decoding: output, as: UTF8.self)
    }
}

private func actionQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
