import Darwin
import Foundation
import SVNCore

struct RepositorySearchTests {
    func testRealRecursiveSearchKeepsDistinctPathsAndMetadata() async throws {
        let fixture = try SearchCheckFixture()
        defer { fixture.remove() }
        let tools = try fixture.localTools()
        let repository = fixture.root.appendingPathComponent("repository")
        let seed = fixture.root.appendingPathComponent("seed")
        let trunk = repository.appendingPathComponent("trunk")
        try await fixture.run(tools.svnadmin, ["create", repository.path])
        try fixture.write("first content\n", to: seed.appendingPathComponent("服务 Code/中文 @目录/Shared.txt"))
        try fixture.write("second content\n", to: seed.appendingPathComponent("服务 Code/other/shared.TXT"))
        try fixture.write("literal name\n", to: seed.appendingPathComponent("服务 Code/中文 @目录/a%20#?.txt"))
        try fixture.write("unrelated\n", to: seed.appendingPathComponent("untouched/skip.txt"))
        try await fixture.run(tools.svn, ["import", "--non-interactive", "-m", "search fixture", "--", seed.path, trunk.absoluteString])
        let client = SVNClient(executablePath: tools.svn.path)

        let shared = try await client.search(url: trunk.absoluteString, query: "  SHARED  ")
        try expect(Set(shared.entries.map(\.name)) == ["服务 Code/中文 @目录/Shared.txt", "服务 Code/other/shared.TXT"])
        try expect(shared.totalMatches == 2 && !shared.isTruncated)
        try expect(Set(shared.entries.map(\.id)).count == 2, "Equal basenames in different directories must stay selectable independently")
        try expect(shared.entries.allSatisfy { !$0.isDirectory && $0.revision == "1" && !$0.author.isEmpty && $0.lastCommitDate != nil })
        try expect(shared.entries.first(where: { $0.name.hasSuffix("Shared.txt") })?.size == Int64(Data("first content\n".utf8).count))

        let byParent = try await client.search(url: trunk.absoluteString, query: "服务 code")
        try expect(byParent.totalMatches == 6, "A parent-path keyword must also match its nested files")
        try expect(byParent.entries.contains { $0.name == "服务 Code/中文 @目录/a%20#?.txt" })
        let byChinese = try await client.search(url: trunk.absoluteString, query: "中文")
        try expect(byChinese.totalMatches == 3)
        let directories = try await client.search(url: trunk.absoluteString, query: "服务 code", directoriesOnly: true)
        try expect(directories.totalMatches == 3 && directories.entries.allSatisfy(\.isDirectory))
        let exactName = "服务 Code/中文 @目录/a%20#?.txt"
        let target = try SVNLocation.child(exactName, of: trunk.absoluteString)
        let content = try await ProcessRunner.run(executable: tools.svn.path, arguments: ["cat", "--non-interactive", "--", target + "@"])
        try expect(content.exitCode == 0 && content.text == "literal name\n", "A selected special-character result must resolve to the original repository item")
    }

    func testSearchParserFiltersFullPathsAndPreservesMetadataWithoutSorting() throws {
        let result = try SVNXML.searchList(Data("""
        <lists><list path="https://example.invalid/repo">
          <entry kind="file"><name>Parent/子目录/Z10.txt</name><size>42</size><commit revision="12"><author>甲 &amp; 乙</author><date>2026-10-23T02:00:00.123456Z</date></commit></entry>
          <entry kind="file"><name>unrelated.txt</name><size>not-a-size</size><commit><date>not-a-date</date></commit></entry>
          <entry kind="dir"><name>Parent/子目录/A2</name><commit revision="3"/></entry>
        </list></lists>
        """.utf8), query: "parent/子目录")
        try expect(result.entries.map(\.name) == ["Parent/子目录/Z10.txt", "Parent/子目录/A2"], "Parsing preserves server order; the UI sorts only bounded results")
        try expect(result.totalMatches == 2 && !result.isTruncated)
        let file = try require(result.entries.first)
        try expect(file.author == "甲 & 乙" && file.revision == "12" && file.size == 42)
        try expect(file.lastCommitDate != nil && file.date == "2026-10-23T02:00:00.123456Z")
        try expect(result.entries.last?.isDirectory == true && result.entries.last?.lastCommitDate == nil)
    }

    func testDirectoriesOnlyFiltersBeforeLimitAndCountsOnlyFolders() throws {
        var xml = "<lists><list>"
        for index in 0..<20 {
            xml += "<entry kind=\"file\"><name>project/file\(index).log</name></entry>"
        }
        xml += "<entry kind=\"dir\"><name>project/目录1</name><commit revision=\"7\"/></entry>"
        xml += "<entry kind=\"dir\"><name>project/目录2</name><commit revision=\"8\"/></entry></list></lists>"
        let result = try SVNXML.searchList(Data(xml.utf8), query: "project", limit: 1, directoriesOnly: true)
        try expect(result.totalMatches == 2 && result.isTruncated)
        try expect(result.entries.map(\.name) == ["project/目录1"])
        try expect(result.entries.first?.revision == "7" && result.entries.first?.isDirectory == true)
        let filesOnlyMatch = try SVNXML.searchList(Data(xml.utf8), query: ".log", directoriesOnly: true)
        try expect(filesOnlyMatch.totalMatches == 0 && filesOnlyMatch.entries.isEmpty)
    }

    func testSearchParserBoundsResultsButCountsAllMatches() throws {
        var xml = "<lists><list path=\"file:///fixture\">"
        for index in 0..<6000 {
            xml += "<entry kind=\"file\"><name>match/\(index).txt</name><size>\(index)</size><commit revision=\"\(index)\"><date>2026-10-23T00:00:00Z</date></commit></entry>"
            xml += "<entry kind=\"file\"><name>excluded/\(index).txt</name><commit><date>not-a-date</date></commit></entry>"
        }
        xml += "</list></lists>"
        let data = Data(xml.utf8)
        let bounded = try SVNXML.searchList(data, query: "match", limit: 3)
        try expect(bounded.entries.map(\.name) == ["match/0.txt", "match/1.txt", "match/2.txt"])
        try expect(bounded.totalMatches == 6000 && bounded.isTruncated)
        try expect(bounded.entries.allSatisfy { $0.lastCommitDate != nil })
        let standard = try SVNXML.searchList(data, query: "match")
        try expect(standard.entries.count == 5000 && standard.totalMatches == 6000 && standard.isTruncated)
        let minimum = try SVNXML.searchList(data, query: "match", limit: -5)
        try expect(minimum.entries.count == 1 && minimum.totalMatches == 6000)
        let none = try SVNXML.searchList(data, query: "absent")
        try expect(none.entries.isEmpty && none.totalMatches == 0 && !none.isTruncated)
    }

    func testSearchRejectsMalformedXMLAndBlankQueries() throws {
        for invalid in ["<lists><list><entry kind=\"file\"><name>match</name></entry>",
                        "<lists><list><entry><name>match</name></entry></list></lists><extra/>",
                        "<info/>", ""] {
            try expectThrows(SVNError.self) { try SVNXML.searchList(Data(invalid.utf8), query: "match") }
        }
        for blank in ["", " \n\t "] {
            try expectThrows(SVNError.self) { try SVNXML.searchList(Data("<lists/>".utf8), query: blank) }
        }
        let empty = try SVNXML.searchList(Data("<lists><list path=\"file:///fixture\"/></lists>".utf8), query: "x")
        try expect(empty.entries.isEmpty && empty.totalMatches == 0)
    }

    func testBlankClientSearchDoesNotLaunchAnyCommand() async throws {
        let fixture = try SearchCheckFixture()
        defer { fixture.remove() }
        let marker = fixture.root.appendingPathComponent("calls")
        let executable = try fixture.makeExecutable("printf launched > \(searchShellQuote(marker.path))\nexit 90")
        let client = SVNClient(executablePath: executable.path)
        for query in ["", " \n\t "] {
            do {
                _ = try await client.search(url: "https://example.invalid/repo", query: query)
                throw CheckFailure.failed("Blank search must be rejected")
            } catch let error as CheckFailure { throw error }
            catch is SVNError { }
        }
        try expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    func testClientSearchUsesOneAuthenticatedRecursiveListAndRedactsErrors() async throws {
        let fixture = try SearchCheckFixture()
        defer { fixture.remove() }
        let marker = fixture.root.appendingPathComponent("arguments")
        let password = "synthetic-search-password"
        let xml = "<lists><list path=\"https://example.invalid/repo\"><entry kind=\"file\"><name>folder/target.txt</name><size>7</size></entry></list></lists>"
        let executable = try fixture.makeExecutable("""
        for task_argument in "$@"; do
            if [ "$task_argument" = \(searchShellQuote(password)) ]; then exit 91; fi
        done
        printf '%s\\n' "$@" > \(searchShellQuote(marker.path))
        IFS= read -r task_password
        if [ "$task_password" != \(searchShellQuote(password)) ]; then exit 92; fi
        printf '%s\\n' \(searchShellQuote(xml))
        """)
        let client = SVNClient(executablePath: executable.path, credentials: .init(username: "fixture-user", password: password))
        let result = try await client.search(url: "https://example.invalid/repo", query: "target")
        try expect(result.entries.map(\.name) == ["folder/target.txt"])
        let arguments = try String(contentsOf: marker, encoding: .utf8).split(separator: "\n").map(String.init)
        try expect(arguments == ["list", "--non-interactive", "--no-auth-cache", "--username", "fixture-user", "--password-from-stdin", "--xml", "--depth", "infinity", "--", "https://example.invalid/repo@"])
        let failing = try fixture.makeExecutable("""
        IFS= read -r task_password
        printf 'svn: E170001: fixture denial %s\\n' "$task_password" >&2
        exit 1
        """, name: "failing svn")
        do {
            _ = try await SVNClient(executablePath: failing.path, credentials: client.credentials).search(url: "https://example.invalid/repo", query: "target")
            throw CheckFailure.failed("Failed authentication must be reported")
        } catch let error as CheckFailure { throw error }
        catch let error as SVNError {
            try expect(error.isAuthenticationFailure)
            try expect(!error.localizedDescription.contains(password) && error.localizedDescription.contains("[已隐藏]"))
        }
    }

    func testCancellingSearchTerminatesTheRecursiveList() async throws {
        let fixture = try SearchCheckFixture()
        defer { fixture.remove() }
        let marker = fixture.root.appendingPathComponent("search.pid")
        let executable = try fixture.makeExecutable("""
        printf '%s\\n' "$$" > \(searchShellQuote(marker.path))
        exec /bin/sleep 30
        """)
        let task = Task {
            try await SVNClient(executablePath: executable.path).search(url: "https://example.invalid/repo", query: "target")
        }
        var taskPID: pid_t?
        defer {
            task.cancel()
            if let taskPID, kill(taskPID, 0) == 0 { _ = kill(taskPID, SIGTERM) }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while taskPID == nil && ContinuousClock.now < deadline {
            if let content = try? String(contentsOf: marker, encoding: .utf8) {
                taskPID = Int32(content.trimmingCharacters(in: .whitespacesAndNewlines))
            } else { try await Task.sleep(for: .milliseconds(10)) }
        }
        let pid = try require(taskPID, "The recursive list must start before cancellation")
        task.cancel()
        do {
            _ = try await task.value
            throw CheckFailure.failed("Cancelled recursive list must throw CancellationError")
        } catch is CancellationError { }
        let exists = kill(pid, 0) == 0
        try expect(!exists, "The recursive list must be terminated and reaped")
        if !exists { taskPID = nil }
    }

    func testSearchParsingHonoursTaskCancellation() async throws {
        let xml = Data(("<lists><list>" + String(repeating: "<entry kind=\"file\"><name>excluded.txt</name><commit><date>invalid</date></commit></entry>", count: 100_000) + "</list></lists>").utf8)
        let started = SearchCheckFlag()
        let task = Task.detached {
            started.set()
            return try SVNXML.searchList(xml, query: "absent")
        }
        defer { task.cancel() }
        while !started.value { try await Task.sleep(for: .milliseconds(1)) }
        task.cancel()
        let began = ContinuousClock.now
        do {
            _ = try await task.value
            throw CheckFailure.failed("Cancelled XML parsing must not return a partial result")
        } catch is CancellationError { }
        try expect(began.duration(to: ContinuousClock.now) < .seconds(3))
    }

    func testRecursiveChildURLPreservesLiteralSegmentsAndRejectsEscapePaths() throws {
        let parent = "https://example.invalid/repository/父目录"
        let relative = "code/中文 @目录/a%20#?.txt"
        let value = try SVNLocation.child(relative, of: parent)
        let url = try require(URL(string: value))
        try expect(url.path(percentEncoded: false) == "/repository/父目录/" + relative)
        try expect(url.query == nil && url.fragment == nil)
        try expect(value.contains("a%2520%23%3F.txt"), "Literal percent, # and ? must remain part of the filename")
        let encodedLooking = try SVNLocation.child("%2E%2E/%2Fname", of: parent)
        try expect(URL(string: encodedLooking)?.path(percentEncoded: false) == "/repository/父目录/%2E%2E/%2Fname")
        for invalid in ["", "/absolute", "a//b", "a/", ".", "..", "a/./b", "a/../b", "a\0b"] {
            try expectThrows(SVNError.self, "Invalid relative path: \(invalid)") { try SVNLocation.child(invalid, of: parent) }
        }
    }
}

private final class SearchCheckFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return storage }
    func set() { lock.lock(); defer { lock.unlock() }; storage = true }
}

private struct SearchCheckFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SVNRepositorySearch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    func makeExecutable(_ body: String, name: String = "mock svn") throws -> URL {
        let executable = root.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }
    func localTools() throws -> (svn: URL, svnadmin: URL) {
        let directories = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/svn-cli/bin").path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for directory in directories {
            let svn = URL(fileURLWithPath: directory).appendingPathComponent("svn")
            let svnadmin = URL(fileURLWithPath: directory).appendingPathComponent("svnadmin")
            if FileManager.default.isExecutableFile(atPath: svn.path), FileManager.default.isExecutableFile(atPath: svnadmin.path) {
                return (svn, svnadmin)
            }
        }
        throw CheckFailure.failed("Recursive search integration requires local svn and svnadmin")
    }
    @discardableResult
    func run(_ executable: URL, _ arguments: [String]) async throws -> String {
        let output = try await ProcessRunner.run(executable: executable.path, arguments: arguments)
        guard output.exitCode == 0 else { throw CheckFailure.failed("Temporary SVN fixture command failed (\(output.exitCode))") }
        return output.text
    }
}

private func searchShellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
