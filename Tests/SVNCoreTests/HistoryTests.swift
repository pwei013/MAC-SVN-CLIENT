import Darwin
import Foundation
import SVNCore

struct HistoryTests {
    func testWorkingHistoryResolvesSwitchedNodesAndRejectsUntrackedScopes() async throws {
        let fixture = try await HistoryIncomingFixture.make()
        defer { fixture.remove() }
        let client = fixture.client()
        let literal = try await client.workingHistoryURL(at: fixture.wc, path: fixture.name)
        try expect(literal == fixture.repo.appendingPathComponent(fixture.name).absoluteString)
        let root = try await client.workingHistoryURL(at: fixture.wc)
        try expect(root == fixture.repo.absoluteString)
        let branch = fixture.other.appendingPathComponent("alternate nested")
        _ = try await fixture.run(["copy", "--", fixture.other.appendingPathComponent("nested").path + "@", branch.path])
        _ = try await fixture.run(["commit", "-m", "copy nested fixture", "--", fixture.other.path + "@"])
        let branchURL = fixture.repo.appendingPathComponent("alternate nested")
        _ = try await fixture.run(["switch", "--", branchURL.absoluteString + "@", fixture.wc.appendingPathComponent("nested").path])
        let switched = try await client.workingHistoryURL(at: fixture.wc, path: "nested/file.txt")
        try expect(switched == branchURL.appendingPathComponent("file.txt").absoluteString, "History must use the switched child's actual SVN URL")
        try fixture.write("untracked file\n", to: fixture.wc.appendingPathComponent("untracked.txt"))
        for path in ["untracked.txt", "../outside", ".svn/wc.db", "nested/../file.txt", "/absolute"] {
            do {
                _ = try await client.workingHistoryURL(at: fixture.wc, path: path)
                throw CheckFailure.failed("Untracked or out-of-scope history targets must be rejected before remote access")
            } catch let failure as CheckFailure { throw failure }
            catch is SVNError { }
        }
        let untracked = fixture.wc.appendingPathComponent("untracked.txt")
        _ = try await fixture.run(["add", "--", untracked.path + "@"])
        do {
            _ = try await client.workingHistoryURL(at: fixture.wc, path: "untracked.txt")
            throw CheckFailure.failed("A newly added node without committed history must be rejected")
        } catch let failure as CheckFailure { throw failure }
        catch is SVNError { }
    }

    func testHistoryPagesKeepSnapshotAndMetadataReadOnly() async throws {
        let fixture = try await HistoryIncomingFixture.make()
        defer { fixture.remove() }
        for number in 2...5 {
            try fixture.write("revision \(number)\n", to: fixture.other.appendingPathComponent(fixture.name))
            _ = try await fixture.run(["commit", "--username", "history-author", "-m", "历史说明 \(number)", "--", fixture.other.path + "@"])
        }
        let client = fixture.client()
        let before = try await fixture.state()
        let original = try Data(contentsOf: fixture.wc.appendingPathComponent(fixture.name))
        let first = try await client.history(url: fixture.repo.absoluteString, limit: 2)
        try expect(first.entries.map(\.revision) == [5, 4] && first.hasMore && first.nextBeforeRevision == 3 && first.snapshotRevision == 5)
        try expect(first.entries.first?.author == "history-author" && first.entries.first?.message == "历史说明 5")
        try expect(first.entries.first?.date.isEmpty == false && first.entries.first?.paths.contains(where: { $0.path == "/" + fixture.name && $0.action == "M" && $0.kind == "file" }) == true)
        try fixture.write("race revision 6\n", to: fixture.other.appendingPathComponent(fixture.name))
        _ = try await fixture.run(["commit", "-m", "newer revision outside snapshot", "--", fixture.other.path + "@"])
        let second = try await client.history(url: fixture.repo.absoluteString, beforeRevision: first.nextBeforeRevision, snapshotRevision: first.snapshotRevision, limit: 2)
        let third = try await client.history(url: fixture.repo.absoluteString, beforeRevision: second.nextBeforeRevision, snapshotRevision: first.snapshotRevision, limit: 2)
        try expect(second.entries.map(\.revision) == [3, 2] && second.hasMore && second.nextBeforeRevision == 1)
        try expect(third.entries.map(\.revision) == [1] && !third.hasMore && third.nextBeforeRevision == nil)
        try expect(second.snapshotRevision == 5 && third.snapshotRevision == 5)
        let empty = try await client.history(url: fixture.repo.absoluteString, beforeRevision: 0, snapshotRevision: 5)
        try expect(empty.entries.isEmpty && !empty.hasMore)
        let after = try await fixture.state()
        try expect(after == before && Data(contentsOf: fixture.wc.appendingPathComponent(fixture.name)) == original)
    }

    func testHistoryComparisonTracksCopiesAndMislabeledTextWithoutWorkingCopy() async throws {
        let fixture = try await HistoryIncomingFixture.make()
        defer { fixture.remove() }
        let old = fixture.other.appendingPathComponent(fixture.name)
        try fixture.write("version 2 中文\n", to: old)
        _ = try await fixture.run(["propset", "svn:mime-type", "application/octet-stream", "--", old.path + "@"])
        _ = try await fixture.run(["commit", "-m", "mislabeled source", "--", fixture.other.path + "@"])
        let renamed = "重命名 @ 文件.cs"
        let new = fixture.other.appendingPathComponent(renamed)
        _ = try await fixture.run(["move", "--", old.path + "@", new.path])
        _ = try await fixture.run(["commit", "-m", "rename preserving history", "--", fixture.other.path + "@"])
        let url = fixture.repo.appendingPathComponent(renamed).absoluteString
        let client = fixture.client()
        let page = try await client.history(url: url)
        try expect(page.entries.map(\.revision) == [3, 2, 1])
        try expect(page.entries.first?.paths.contains(where: { $0.path == "/" + renamed && $0.copyFromPath == "/" + fixture.name && $0.copyFromRevision != nil }) == true)
        let compared = try await client.historyComparison(url: url, pegRevision: 3, leftRevision: 1, rightRevision: 3)
        try expect(compared.local.text == "base 中文\n" && compared.remote.text == "version 2 中文\n")
        try expect(compared.localLabel.contains("r1") && compared.remoteLabel.contains("r3"))
        let target = try await client.prepareRemoteFileDiff(at: fixture.wc, path: fixture.name)
        let specified = try await client.fileComparison(target, revision: .revision(2))
        try expect(specified.remote.text == "version 2 中文\n" && specified.remoteLabel.contains("r2"))
        _ = try await fixture.run(["delete", "--", new.path + "@"])
        _ = try await fixture.run(["commit", "-m", "delete fixture historical path", "--", fixture.other.path + "@"])
        do {
            _ = try await client.historyComparison(url: url, pegRevision: 3, leftRevision: 1, rightRevision: 4)
            throw CheckFailure.failed("A missing historical revision must not fall back to BASE or another path")
        } catch let failure as CheckFailure { throw failure }
        catch is SVNError { }
        let youngest = try await fixture.youngest()
        try expect(youngest == "4")
        try expect(try String(contentsOf: fixture.wc.appendingPathComponent(fixture.name), encoding: .utf8) == "base 中文\n")
    }

    func testHistoryRejectsMalformedAndBoundedResponsesAndCancels() async throws {
        let fixture = try await HistoryIncomingFixture.make()
        defer { fixture.remove() }
        for xml in ["<unexpected/>", "<log><logentry revision='bad'/></log>",
                    "<log><logentry revision='1'><paths><path action='M'>/../outside</path></paths></logentry></log>",
                    "<!DOCTYPE log [<!ENTITY injected 'value'>]><log><logentry revision='1'><msg>&injected;</msg></logentry></log>"] {
            let fake = try fixture.wrapper("if [ \"$1\" = log ]; then printf '%s' \(historyIncomingQuote(xml)); exit 0; fi")
            do {
                _ = try await fake.history(url: fixture.repo.absoluteString, snapshotRevision: 1)
                throw CheckFailure.failed("Malformed history response must be rejected")
            } catch let failure as CheckFailure { throw failure }
            catch is SVNError { }
        }
        let huge = try fixture.wrapper("if [ \"$1\" = log ]; then exec /usr/bin/yes x; fi")
        do {
            _ = try await huge.history(url: fixture.repo.absoluteString, snapshotRevision: 1)
            throw CheckFailure.failed("History output must be bounded")
        } catch let failure as CheckFailure { throw failure }
        catch let failure as SVNError { try expect(failure.localizedDescription.contains("16 MiB")) }
        let marker = fixture.root.appendingPathComponent("history.pid")
        let slow = try fixture.wrapper("if [ \"$1\" = log ]; then printf '%s' \"$$\" > \(historyIncomingQuote(marker.path)); exec /bin/sleep 30; fi")
        let task = Task { try await slow.history(url: fixture.repo.absoluteString, snapshotRevision: 1) }
        let pid = try await fixture.waitForPID(marker)
        task.cancel()
        do { _ = try await task.value; throw CheckFailure.failed("Cancelled history must fail") }
        catch is CancellationError { }
        try expect(kill(pid, 0) != 0, "The cancelled log process must be reaped")
    }
}

struct HistoryIncomingFixture {
    let root: URL
    let svn: URL
    let repo: URL
    let wc: URL
    let other: URL
    let config: URL
    let svnlook: URL
    let name = "中文 空格@源码.cs"

    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("SVNHistoryIncoming-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let bin = try require([FileManager.default.homeDirectoryForCurrentUser.path + "/.local/svn-cli/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].first {
            FileManager.default.isExecutableFile(atPath: $0 + "/svn") && FileManager.default.isExecutableFile(atPath: $0 + "/svnadmin")
        })
        let profile = root.appendingPathComponent("profile")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: false)
        let config = profile.appendingPathComponent("config")
        try "[miscellany]\nglobal-ignores =\n".write(to: config, atomically: true, encoding: .utf8)
        let svn = root.appendingPathComponent("isolated svn")
        try ("#!/bin/sh\nexec " + historyIncomingQuote(bin + "/svn") + " --config-dir " + historyIncomingQuote(profile.path) + " \"$@\"\n").write(to: svn, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: svn.path)
        let fixture = Self(root: root, svn: svn, repo: root.appendingPathComponent("repository"),
            wc: root.appendingPathComponent("working copy @"), other: root.appendingPathComponent("writer"),
            config: config, svnlook: URL(fileURLWithPath: bin + "/svnlook"))
        do {
            let seed = root.appendingPathComponent("seed")
            try fixture.write("base 中文\n", to: seed.appendingPathComponent(fixture.name))
            try fixture.write("local only\n", to: seed.appendingPathComponent("local-only.txt"))
            try fixture.write("delete later\n", to: seed.appendingPathComponent("remove.txt"))
            try fixture.write("nested\n", to: seed.appendingPathComponent("nested/file.txt"))
            let made = try await ProcessRunner.run(executable: bin + "/svnadmin", arguments: ["create", fixture.repo.path])
            guard made.exitCode == 0 else { throw CheckFailure.failed("Cannot create history fixture repository") }
            _ = try await fixture.run(["import", "--username", "fixture-author", "-m", "initial fixture", "--", seed.path, fixture.repo.absoluteString])
            _ = try await fixture.run(["checkout", "--", fixture.repo.absoluteString + "@", fixture.wc.path])
            _ = try await fixture.run(["checkout", "--", fixture.repo.absoluteString + "@", fixture.other.path])
            return fixture
        } catch { fixture.remove(); throw error }
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func client() -> SVNClient { SVNClient(executablePath: svn.path, globalIgnoreConfigurationFiles: [config]) }
    func write(_ text: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }
    func run(_ arguments: [String]) async throws -> String {
        let result = try await ProcessRunner.run(executable: svn.path, arguments: arguments)
        guard result.exitCode == 0 else {
            let detail = String(decoding: result.stderr, as: UTF8.self)
            let code = detail.range(of: "[EW][0-9]{6}", options: .regularExpression).map { String(detail[$0]) } ?? "no-code"
            throw CheckFailure.failed("Isolated history/incoming fixture failed (\(arguments.first ?? "command"), \(code))")
        }
        return result.text
    }
    func state() async throws -> String {
        let info = try await client().info(at: wc)
        let status = try await client().status(at: wc, showIgnored: true)
        return info.url + "#" + info.revision + status.map { "\($0.path)|\($0.item)|\($0.properties)" }.joined(separator: "\n")
    }
    func youngest() async throws -> String {
        let result = try await ProcessRunner.run(executable: svnlook.path, arguments: ["youngest", repo.path])
        guard result.exitCode == 0 else { throw CheckFailure.failed("Cannot inspect fixture youngest revision") }
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func wrapper(_ body: String) throws -> SVNClient {
        let file = root.appendingPathComponent("wrapper-\(UUID().uuidString)")
        try ("#!/bin/sh\n" + body + "\nexec " + historyIncomingQuote(svn.path) + " \"$@\"\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return SVNClient(executablePath: file.path, globalIgnoreConfigurationFiles: [config])
    }
    func waitForPID(_ marker: URL) async throws -> pid_t {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if let text = try? String(contentsOf: marker, encoding: .utf8), let pid = Int32(text) { return pid }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CheckFailure.failed("Fixture process did not start")
    }
}
func historyIncomingQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
