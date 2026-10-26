import Darwin
import Foundation
import CoreFoundation
import SVNCore

struct FileComparisonTests {
    func testFileComparisonReadsMislabeledTextAtPinnedHeadAndBaseReadOnly() async throws {
        let fixture = try await ComparisonFixture.make()
        defer { fixture.remove() }
        let localFile = fixture.wc.appendingPathComponent("target.cs")
        let otherFile = fixture.other.appendingPathComponent("target.cs")
        _ = try await fixture.run(["propset", "svn:mime-type", "application/octet-stream", "--", otherFile.path + "@"])
        try fixture.write("BASE-with-binary-mime\r\n", to: otherFile)
        _ = try await fixture.run(["commit", "-m", "fixture mislabeled mime", "--", otherFile.path + "@"])
        _ = try await fixture.run(["update", "--", fixture.wc.path + "@"])
        try fixture.write("HEAD-pinned\r\n", to: otherFile)
        _ = try await fixture.run(["commit", "-m", "fixture HEAD", "--", otherFile.path + "@"])
        try fixture.write("LOCAL-content\r\n", to: localFile)
        let before = try await fixture.state()
        let mime = try await fixture.value("svn:mime-type", at: localFile)
        let client = fixture.client()
        let target = try await client.prepareRemoteFileDiff(at: fixture.wc, path: "target.cs")
        let patch = try await client.diffAgainstHead(target)
        try expect(patch.localizedCaseInsensitiveContains("binary"), "The fixture must reproduce SVN's MIME-based patch rejection")
        let pinned = try await fixture.youngest()
        let catArguments = fixture.root.appendingPathComponent("cat-arguments")
        let racing = try fixture.wrapper("""
        if [ "$1" = info ]; then
            case "$*" in *"--show-item revision"*)
                \(comparisonQuote(fixture.svn.path)) "$@" || exit "$?"
                printf '%s\\r\\n' 'HEAD-after-info' > \(comparisonQuote(otherFile.path))
                \(comparisonQuote(fixture.svn.path)) commit -m fixture-race -- \(comparisonQuote(otherFile.path + "@")) >/dev/null || exit "$?"
                exit 0
            esac
        fi
        if [ "$1" = cat ]; then printf '%s\\0' "$@" > \(comparisonQuote(catArguments.path)); fi
        """, name: "pinned snapshot svn")
        let result = try await racing.fileComparison(target)
        try expect(result.local.text == "LOCAL-content\r\n" && result.remote.text == "HEAD-pinned\r\n")
        try expect(result.remoteLabel.contains("r" + pinned) && result.local.lineEnding == "CRLF")
        let args = try String(contentsOf: catArguments, encoding: .utf8).split(separator: "\0").map(String.init)
        try expect(args.contains(pinned) && args.last == target.url + "@" + pinned && !args.contains("HEAD"), "Cat must use the same numeric revision returned by HEAD info")
        let afterRace = try await fixture.youngest()
        try expect(afterRace != pinned, "The fixture must advance HEAD between info and cat")
        let base = try await client.fileComparison(target, revision: .base)
        let head = try await client.fileComparison(target)
        try expect(base.remote.text == "BASE-with-binary-mime\r\n" && base.remoteLabel.contains("BASE"))
        try expect(head.remote.text == "HEAD-after-info\r\n" && head.local.text == "LOCAL-content\r\n")
        let after = try await fixture.state()
        let afterRevision = try await fixture.youngest()
        let afterMime = try await fixture.value("svn:mime-type", at: localFile)
        try expect(before == after && mime == afterMime && mime == "application/octet-stream")
        try expect(afterRevision == afterRace, "Only the fixture's third-party race may commit; comparisons are read-only")
        try expect(try Data(contentsOf: localFile) == Data("LOCAL-content\r\n".utf8))
    }

    func testFileComparisonDecodesUnicodeAndChineseButRejectsBinary() async throws {
        let fixture = try await ComparisonFixture.make()
        defer { fixture.remove() }
        let unicode = "using System;\r\n// 中文 😀\r\n"
        let gbText = "中文编码与文本比较\r\n"
        let gbEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0632)))
        let gb = try require(gbText.data(using: gbEncoding, allowLossyConversion: false))
        let samples: [(String, Data, String, String)] = [
            ("bom.txt", Data([0xEF, 0xBB, 0xBF]) + Data("first\r\n第二行\nthird\r".utf8), "first\r\n第二行\nthird\r", "UTF-8"),
            ("little.txt", Data([0xFF, 0xFE]) + (try require(unicode.data(using: .utf16LittleEndian))), unicode, "UTF-16 LE"),
            ("big.txt", Data([0xFE, 0xFF]) + (try require(unicode.data(using: .utf16BigEndian))), unicode, "UTF-16 BE"),
            ("plain16.txt", try require(unicode.data(using: .utf16LittleEndian)), unicode, "UTF-16 LE"),
            ("legacy.txt", gb, gbText, "GB")
        ]
        let binaries: [(String, Data)] = [
            ("fake.cs", Data([0x89, 0x50, 0x4E, 0x47, 13, 10, 0x1A, 10]) + Data("not a source file".utf8)),
            ("archive.txt", Data([0x50, 0x4B, 3, 4, 65, 66])),
            ("nul.txt", Data([65, 0, 0, 66])), ("control.txt", Data("visible\u{1B}control".utf8)),
            ("bad16.txt", Data([0xFF, 0xFE, 0, 0xD8]))
        ]
        for (name, data, _, _) in samples { try data.write(to: fixture.other.appendingPathComponent(name)) }
        for (name, data) in binaries { try data.write(to: fixture.other.appendingPathComponent(name)) }
        let paths = (samples.map { $0.0 } + binaries.map { $0.0 }).map { fixture.other.appendingPathComponent($0).path + "@" }
        _ = try await fixture.run(["add", "--"] + paths)
        _ = try await fixture.run(["commit", "-m", "encoding fixture", "--", fixture.other.path + "@"])
        _ = try await fixture.run(["update", "--", fixture.wc.path + "@"])
        let client = fixture.client()
        let before = try await fixture.state()
        let revision = try await fixture.youngest()
        for (name, data, text, encoding) in samples {
            let target = try await client.prepareRemoteFileDiff(at: fixture.wc, path: name)
            let compared = try await client.fileComparison(target)
            try expect(compared.local.text == text && compared.remote.text == text, "Decoded text must preserve line endings and Unicode characters")
            try expect(compared.local.encoding.contains(encoding) && compared.remote.encoding.contains(encoding))
            try expect(compared.local.byteCount == data.count && compared.remote.byteCount == data.count)
            if name == "bom.txt" { try expect(compared.local.encoding.contains("BOM") && compared.local.lineEnding.contains("混合")) }
        }
        for (name, _) in binaries {
            let target = try await client.prepareRemoteFileDiff(at: fixture.wc, path: name)
            do {
                _ = try await client.fileComparison(target)
                throw CheckFailure.failed("Real binary or invalid UTF-16 must not be forced into text based on its extension")
            } catch let error as CheckFailure { throw error }
            catch is SVNError { }
        }
        let afterDecoding = try await fixture.state()
        try expect(afterDecoding == before, "Successful decoding and binary rejection must leave working-copy state unchanged")
        try fixture.write("local text instead of PNG\n", to: fixture.wc.appendingPathComponent("fake.cs"))
        let binaryRemote = try await client.prepareRemoteFileDiff(at: fixture.wc, path: "fake.cs")
        do {
            _ = try await client.fileComparison(binaryRemote)
            throw CheckFailure.failed("A real remote binary must also be rejected when the local side is text")
        } catch let error as CheckFailure { throw error }
        catch is SVNError { }
        try expect(try String(contentsOf: fixture.wc.appendingPathComponent("fake.cs"), encoding: .utf8) == "local text instead of PNG\n")
        let afterRevision = try await fixture.youngest()
        try expect(afterRevision == revision)
    }

    func testFileComparisonHandlesLiteralPathsMissingHeadAndSizeLimits() async throws {
        let fixture = try await ComparisonFixture.make()
        defer { fixture.remove() }
        let client = fixture.client()
        let name = "中文 空格@文件.cs"
        try fixture.write("LOCAL-literal\n", to: fixture.wc.appendingPathComponent(name))
        try fixture.write("HEAD-literal\n", to: fixture.other.appendingPathComponent(name))
        _ = try await fixture.run(["commit", "-m", "literal HEAD", "--", fixture.other.appendingPathComponent(name).path + "@"])
        let literal = try await client.prepareRemoteFileDiff(at: fixture.wc, path: name)
        let result = try await client.fileComparison(literal)
        try expect(result.local.text == "LOCAL-literal\n" && result.remote.text == "HEAD-literal\n")
        let link = fixture.wc.appendingPathComponent("link @")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "other.txt")
        let linkTarget = try await client.prepareRemoteFileDiff(at: fixture.wc, path: "link @")
        let linked = try await client.fileComparison(linkTarget)
        try expect(linked.local.text == "link other.txt" && linked.remote.text == "link target.cs", "Read stored symlink text, never the linked file's contents")
        _ = try await fixture.run(["move", "--", fixture.other.appendingPathComponent(name).path + "@", fixture.other.appendingPathComponent("renamed.cs").path])
        _ = try await fixture.run(["delete", "--", fixture.other.appendingPathComponent("target.cs").path + "@"])
        _ = try await fixture.run(["commit", "-m", "delete and rename", "--", fixture.other.path + "@"])
        for path in [name, "target.cs"] {
            let target = try await client.prepareRemoteFileDiff(at: fixture.wc, path: path)
            do {
                _ = try await client.fileComparison(target)
                throw CheckFailure.failed("A missing HEAD path must not silently read BASE")
            } catch let error as CheckFailure { throw error }
            catch let error as SVNError { try expect(error.localizedDescription.contains("删除或改名")) }
            let base = try await client.fileComparison(target, revision: .base)
            try expect(base.remoteLabel.contains("BASE"))
        }
        try Data(repeating: 65, count: 4 * 1_024 * 1_024 + 1).write(to: fixture.wc.appendingPathComponent("target.cs"))
        let localLarge = try await client.prepareRemoteFileDiff(at: fixture.wc, path: "target.cs")
        do {
            _ = try await client.fileComparison(localLarge, revision: .base)
            throw CheckFailure.failed("A local oversized file must fail without truncating its content")
        } catch let error as CheckFailure { throw error }
        catch let error as SVNError { try expect(error.localizedDescription.contains("本地文件超过 4 MiB")) }
        try Data(repeating: 66, count: 4 * 1_024 * 1_024 + 1).write(to: fixture.other.appendingPathComponent("large.txt"))
        _ = try await fixture.run(["commit", "-m", "large HEAD", "--", fixture.other.appendingPathComponent("large.txt").path + "@"])
        let remoteLarge = try await client.prepareRemoteFileDiff(at: fixture.wc, path: "large.txt")
        do {
            _ = try await client.fileComparison(remoteLarge)
            throw CheckFailure.failed("A remote oversized file must fail without a partial comparison")
        } catch let error as CheckFailure { throw error }
        catch let error as SVNError { try expect(error.localizedDescription.contains("云端文件超过 4 MiB")) }
        try expect(try Data(contentsOf: fixture.wc.appendingPathComponent("large.txt")) == Data("small file\n".utf8))
    }

    func testFileComparisonAuthenticationCancellationAndStaleMapping() async throws {
        let fixture = try await ComparisonFixture.make()
        defer { fixture.remove() }
        let target = try await fixture.client().prepareRemoteFileDiff(at: fixture.wc, path: "target.cs")
        let password = "dummy comparison password"
        let credentials = SVNCredentials(username: "fixture-user", password: password)
        let infoArgs = fixture.root.appendingPathComponent("info-arguments")
        let catArgs = fixture.root.appendingPathComponent("cat-arguments")
        let input = fixture.root.appendingPathComponent("input-results")
        let authenticated = try fixture.wrapper("""
        if [ "$1" = info ]; then
            case "$*" in *"--show-item revision"*)
                printf '%s\\0' "$@" > \(comparisonQuote(infoArgs.path))
                IFS= read -r task_password
                if [ "$task_password" = \(comparisonQuote(password)) ]; then printf '%s\\n' info-ok >> \(comparisonQuote(input.path)); fi
                printf '%s\\n' 7
                exit 0
            esac
        fi
        if [ "$1" = cat ]; then
            printf '%s\\0' "$@" > \(comparisonQuote(catArgs.path))
            IFS= read -r task_password
            if [ "$task_password" = \(comparisonQuote(password)) ]; then printf '%s\\n' cat-ok >> \(comparisonQuote(input.path)); fi
            printf '%s\\n' 'REMOTE fixture'
            exit 0
        fi
        """, name: "authenticated svn", credentials: credentials)
        let result = try await authenticated.fileComparison(target)
        try expect(result.remote.text == "REMOTE fixture\n" && result.remoteLabel.contains("r7"))
        for file in [infoArgs, catArgs] {
            let args = try String(contentsOf: file, encoding: .utf8).split(separator: "\0").map(String.init)
            try expect(args.contains("--username") && args.contains("fixture-user") && args.contains("--password-from-stdin"))
            try expect(!args.joined(separator: " ").contains(password))
        }
        let cat = try String(contentsOf: catArgs, encoding: .utf8).split(separator: "\0").map(String.init)
        try expect(cat.contains("7") && cat.last == target.url + "@7")
        try expect(try String(contentsOf: input, encoding: .utf8) == "info-ok\ncat-ok\n")
        let failure = try fixture.wrapper("""
        if [ "$1" = info ]; then
            case "$*" in *"--show-item revision"*)
                IFS= read -r task_password
                printf '%s\\n' "svn: E170001: fixture $task_password" >&2
                exit 1
            esac
        fi
        """, name: "auth failure svn", credentials: credentials)
        do {
            _ = try await failure.fileComparison(target)
            throw CheckFailure.failed("Authentication failures must remain distinguishable for the login retry")
        } catch let error as CheckFailure { throw error }
        catch let error as SVNError { try expect(error.isAuthenticationFailure && !error.localizedDescription.contains(password)) }

        let marker = fixture.root.appendingPathComponent("cat.pid")
        let cancellable = try fixture.wrapper(comparisonInfoThenCat("""
        IFS= read -r task_password
        printf '%s\\n' "$$" > \(comparisonQuote(marker.path))
        exec /bin/sleep 30
        """), name: "cancel cat svn", credentials: credentials)
        let task = Task { try await cancellable.fileComparison(target) }
        var process: pid_t?
        defer { task.cancel(); if let process, kill(process, 0) == 0 { _ = kill(process, SIGTERM) } }
        process = try await fixture.waitForPID(marker)
        let pid = try require(process)
        task.cancel()
        do {
            _ = try await task.value
            throw CheckFailure.failed("Cancelled full-text read must propagate CancellationError")
        } catch is CancellationError { }
        try expect(kill(pid, 0) != 0)
        process = nil

        let overflowPID = fixture.root.appendingPathComponent("overflow.pid")
        let overflow = try fixture.wrapper(comparisonInfoThenCat("""
        IFS= read -r task_password
        printf '%s\\n' "$$" > \(comparisonQuote(overflowPID.path))
        exec /usr/bin/yes comparison-fixture
        """), name: "overflow svn", credentials: credentials)
        let request = Task { try await overflow.fileComparison(target) }
        let timeout = Task { try await Task.sleep(for: .seconds(10)); request.cancel() }
        defer { request.cancel(); timeout.cancel() }
        do {
            _ = try await request.value
            throw CheckFailure.failed("Overflow must stop the producer and reject the partial document")
        } catch let error as CheckFailure { throw error }
        catch let error as SVNError { try expect(error.localizedDescription.contains("超过 4 MiB")) }
        let stopped = try await fixture.waitForPID(overflowPID)
        try expect(kill(stopped, 0) != 0, "Exceeding the size limit must terminate and reap the producer without draining forever")

        let remoteMarker = fixture.root.appendingPathComponent("stale-remote")
        let staleClient = try fixture.wrapper("""
        if [ "$1" = cat ]; then printf '%s' requested > \(comparisonQuote(remoteMarker.path)); exit 1; fi
        if [ "$1" = info ]; then
            case "$*" in *"--show-item revision"*) printf '%s' requested > \(comparisonQuote(remoteMarker.path)); exit 1;; esac
        fi
        """, name: "stale check svn")
        let switched = fixture.root.appendingPathComponent("switched")
        _ = try await fixture.run(["checkout", "--", fixture.repository.appendingPathComponent("branch-a").absoluteString + "@", switched.path])
        let stale = try await staleClient.prepareRemoteFileDiff(at: switched, path: "target.cs")
        _ = try await fixture.run(["switch", "--ignore-ancestry", "--", fixture.repository.appendingPathComponent("branch-b").absoluteString + "@", switched.path])
        do {
            _ = try await staleClient.fileComparison(stale)
            throw CheckFailure.failed("A switched repository mapping must stop before authenticated remote reads")
        } catch let error as CheckFailure { throw error }
        catch is SVNError { }
        try expect(!FileManager.default.fileExists(atPath: remoteMarker.path))
    }
}

private func comparisonInfoThenCat(_ body: String) -> String {
    """
    if [ "$1" = info ]; then
        case "$*" in *"--show-item revision"*) IFS= read -r task_password; printf '%s\\n' 1; exit 0;; esac
    fi
    if [ "$1" = cat ]; then
        \(body)
    fi
    """
}
private struct ComparisonFixture {
    let root: URL
    let svn: URL
    let repository: URL
    let wc: URL
    let other: URL
    let config: URL
    let svnlook: URL
    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("SVNFileComparisonChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let bin = try require([FileManager.default.homeDirectoryForCurrentUser.path + "/.local/svn-cli/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].first {
            FileManager.default.isExecutableFile(atPath: $0 + "/svn") && FileManager.default.isExecutableFile(atPath: $0 + "/svnadmin")
        })
        let profile = root.appendingPathComponent("profile")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let config = profile.appendingPathComponent("config")
        try "[miscellany]\nglobal-ignores =\nenable-auto-props = no\n".write(to: config, atomically: true, encoding: .utf8)
        let svn = root.appendingPathComponent("isolated svn")
        try ("#!/bin/sh\nexec " + comparisonQuote(bin + "/svn") + " --config-dir " + comparisonQuote(profile.path) + " \"$@\"\n").write(to: svn, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: svn.path)
        let fixture = Self(root: root, svn: svn, repository: root.appendingPathComponent("repository"), wc: root.appendingPathComponent("local @", isDirectory: true),
            other: root.appendingPathComponent("third party", isDirectory: true), config: config, svnlook: URL(fileURLWithPath: bin + "/svnlook"))
        let seed = root.appendingPathComponent("seed")
        for (name, content) in [("target.cs", "BASE-source\n"), ("other.txt", "other file contents\n"), ("中文 空格@文件.cs", "BASE-literal\n"),
                                ("large.txt", "small file\n"), ("branch-a/target.cs", "branch A\n"), ("branch-b/target.cs", "branch B\n")] {
            try fixture.write(content, to: seed.appendingPathComponent(name))
        }
        try FileManager.default.createSymbolicLink(atPath: seed.appendingPathComponent("link @").path, withDestinationPath: "target.cs")
        let created = try await ProcessRunner.run(executable: bin + "/svnadmin", arguments: ["create", fixture.repository.path])
        guard created.exitCode == 0 else { fixture.remove(); throw CheckFailure.failed("Cannot create file-comparison fixture repository") }
        _ = try await fixture.run(["import", "-m", "comparison fixture", "--", seed.path, fixture.repository.absoluteString])
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
            let stage = arguments.first.flatMap { ["import", "checkout", "commit", "propset", "delete", "move", "add", "switch", "update", "propget"].contains($0) ? $0 : nil } ?? "command"
            let detail = String(decoding: result.stderr, as: UTF8.self)
            let code = detail.range(of: "[EW][0-9]{6}", options: .regularExpression).map { String(detail[$0]) } ?? "no-code"
            throw CheckFailure.failed("Isolated comparison SVN \(stage) failed (\(result.exitCode), \(code))")
        }
        return result.text
    }
    func value(_ name: String, at file: URL) async throws -> String { try await run(["propget", "--strict", name, "--", file.path + "@"]) }
    func state() async throws -> String {
        let status = try await client().status(at: wc, showIgnored: true)
        let info = try await client().info(at: wc)
        return info.url + "#" + info.revision + "\n" + status.map { $0.path + "|" + $0.item + "|" + $0.properties }.joined(separator: "\n")
    }
    func youngest() async throws -> String {
        let result = try await ProcessRunner.run(executable: svnlook.path, arguments: ["youngest", repository.path])
        guard result.exitCode == 0 else { throw CheckFailure.failed("Cannot inspect comparison fixture revision") }
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func wrapper(_ body: String, name: String, credentials: SVNCredentials = .init()) throws -> SVNClient {
        let file = root.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\nexec " + comparisonQuote(svn.path) + " \"$@\"\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return SVNClient(executablePath: file.path, credentials: credentials, globalIgnoreConfigurationFiles: [config])
    }
    func waitForPID(_ marker: URL) async throws -> pid_t {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if let value = try? String(contentsOf: marker, encoding: .utf8), let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)) { return pid }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CheckFailure.failed("Comparison process did not start before the deadline")
    }
}
private func comparisonQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
