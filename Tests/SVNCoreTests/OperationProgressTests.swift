import Foundation
import Darwin
import SVNCore

struct OperationProgressTests {
    func testUpdateStreamsFilesAndReadsLocalAuthorsInBatches() async throws {
        let f = try OperationFixture(); defer { f.remove() }
        try await f.prepare()
        try f.write("remote update\n", f.writer.appendingPathComponent("中文 @.txt"))
        try f.write("new file\n", f.writer.appendingPathComponent("added.cs"))
        _ = try await f.svn(["add", "--", f.writer.appendingPathComponent("added.cs").path + "@"])
        _ = try await f.svn(["delete", "--", f.writer.appendingPathComponent("deleted.txt").path + "@"])
        _ = try await f.svn(["commit", "--username", "更新者", "-m", "server changes", "--", f.writer.path + "@"])
        let events = OperationBox<[SVNOperationEvent]>([])
        let result = try await f.client().updateWithProgress(at: f.wc) { event in events.modify { $0.append(event) } }
        let values = events.value
        let rows = values.flatMap { event -> [SVNOperationRecord] in if case .output(let rows, _) = event { return rows }; return [] }
        let metadata = values.flatMap { event -> [SVNOperationMetadata] in if case .metadata(let values) = event { return values }; return [] }
        try expect(rows.contains { $0.path == "中文 @.txt" && $0.action == "更新" })
        try expect(rows.contains { $0.path == "added.cs" && $0.action == "新增" })
        try expect(rows.contains { $0.path == "deleted.txt" && $0.deleted })
        try expect(metadata.contains { $0.path == "中文 @.txt" && $0.author == "更新者" && $0.date.count == 19 && $0.revision == "2" })
        try expect(metadata.contains { $0.path == "added.cs" && $0.author == "更新者" })
        try expect(!metadata.contains { $0.path == "deleted.txt" }, "Deleted files must not show a stale last author")
        try expect(result.revision == "2")
        try expect(try String(contentsOf: f.wc.appendingPathComponent("中文 @.txt"), encoding: .utf8) == "remote update\n")
        let calls = try f.calls()
        try expect(calls == ["update", "info"], "Metadata should use one local info batch, with no pre-download listing or server request per file")
        let complete = try require(values.firstIndex { if case .commandCompleted = $0 { return true }; return false })
        let info = try require(values.firstIndex { if case .metadata = $0 { return true }; return false })
        try expect(complete < info)
    }

    func testCommitStreamsExplicitFilesAndPreservesUnselectedChanges() async throws {
        let f = try OperationFixture(); defer { f.remove() }
        try await f.prepare()
        for name in ["中文 @.txt", " leading.txt", "other.txt"] { try f.write("local \(name)\n", f.wc.appendingPathComponent(name)) }
        let events = OperationBox<[SVNOperationEvent]>([])
        let result = try await f.client().commitWithProgress(at: f.wc, paths: ["中文 @.txt", " leading.txt"], message: "selected only") { event in events.modify { $0.append(event) } }
        let rows = events.value.flatMap { event -> [SVNOperationRecord] in if case .output(let rows, _) = event { return rows }; return [] }
        try expect(rows.contains { $0.path == "中文 @.txt" && $0.action == "发送" })
        try expect(rows.contains { $0.path == " leading.txt" && $0.action == "发送" }, "Fixed-width SVN prefixes must preserve leading spaces in file names")
        try expect(!rows.contains { $0.path == "other.txt" })
        try expect(result.revision == "2")
        let remote = try await f.svn(["cat", "--", f.repo.appendingPathComponent("other.txt").absoluteString + "@"])
        try expect(remote == "base\n")
        let status = try await f.client().status(at: f.wc)
        try expect(status.contains { $0.path == "other.txt" && $0.item == "modified" })
        try expect(!status.contains { $0.path == "中文 @.txt" || $0.path == " leading.txt" })
    }

    func testLiveCommitHandlesSplitUTF8AndRedactsPassword() async throws {
        let f = try OperationFixture(); defer { f.remove() }
        let ack = f.root.appendingPathComponent("live.ack")
        let password = "synthetic-operation-secret"
        let commit = """
        IFS= read -r task_password
        if [ "$task_password" != \(operationQuote(password)) ]; then exit 11; fi
        printf 'Sending        first.txt\\nSending        \\344\\270'
        task_attempt=0
        while [ ! -f \(operationQuote(ack.path)) ]; do
            task_attempt=$((task_attempt + 1))
            if [ "$task_attempt" -ge 500 ]; then exit 12; fi
            /bin/sleep 0.01
        done
        printf '\\255\\346\\226\\207 @.txt\\nNotice %s\\nCommitted revision 7.' "$task_password"
        """
        let exe = try f.mock(update: "exit 1", commit: commit)
        let events = OperationBox<[SVNOperationEvent]>([])
        let client = SVNClient(executablePath: exe.path, credentials: .init(username: "fixture", password: password))
        let result = try await withCheckTimeout(.seconds(10)) {
            try await client.commitWithProgress(at: f.wc, paths: ["first.txt", "中文 @.txt"], message: "live") { event in
                events.modify { $0.append(event) }
                if case .output(let rows, _) = event, rows.contains(where: { $0.path == "first.txt" }) { try? Data().write(to: ack) }
            }
        }
        let rows = events.value.flatMap { event -> [SVNOperationRecord] in if case .output(let rows, _) = event { return rows }; return [] }
        try expect(rows.contains { $0.path == "中文 @.txt" })
        try expect(!rows.map(\.message).joined().contains("\u{fffd}"))
        try expect(!rows.map(\.message).joined().contains(password) && !result.text.contains(password))
        try expect(rows.contains { $0.message == "Notice [已隐藏]" })
        try expect(result.revision == "7")
    }

    func testFailedOrUnconfirmedCommitIsNotReplayed() async throws {
        for script in ["printf 'Sending        first.txt\\n'; printf 'svn: E999999: rejected\\n' >&2; exit 1", "printf 'Sending        first.txt\\n'; exit 0"] {
            let f = try OperationFixture(); defer { f.remove() }
            let exe = try f.mock(update: "exit 1", commit: script)
            let events = OperationBox<[SVNOperationEvent]>([])
            do {
                _ = try await SVNClient(executablePath: exe.path).commitWithProgress(at: f.wc, paths: ["first.txt"], message: "test") { event in events.modify { $0.append(event) } }
                throw CheckFailure.failed("Failed or unconfirmed commit must not report success")
            } catch is CheckFailure { throw CheckFailure.failed("Commit unexpectedly succeeded") }
            catch { }
            try expect(try f.calls().filter { $0 == "commit" }.count == 1)
            try expect(!events.value.contains { if case .commandCompleted = $0 { return true }; return false })
        }
    }

    func testUpdateCancellationReapsChildAndDoesNotReportCompletion() async throws {
        let f = try OperationFixture(); defer { f.remove() }
        let marker = f.root.appendingPathComponent("reader.pid")
        let exe = try f.mock(update: "printf '%s' \"$$\" > \(operationQuote(marker.path)); exec /bin/sleep 30", commit: "exit 1")
        let events = OperationBox<[SVNOperationEvent]>([])
        let task = Task {
            try await SVNClient(executablePath: exe.path).updateWithProgress(at: f.wc) { event in events.modify { $0.append(event) } }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var pid: Int32?
        while pid == nil && ContinuousClock.now < deadline {
            pid = (try? String(contentsOf: marker, encoding: .utf8)).flatMap { Int32($0) }
            if pid == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        defer { task.cancel(); if let pid, kill(pid, 0) == 0 { kill(pid, SIGTERM) } }
        let child = try require(pid)
        task.cancel()
        do { _ = try await task.value; throw CheckFailure.failed("Update must be cancelled") }
        catch is CancellationError { }
        try expect(kill(child, 0) != 0)
        try expect(!events.value.contains { if case .commandCompleted = $0 { return true }; return false })
    }

    func testLargeOutputIsBoundedAndMetadataFailureKeepsUpdateSuccess() async throws {
        let f = try OperationFixture(); defer { f.remove() }
        try f.write("local", f.wc.appendingPathComponent("target.txt"))
        let script = """
        /usr/bin/awk 'BEGIN { for (i=0;i<20000;i++) printf "U    file%d.txt\\n",i; for(i=0;i<100000;i++) printf "long"; printf "\\nU    target.txt\\nUpdated to revision 8.\\n" }'
        """
        let exe = try f.mock(update: script, commit: "exit 1")
        let counts = OperationBox<(Int, Bool, Bool)>((0, false, false))
        let result = try await SVNClient(executablePath: exe.path).updateWithProgress(at: f.wc) { event in
            counts.modify { value in
                if case .output(let rows, _) = event { value.0 += rows.count }
                if case .commandCompleted = event { value.1 = true }
                if case .notice = event { value.2 = true }
            }
        }
        try expect(counts.value.0 >= 20_003 && counts.value.1 && counts.value.2)
        try expect(result.text.utf8.count < 150_000 && result.revision == "8")
        try expect(try f.calls() == ["update", "info"], "Only retained file metadata needs a local query; a metadata failure must not replay update")
    }
}

private final class OperationBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T
    init(_ value: T) { storage = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return storage }
    func modify(_ action: (inout T) -> Void) { lock.lock(); defer { lock.unlock() }; action(&storage) }
}

private struct OperationFixture: Sendable {
    let root: URL
    let binary: String
    var wc: URL { root.appendingPathComponent("wc") }
    var writer: URL { root.appendingPathComponent("writer") }
    var repo: URL { root.appendingPathComponent("repo") }
    var profile: URL { root.appendingPathComponent("profile") }
    var callFile: URL { root.appendingPathComponent("calls") }
    init() throws {
        binary = try require(SVNClient.locateExecutable())
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        root = workspace.appendingPathComponent("work/operation-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try write("[miscellany]\nglobal-ignores = *.tmp\n", profile.appendingPathComponent("config"))
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func write(_ text: String, _ file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }
    func prepare() async throws {
        let admin = URL(fileURLWithPath: binary).deletingLastPathComponent().appendingPathComponent("svnadmin")
        let output = try await ProcessRunner.run(executable: admin.path, arguments: ["create", repo.path])
        try expect(output.exitCode == 0)
        let seed = root.appendingPathComponent("seed")
        for name in ["中文 @.txt", " leading.txt", "other.txt", "deleted.txt"] { try write("base\n", seed.appendingPathComponent(name)) }
        _ = try await svn(["import", "-m", "initial", "--", seed.path, repo.absoluteString])
        _ = try await svn(["checkout", "--", repo.absoluteString, wc.path])
        _ = try await svn(["checkout", "--", repo.absoluteString, writer.path])
    }
    func svn(_ args: [String]) async throws -> String {
        let result = try await ProcessRunner.run(executable: binary, arguments: ["--config-dir", profile.path, "--non-interactive", "--no-auth-cache"] + args)
        guard result.exitCode == 0 else { throw CheckFailure.failed("Fixture SVN failed with code \(result.exitCode)") }
        return result.text
    }
    func client() throws -> SVNClient {
        let executable = root.appendingPathComponent("svn-wrapper")
        try write("#!/bin/sh\nprintf '%s\\n' \"$1\" >> \(operationQuote(callFile.path))\nexec \(operationQuote(binary)) --config-dir \(operationQuote(profile.path)) \"$@\"\n", executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return SVNClient(executablePath: executable.path, globalIgnoreConfigurationFiles: [profile.appendingPathComponent("config")])
    }
    func calls() throws -> [String] { try String(contentsOf: callFile, encoding: .utf8).split(separator: "\n").map(String.init) }
    func mock(update: String, commit: String) throws -> URL {
        try FileManager.default.createDirectory(at: wc, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("mock-svn")
        let status = "<status><target path=\".\"><entry path=\"first.txt\"><wc-status item=\"modified\" props=\"none\"/></entry><entry path=\"中文 @.txt\"><wc-status item=\"modified\" props=\"none\"/></entry></target></status>"
        try write("""
        #!/bin/sh
        printf '%s\\n' "$1" >> \(operationQuote(callFile.path))
        case "$1" in
          status) printf '%s' \(operationQuote(status)) ;;
          update) \(update) ;;
          commit) \(commit) ;;
          info) printf '<invalid/>' ;;
          *) exit 17 ;;
        esac
        """, executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }
}

private func operationQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
