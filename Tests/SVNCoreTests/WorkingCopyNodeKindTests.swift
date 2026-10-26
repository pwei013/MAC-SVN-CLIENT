import Foundation
import SVNCore

struct WorkingCopyNodeKindTests {
    func testRealNodeKindsIncludeLinksAndMissingOrDeletedDirectories() async throws {
        let fixture = try NodeKindFixture()
        defer { fixture.remove() }
        let tools = try require([FileManager.default.homeDirectoryForCurrentUser.path + "/.local/svn-cli/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].first {
            FileManager.default.isExecutableFile(atPath: $0 + "/svn") && FileManager.default.isExecutableFile(atPath: $0 + "/svnadmin")
        }, "Node kind integration requires svn and svnadmin")
        let configDirectory = fixture.root.appendingPathComponent("profile")
        try fixture.write("[miscellany]\nglobal-ignores =\n", to: configDirectory.appendingPathComponent("config"))
        let svn = try fixture.executable("exec \(nodeKindQuote(tools + "/svn")) --config-dir \(nodeKindQuote(configDirectory.path)) \"$@\"")
        let seed = fixture.root.appendingPathComponent("seed")
        for name in ["plain-file", "folder.with.dot/child.cs", "待缺失 @目录/child.txt", "缺失 @文件", "deletedFolder/child.txt", "deleted-alone.cs", "-gone @目录/child.txt"] {
            try fixture.write("tracked original\n", to: seed.appendingPathComponent(name))
        }
        let repository = fixture.root.appendingPathComponent("repository")
        _ = try await fixture.run(URL(fileURLWithPath: tools + "/svnadmin"), ["create", repository.path])
        _ = try await fixture.run(svn, ["import", "-m", "node kind fixture", "--", seed.path, repository.absoluteString])
        let workingCopy = fixture.root.appendingPathComponent("working copy")
        _ = try await fixture.run(svn, ["checkout", "--", repository.absoluteString + "@", workingCopy.path])
        try fixture.write("tracked modification\n", to: workingCopy.appendingPathComponent("plain-file"))
        _ = try await fixture.run(svn, ["propset", "custom:icon-fixture", "changed", "--", "folder.with.dot@"], at: workingCopy)
        try fixture.write("untracked\n", to: workingCopy.appendingPathComponent("untracked.md"))
        try FileManager.default.createDirectory(at: workingCopy.appendingPathComponent("untracked.json"), withIntermediateDirectories: true)
        for name in ["待缺失 @目录", "缺失 @文件", "-gone @目录"] {
            try FileManager.default.removeItem(at: workingCopy.appendingPathComponent(name))
        }
        _ = try await fixture.run(svn, ["delete", "--", "deletedFolder@", "deleted-alone.cs@"], at: workingCopy)
        try FileManager.default.createSymbolicLink(at: workingCopy.appendingPathComponent("folder-link"), withDestinationURL: workingCopy.appendingPathComponent("folder.with.dot"))
        try FileManager.default.createSymbolicLink(at: workingCopy.appendingPathComponent("dangling-link"), withDestinationURL: workingCopy.appendingPathComponent("does-not-exist"))

        let client = SVNClient(executablePath: svn.path)
        let plain = try await client.status(at: workingCopy)
        try expect(plain.allSatisfy { $0.nodeKind == .unknown }, "Default status must not inspect icon metadata")
        let typed = try await client.status(at: workingCopy, includeNodeKinds: true)
        let byPath = Dictionary(uniqueKeysWithValues: typed.map { ($0.path, $0) })
        let expected: [String: WorkingCopyNodeKind] = [
            "plain-file": .file, "folder.with.dot": .directory, "untracked.md": .file,
            "untracked.json": .directory, "待缺失 @目录": .directory, "缺失 @文件": .file,
            "-gone @目录": .directory, "deletedFolder": .directory, "deleted-alone.cs": .file,
            "folder-link": .symbolicLink, "dangling-link": .symbolicLink
        ]
        for (path, kind) in expected { try expect(byPath[path]?.nodeKind == kind, "Unexpected node kind for \(path)") }
        if let implicitChild = byPath["deletedFolder/child.txt"] {
            try expect(implicitChild.nodeKind == .file, "A reported implicit directory-deletion child must retain its file type")
        }
        try expect(typed.map(\.path) == plain.map(\.path) && typed.map(\.item) == plain.map(\.item))
        try expect(byPath["plain-file"]?.canCommit == true && byPath["待缺失 @目录"]?.canCommit == false)
        let revision = try await fixture.run(URL(fileURLWithPath: tools + "/svnlook"), ["youngest", repository.path])
        try expect(revision.trimmingCharacters(in: .newlines) == "1", "Type lookup must not commit or change repository state")
    }

    func testMissingNodeMetadataUsesOneSafeBatchAndFailureDoesNotLoseStatus() async throws {
        let fixture = try NodeKindFixture()
        defer { fixture.remove() }
        let marker = fixture.root.appendingPathComponent("arguments")
        try fixture.write("existing\n", to: fixture.root.appendingPathComponent("existing.txt"))
        let statusXML = "<status><target path=\".\"><entry path=\"existing.txt\"><wc-status item=\"unversioned\" props=\"none\"/></entry><entry path=\"one@file\"><wc-status item=\"missing\" props=\"none\"/></entry><entry path=\"missing dir\"><wc-status item=\"deleted\" props=\"none\"/></entry><entry path=\"-missing\"><wc-status item=\"missing\" props=\"none\"/></entry><entry path=\"../outside\"><wc-status item=\"missing\" props=\"none\"/></entry></target></status>"
        let infoXML = "<info><entry path=\"one@file\" kind=\"file\"/><entry path=\"missing dir\" kind=\"dir\"/><entry path=\"-missing\" kind=\"dir\"/></info>"
        func command(_ infoBody: String) -> String {
            """
            printf '%s\\0' "$@" >> \(nodeKindQuote(marker.path))
            if [ "$1" = status ]; then
              printf '%s\\n' \(nodeKindQuote(statusXML))
            elif [ "$1" = info ]; then
              \(infoBody)
            fi
            """
        }
        let svn = try fixture.executable(command("printf '%s\\n' \(nodeKindQuote(infoXML))"))
        let client = SVNClient(executablePath: svn.path)
        let plain = try await client.status(at: fixture.root)
        var arguments = try fixture.arguments(marker)
        try expect(arguments.filter { $0 == "status" }.count == 1 && !arguments.contains("info"))
        try Data().write(to: marker)
        let typed = try await client.status(at: fixture.root, includeNodeKinds: true)
        arguments = try fixture.arguments(marker)
        try expect(arguments.filter { $0 == "status" }.count == 1 && arguments.filter { $0 == "info" }.count == 1)
        let infoStart = try require(arguments.firstIndex(of: "info"))
        let infoArguments = Array(arguments[infoStart...])
        let targets = ["-missing@", "missing dir@", "one@file@"]
        try expect(Array(infoArguments.suffix(3)) == targets && infoArguments.contains("--depth") && infoArguments.contains("empty"))
        try expect(!infoArguments.contains("../outside@") && !infoArguments.contains("--recursive"))
        let typedByPath = Dictionary(uniqueKeysWithValues: typed.map { ($0.path, $0.nodeKind) })
        try expect(typedByPath["existing.txt"] == .file && typedByPath["missing dir"] == .directory)
        try expect(typedByPath["one@file"] == .file && typedByPath["-missing"] == .directory && typedByPath["../outside"] == .unknown)

        for infoBody in ["printf '%s\\n' 'svn: E200000: fixture metadata failure' >&2; exit 1", "printf '%s\\n' '<malformed' "] {
            let failing = try fixture.executable(command(infoBody), name: "failing-\(UUID().uuidString)")
            let result = try await SVNClient(executablePath: failing.path).status(at: fixture.root, includeNodeKinds: true)
            try expect(result.map(\.path) == plain.map(\.path) && result.map(\.item) == plain.map(\.item), "Metadata failure must retain all SVN status rows")
            try expect(result.first(where: { $0.path == "existing.txt" })?.nodeKind == .file)
            try expect(result.filter { $0.path != "existing.txt" }.allSatisfy { $0.nodeKind == .unknown })
        }
    }
}

private struct NodeKindFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SVNNodeKindChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    func executable(_ body: String, name: String = "isolated svn") throws -> URL {
        let file = root.appendingPathComponent(name)
        try write("#!/bin/sh\n" + body + "\n", to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }
    func arguments(_ file: URL) throws -> [String] {
        try String(contentsOf: file, encoding: .utf8).split(separator: "\0").map(String.init)
    }
    @discardableResult
    func run(_ executable: URL, _ arguments: [String], at directory: URL? = nil) async throws -> String {
        let result = try await ProcessRunner.run(executable: executable.path, arguments: arguments, directory: directory)
        guard result.exitCode == 0 else { throw CheckFailure.failed("Node kind fixture command failed (\(result.exitCode))") }
        return result.text
    }
}

private func nodeKindQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
