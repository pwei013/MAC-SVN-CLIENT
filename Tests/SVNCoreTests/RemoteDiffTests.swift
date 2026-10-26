import Darwin
import Foundation
import SVNCore

struct RemoteDiffTests {
    func testRemoteDiffUsesHeadAndLeavesWorkingCopyUnchanged() async throws {
        let fixture = try await RemoteDiffFixture.make()
        defer { fixture.remove() }
        try fixture.write("LOCAL-only\n", to: fixture.wc.appendingPathComponent("target.txt"))
        try fixture.write("HEAD-only\n", to: fixture.other.appendingPathComponent("target.txt"))
        _ = try await fixture.run(["commit", "-m", "third party edit", "--", fixture.other.appendingPathComponent("target.txt").path + "@"])
        let original = try Data(contentsOf: fixture.wc.appendingPathComponent("target.txt"))
        let before = try await fixture.state(at: fixture.wc)
        let revision = try await fixture.youngest()
        let client = fixture.client()
        let baseDiff = try await client.diff(at: fixture.wc, paths: ["target.txt"])
        try expect(baseDiff.contains("-BASE-only") && baseDiff.contains("+LOCAL-only"))
        let target = try await client.prepareRemoteFileDiff(at: fixture.wc, path: "target.txt")
        try expect(target.path == "target.txt" && target.url == fixture.repository.appendingPathComponent("target.txt").absoluteString)
        let headDiff = try await client.diffAgainstHead(target)
        try expect(headDiff.contains("-HEAD-only") && headDiff.contains("+LOCAL-only") && !headDiff.contains("-BASE-only"), "The comparison must use the third party's HEAD content, not this WC's BASE")
        try expect(try Data(contentsOf: fixture.wc.appendingPathComponent("target.txt")) == original)
        let after = try await fixture.state(at: fixture.wc)
        let afterRevision = try await fixture.youngest()
        let afterBaseDiff = try await client.diff(at: fixture.wc, paths: ["target.txt"])
        try expect(after == before && afterRevision == revision && afterBaseDiff == baseDiff, "HEAD comparison must not update, schedule or commit anything")
    }

    func testRemoteDiffHandlesLiteralPathsBinaryAndMissingHead() async throws {
        let fixture = try await RemoteDiffFixture.make()
        defer { fixture.remove() }
        let literal = "中文 空格@文件.txt"
        try fixture.write("LOCAL-literal\n", to: fixture.wc.appendingPathComponent(literal))
        try fixture.write("LOCAL-other\n", to: fixture.wc.appendingPathComponent("other.txt"))
        try fixture.write("HEAD-literal\n", to: fixture.other.appendingPathComponent(literal))
        try fixture.write("HEAD-other\n", to: fixture.other.appendingPathComponent("other.txt"))
        _ = try await fixture.run(["commit", "-m", "third party literal edit", "--", fixture.other.appendingPathComponent(literal).path + "@", fixture.other.appendingPathComponent("other.txt").path + "@"])
        let client = fixture.client()
        let target = try await client.prepareRemoteFileDiff(at: fixture.wc, path: literal)
        let diff = try await client.diffAgainstHead(target)
        try expect(diff.contains("-HEAD-literal") && diff.contains("+LOCAL-literal"))
        try expect(!diff.contains("HEAD-other") && !diff.contains("LOCAL-other") && !diff.contains("Index: other.txt"), "Only the literal @/space/Chinese path may be compared")
        let link = fixture.wc.appendingPathComponent("link @")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "other.txt")
        let linkTarget = try await client.prepareRemoteFileDiff(at: fixture.wc, path: "link @")
        let linkDiff = try await client.diffAgainstHead(linkTarget)
        try expect(linkDiff.contains("other.txt") && linkDiff.contains("target.txt"), "A versioned svn:special symlink compares link text without following its target")

        try Data([0, 9, 10, 11]).write(to: fixture.wc.appendingPathComponent("binary.dat"))
        try Data([0, 6, 7, 8]).write(to: fixture.other.appendingPathComponent("binary.dat"))
        _ = try await fixture.run(["propset", "svn:mime-type", "application/octet-stream", "--", fixture.other.appendingPathComponent("binary.dat").path + "@"])
        _ = try await fixture.run(["commit", "-m", "third party binary edit", "--", fixture.other.appendingPathComponent("binary.dat").path + "@"])
        let binary = try await client.prepareRemoteFileDiff(at: fixture.wc, path: "binary.dat")
        let binaryDiff = try await client.diffAgainstHead(binary)
        try expect(binaryDiff.localizedCaseInsensitiveContains("binary"), "Keep SVN's binary explanation instead of forcing a text diff")
        let binaryBefore = try Data(contentsOf: fixture.wc.appendingPathComponent("binary.dat"))

        _ = try await fixture.run(["delete", "--", fixture.other.appendingPathComponent("target.txt").path + "@"])
        _ = try await fixture.run(["move", "--", fixture.other.appendingPathComponent(literal).path + "@", fixture.other.appendingPathComponent("renamed @.txt").path])
        _ = try await fixture.run(["commit", "-m", "third party delete and rename", "--", fixture.other.path + "@"])
        let revision = try await fixture.youngest()
        let before = try await fixture.state(at: fixture.wc)
        for path in ["target.txt", literal] {
            let missing = try await client.prepareRemoteFileDiff(at: fixture.wc, path: path)
            do {
                _ = try await client.diffAgainstHead(missing)
                throw CheckFailure.failed("HEAD deletion or rename must fail rather than silently compare BASE")
            } catch let error as CheckFailure { throw error }
            catch let error as SVNError { try expect(error.localizedDescription.contains("云端最新版本") && error.localizedDescription.contains("删除或改名")) }
        }
        let after = try await fixture.state(at: fixture.wc)
        let afterRevision = try await fixture.youngest()
        try expect(after == before && afterRevision == revision)
        try expect(try Data(contentsOf: fixture.wc.appendingPathComponent("binary.dat")) == binaryBefore)
        try expect(try String(contentsOf: fixture.wc.appendingPathComponent(literal), encoding: .utf8) == "LOCAL-literal\n")
    }

    func testRemoteDiffRejectsInvalidAndStaleTargetsBeforeRemoteRead() async throws {
        let fixture = try await RemoteDiffFixture.make()
        defer { fixture.remove() }
        let marker = fixture.root.appendingPathComponent("remote-request")
        let client = try fixture.wrapper("""
        if [ "$1" = diff ]; then
            printf '%s\\n' requested > \(remoteDiffShellQuote(marker.path))
            exit 1
        fi
        """, name: "no remote svn")
        try fixture.write("untracked\n", to: fixture.wc.appendingPathComponent("new.txt"))
        try fixture.write("ignored\n", to: fixture.wc.appendingPathComponent("skip.ignored"))
        _ = try await fixture.run(["propset", "svn:ignore", "*.ignored", "--", fixture.wc.path + "@"])
        for path in ["", "../outside.txt", "/absolute.txt", ".svn/wc.db", "nested/../target.txt", "nested", "new.txt", "skip.ignored", "missing.txt"] {
            try await fixture.expectInvalid(client: client, directory: fixture.wc, path: path)
        }
        _ = try await fixture.run(["add", "--", fixture.wc.appendingPathComponent("new.txt").path + "@"])
        try await fixture.expectInvalid(client: client, directory: fixture.wc, path: "new.txt")
        _ = try await fixture.run(["delete", "--keep-local", "--force", "--", fixture.wc.appendingPathComponent("other.txt").path + "@"])
        try await fixture.expectInvalid(client: client, directory: fixture.wc, path: "other.txt")
        let linked = fixture.wc.appendingPathComponent("linked-parent")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: fixture.wc.appendingPathComponent("nested"))
        try await fixture.expectInvalid(client: client, directory: fixture.wc, path: "linked-parent/tracked.txt")
        let external = fixture.wc.appendingPathComponent("nested/external-wc")
        _ = try await fixture.run(["checkout", "--", fixture.repository.appendingPathComponent("branch-b").absoluteString + "@", external.path])
        try await fixture.expectInvalid(client: client, directory: fixture.wc, path: "nested/external-wc/target.txt")

        let switched = fixture.root.appendingPathComponent("switched")
        _ = try await fixture.run(["checkout", "--", fixture.repository.appendingPathComponent("branch-a").absoluteString + "@", switched.path])
        let target = try await client.prepareRemoteFileDiff(at: switched, path: "target.txt")
        _ = try await fixture.run(["switch", "--ignore-ancestry", "--", fixture.repository.appendingPathComponent("branch-b").absoluteString + "@", switched.path])
        let switchedNow = try await client.prepareRemoteFileDiff(at: switched, path: "target.txt")
        try expect(switchedNow.url != target.url, "The fixture must actually change the repository mapping while retaining a local file")
        do {
            _ = try await client.diffAgainstHead(target)
            throw CheckFailure.failed("A switched URL must be rejected before a remote diff")
        } catch let error as CheckFailure { throw error }
        catch is SVNError { }
        try expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    func testRemoteDiffAuthenticationCancellationAndBoundedOutput() async throws {
        let fixture = try await RemoteDiffFixture.make()
        defer { fixture.remove() }
        let target = try await fixture.client().prepareRemoteFileDiff(at: fixture.wc, path: "target.txt")
        let password = "dummy HEAD password"
        let credentials = SVNCredentials(username: "fixture-user", password: password)
        let arguments = fixture.root.appendingPathComponent("diff-arguments")
        let input = fixture.root.appendingPathComponent("input-result")
        let largeClient = try fixture.wrapper("""
        if [ "$1" = diff ]; then
            printf '%s\\0' "$@" > \(remoteDiffShellQuote(arguments.path))
            IFS= read -r task_password
            if [ "$task_password" = \(remoteDiffShellQuote(password)) ]; then printf '%s' input-ok > \(remoteDiffShellQuote(input.path)); fi
            /bin/dd if=/dev/zero bs=524287 count=1 2>/dev/null | /usr/bin/tr '\\000' A
            printf '%s' '中'
            /bin/dd if=/dev/zero bs=524288 count=4 2>/dev/null | /usr/bin/tr '\\000' B
            exit 0
        fi
        """, name: "large output svn", credentials: credentials)
        let text = try await largeClient.diffAgainstHead(target)
        try expect(text.utf8.count <= 512 * 1_024 + 512 && text.contains("已截断"))
        try expect(!text.contains("\u{FFFD}"), "Truncation must not manufacture an incomplete UTF-8 replacement character")
        let args = try String(contentsOf: arguments, encoding: .utf8).split(separator: "\0").map(String.init)
        try expect(args.contains("--username") && args.contains("fixture-user") && args.contains("--password-from-stdin"))
        try expect(!args.joined(separator: " ").contains(password))
        try expect(args.contains("HEAD") && args.contains("--internal-diff") && args.last == "target.txt@" && !args.contains("--force"))
        try expect(!args.contains("--depth"), "A single validated file needs no depth override; empty depth silently suppresses svn:special diffs")
        try expect(try String(contentsOf: input, encoding: .utf8) == "input-ok", "Credential input is consumed through stdin without persisting the password")

        let failure = try fixture.wrapper("""
        if [ "$1" = diff ]; then
            IFS= read -r task_password
            printf '%s\\n' "svn: E170001: fixture authentication $task_password" >&2
            exit 1
        fi
        """, name: "auth failure svn", credentials: credentials)
        do {
            _ = try await failure.diffAgainstHead(target)
            throw CheckFailure.failed("Authentication errors must remain retryable by the model")
        } catch let error as CheckFailure { throw error }
        catch let error as SVNError {
            try expect(error.isAuthenticationFailure && !error.localizedDescription.contains(password))
        }

        let marker = fixture.root.appendingPathComponent("running.pid")
        let cancellable = try fixture.wrapper("""
        if [ "$1" = diff ]; then
            IFS= read -r task_password
            printf '%s\\n' "$$" > \(remoteDiffShellQuote(marker.path))
            exec /bin/sleep 30
        fi
        """, name: "cancel svn", credentials: credentials)
        let task = Task { try await cancellable.diffAgainstHead(target) }
        var process: pid_t?
        defer { task.cancel(); if let process, kill(process, 0) == 0 { _ = kill(process, SIGTERM) } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while process == nil, ContinuousClock.now < deadline {
            if let value = try? String(contentsOf: marker, encoding: .utf8) { process = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if process == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        let pid = try require(process, "The remote diff process must start before cancellation")
        task.cancel()
        do {
            _ = try await task.value
            throw CheckFailure.failed("Cancelled remote diff must throw CancellationError")
        } catch is CancellationError { }
        try expect(kill(pid, 0) != 0, "Cancellation must terminate and reap the remote diff process")
        process = nil
    }
}

private struct RemoteDiffFixture {
    let root: URL
    let svn: URL
    let repository: URL
    let wc: URL
    let other: URL
    let config: URL
    let svnlook: URL

    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("SVNRemoteDiffChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let bin = try require([FileManager.default.homeDirectoryForCurrentUser.path + "/.local/svn-cli/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].first {
            FileManager.default.isExecutableFile(atPath: $0 + "/svn") && FileManager.default.isExecutableFile(atPath: $0 + "/svnadmin")
        })
        let profile = root.appendingPathComponent("profile")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let config = profile.appendingPathComponent("config")
        try "[miscellany]\nglobal-ignores =\n".write(to: config, atomically: true, encoding: .utf8)
        let svn = root.appendingPathComponent("isolated svn")
        try ("#!/bin/sh\nexec " + remoteDiffShellQuote(bin + "/svn") + " --config-dir " + remoteDiffShellQuote(profile.path) + " \"$@\"\n").write(to: svn, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: svn.path)
        let fixture = Self(root: root, svn: svn, repository: root.appendingPathComponent("repository"), wc: root.appendingPathComponent("local @", isDirectory: true),
            other: root.appendingPathComponent("third party", isDirectory: true), config: config, svnlook: URL(fileURLWithPath: bin + "/svnlook"))
        let seed = root.appendingPathComponent("seed")
        for (path, content) in [("target.txt", "BASE-only\n"), ("other.txt", "BASE-other\n"), ("中文 空格@文件.txt", "BASE-literal\n"),
                                ("nested/tracked.txt", "tracked\n"), ("branch-a/target.txt", "branch A\n"), ("branch-b/target.txt", "branch B\n")] {
            try fixture.write(content, to: seed.appendingPathComponent(path))
        }
        try Data([0, 1, 2, 3]).write(to: seed.appendingPathComponent("binary.dat"))
        try FileManager.default.createSymbolicLink(atPath: seed.appendingPathComponent("link @").path, withDestinationPath: "target.txt")
        let created = try await ProcessRunner.run(executable: bin + "/svnadmin", arguments: ["create", fixture.repository.path])
        guard created.exitCode == 0 else { fixture.remove(); throw CheckFailure.failed("Cannot create remote-diff fixture repository") }
        _ = try await fixture.run(["import", "-m", "remote diff fixture", "--", seed.path, fixture.repository.absoluteString])
        _ = try await fixture.run(["checkout", "--", fixture.repository.absoluteString + "@", fixture.wc.path])
        _ = try await fixture.run(["checkout", "--", fixture.repository.absoluteString + "@", fixture.other.path])
        return fixture
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func client() -> SVNClient { SVNClient(executablePath: svn.path, globalIgnoreConfigurationFiles: [config]) }
    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    func run(_ arguments: [String]) async throws -> String {
        let result = try await ProcessRunner.run(executable: svn.path, arguments: arguments)
        guard result.exitCode == 0 else {
            let commands = ["import", "checkout", "commit", "propset", "delete", "move", "add", "switch"]
            let stage = arguments.first.flatMap { commands.contains($0) ? $0 : nil } ?? "command"
            let detail = String(decoding: result.stderr, as: UTF8.self)
            let code = detail.range(of: "[EW][0-9]{6}", options: .regularExpression).map { String(detail[$0]) } ?? "no-code"
            throw CheckFailure.failed("Isolated remote-diff SVN \(stage) failed (\(result.exitCode), \(code))")
        }
        return result.text
    }
    func state(at directory: URL) async throws -> String {
        let client = client()
        let status = try await client.status(at: directory, showIgnored: true)
        let info = try await client.info(at: directory)
        return info.url + "#" + info.revision + "\n" + status.map { $0.path + "|" + $0.item + "|" + $0.properties }.joined(separator: "\n")
    }
    func youngest() async throws -> String {
        let result = try await ProcessRunner.run(executable: svnlook.path, arguments: ["youngest", repository.path])
        guard result.exitCode == 0 else { throw CheckFailure.failed("Cannot inspect remote-diff fixture revision") }
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func wrapper(_ body: String, name: String, credentials: SVNCredentials = .init()) throws -> SVNClient {
        let file = root.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\nexec " + remoteDiffShellQuote(svn.path) + " \"$@\"\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return SVNClient(executablePath: file.path, credentials: credentials, globalIgnoreConfigurationFiles: [config])
    }
    func expectInvalid(client: SVNClient, directory: URL, path: String) async throws {
        do {
            _ = try await client.prepareRemoteFileDiff(at: directory, path: path)
            throw CheckFailure.failed("Invalid or unversioned file must be rejected before a remote request")
        } catch let error as CheckFailure { throw error }
        catch is SVNError { }
    }
}
private func remoteDiffShellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
