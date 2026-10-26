import Foundation
import SVNCore

struct IgnoreScopeTests {
    func testScopeSuggestionsPreserveLiteralNamesAndSeparateGlobalWhitespace() throws {
        try expect(SVNIgnoreScope.allCases.count == 3)
        try expect(SVNIgnoreScope.userGlobal.propertyName == nil)
        try expect(SVNIgnoreScope.currentDirectory.propertyName == "svn:ignore")
        try expect(SVNIgnoreScope.directoryTree.propertyName == "svn:global-ignores")
        let name = "草稿 [1]*?%(name)s.ctx"
        let global = SVNIgnoreScope.userGlobal.suggestions(forName: name, isDirectory: false)
        try expect(global == SVNGlobalIgnores.suggestions(forName: name, isDirectory: false))
        try expect(global.first?.usesWhitespaceWildcard == true && global.first?.pattern.contains("[%]") == true)
        for scope in [SVNIgnoreScope.currentDirectory, .directoryTree] {
            let suggestions = scope.suggestions(forName: name, isDirectory: false)
            try expect(suggestions.map(\.kind) == [.fileName, .fileExtension])
            let literal = try require(suggestions.first)
            try expect(!literal.usesWhitespaceWildcard && literal.pattern.contains("草稿 ") && literal.pattern.contains("%(name)s"))
            try expect(literal.pattern != name, "Glob metacharacters must be escaped rather than broadening a filename rule")
            try expect(suggestions.last?.pattern == "*.ctx")
            let folder = scope.suggestions(forName: "缓存.v2 %", isDirectory: true)
            try expect(folder.count == 1 && folder.first?.kind == .directoryName && folder.first?.pattern == "缓存.v2 %")
            try expect(scope.suggestions(forName: ".env", isDirectory: false).count == 1)
            try expect(scope.suggestions(forName: "archive.tar.gz", isDirectory: false).last?.pattern == "*.gz")
            for invalid in ["", ".", "..", "parent/child", "line\nfeed", "nul\0name", "tab\tname"] {
                try expect(scope.suggestions(forName: invalid, isDirectory: false).isEmpty)
            }
        }
    }

    func testDirectoryScopesAppendToDirectParentAndRespectNativeScope() async throws {
        let fixture = try await ScopeIgnoreFixture.make()
        defer { fixture.remove() }
        let client = fixture.client()
        try await fixture.set("svn:ignore", "existing-local-only\n", at: fixture.nested)
        try await fixture.set("svn:global-ignores", "", at: fixture.nested)
        try await fixture.set("test:note", "preserve unrelated\n", at: fixture.nested)
        let explicitEmpty = try await client.directoryIgnoreSettings(at: fixture.nested)
        try expect(explicitEmpty.globalIgnores != nil, "Native explicit empty properties must remain present when editing the other property")
        let originalConfig = try Data(contentsOf: fixture.config)
        for relative in ["nested/one.extLocal", "nested/two.extLocal", "nested/deeper/one.extLocal", "other/one.extLocal"] {
            try fixture.write("local fixture\n", to: fixture.project.appendingPathComponent(relative))
        }
        let localPath = fixture.relativeProject + "/nested/one.extLocal"
        let localSuggestion = try require(SVNIgnoreScope.currentDirectory.suggestions(forName: "one.extLocal", isDirectory: false).last)
        let backups = fixture.root.appendingPathComponent("scope backups")
        let local = try await client.addDirectoryIgnore(at: fixture.wc, path: localPath, suggestion: localSuggestion,
            scope: .currentDirectory, backupDirectory: backups)
        try expect(local.changed && local.settings.directory.path == fixture.nested.path)
        try expect(local.settings.ignore?.contains("existing-local-only\n") == true)
        try expect(local.settings.ignore?.components(separatedBy: "\n").filter { $0 == localSuggestion.pattern }.count == 1)
        try expect(local.settings.globalIgnores == explicitEmpty.globalIgnores, "Adding svn:ignore must not delete or normalize the other explicit-empty property")
        let localStatus = try await client.status(at: fixture.project, showIgnored: true)
        try expect(localStatus.first(where: { $0.path == "nested/one.extLocal" })?.item == "ignored")
        try expect(localStatus.first(where: { $0.path == "nested/two.extLocal" })?.item == "ignored")
        try expect(localStatus.first(where: { $0.path == "nested/deeper/one.extLocal" })?.item == "unversioned")
        try expect(localStatus.first(where: { $0.path == "other/one.extLocal" })?.item == "unversioned")

        let backupCount = try FileManager.default.contentsOfDirectory(atPath: backups.path).count
        do {
            _ = try await client.addDirectoryIgnore(at: fixture.wc, path: localPath, suggestion: localSuggestion,
                scope: .currentDirectory, backupDirectory: backups)
            throw CheckFailure.failed("A repeated request for a now ignored row must be rejected as stale")
        } catch let error as CheckFailure { throw error }
        catch is SVNError { }
        try expect(try FileManager.default.contentsOfDirectory(atPath: backups.path).count == backupCount)
        let afterRepeat = try await client.directoryIgnoreSettings(at: fixture.nested)
        try expect(afterRepeat.ignore == local.settings.ignore && afterRepeat.globalIgnores == local.settings.globalIgnores)

        let folder = "缓存 [1]%(env)s"
        for relative in ["nested/" + folder + "/child.txt", "nested/deeper/" + folder + "/child.txt", "other/" + folder + "/child.txt"] {
            try fixture.write("local directory child\n", to: fixture.project.appendingPathComponent(relative))
        }
        let treeSuggestion = try require(SVNIgnoreScope.directoryTree.suggestions(forName: folder, isDirectory: true).first)
        let tree = try await client.addDirectoryIgnore(at: fixture.wc, path: fixture.relativeProject + "/nested/" + folder,
            suggestion: treeSuggestion, scope: .directoryTree, backupDirectory: backups)
        try expect(tree.changed && tree.settings.directory.path == fixture.nested.path)
        try expect(tree.settings.ignore == local.settings.ignore, "Adding svn:global-ignores must leave every byte of svn:ignore intact")
        try expect(tree.settings.globalIgnores?.components(separatedBy: "\n").filter { $0 == treeSuggestion.pattern }.count == 1)
        let treeStatus = try await client.status(at: fixture.project, showIgnored: true)
        try expect(treeStatus.first(where: { $0.path == "nested/" + folder })?.item == "ignored")
        try expect(treeStatus.first(where: { $0.path == "nested/deeper/" + folder })?.item == "ignored")
        try expect(treeStatus.first(where: { $0.path == "other/" + folder })?.item == "unversioned")

        let literalName = "草稿 [1]*?%(name)s.ctx"
        let peerName = "草稿 11ab%(name)s.ctx"
        try fixture.write("literal filename\n", to: fixture.other.appendingPathComponent(literalName))
        try fixture.write("similar filename\n", to: fixture.other.appendingPathComponent(peerName))
        let literalSuggestion = try require(SVNIgnoreScope.currentDirectory.suggestions(forName: literalName, isDirectory: false).first)
        _ = try await client.addDirectoryIgnore(at: fixture.wc, path: fixture.relativeProject + "/other/" + literalName,
            suggestion: literalSuggestion, scope: .currentDirectory, backupDirectory: backups)
        let literalStatus = try await client.status(at: fixture.other, showIgnored: true)
        try expect(literalStatus.first(where: { $0.path == literalName })?.item == "ignored")
        try expect(literalStatus.first(where: { $0.path == peerName })?.item == "unversioned", "Literal glob characters, spaces and percent signs must not ignore similar filenames")
        let note = try await fixture.value("test:note", at: fixture.nested)
        try expect(note == "preserve unrelated\n")
        try expect(try Data(contentsOf: fixture.config) == originalConfig, "Directory scopes must not modify user global config")
        try await fixture.assertNoSchedulingOrCommit()
    }

    func testDirectoryScopesRejectInvalidTargetsBeforeWriting() async throws {
        let fixture = try await ScopeIgnoreFixture.make()
        defer { fixture.remove() }
        let client = fixture.client()
        try await fixture.set("svn:ignore", "*.ignored\n", at: fixture.nested)
        try await fixture.set("test:note", "preserve original\n", at: fixture.nested)
        try fixture.write("untracked file\n", to: fixture.nested.appendingPathComponent("new.txt"))
        try fixture.write("ignored file\n", to: fixture.nested.appendingPathComponent("blocked.ignored"))
        let original = try await client.directoryIgnoreSettings(at: fixture.nested)
        let originalConfig = try Data(contentsOf: fixture.config)
        let valid = try require(SVNIgnoreScope.currentDirectory.suggestions(forName: "new.txt", isDirectory: false).first)
        let otherName = try require(SVNIgnoreScope.currentDirectory.suggestions(forName: "unrelated.bin", isDirectory: false).first)
        let wrongType = try require(SVNIgnoreScope.currentDirectory.suggestions(forName: "new.txt", isDirectory: true).first)
        let backups = fixture.root.appendingPathComponent("refused backups")
        let relative = fixture.relativeProject + "/nested/"
        let cases: [(String, SVNIgnoreSuggestion, SVNIgnoreScope)] = [
            (relative + "new.txt", valid, .userGlobal),
            (relative + "new.txt", otherName, .currentDirectory),
            (relative + "new.txt", wrongType, .directoryTree),
            (relative + "tracked.txt", try require(SVNIgnoreScope.currentDirectory.suggestions(forName: "tracked.txt", isDirectory: false).first), .currentDirectory),
            (relative + "blocked.ignored", try require(SVNIgnoreScope.currentDirectory.suggestions(forName: "blocked.ignored", isDirectory: false).first), .currentDirectory),
            ("", valid, .currentDirectory), ("../outside/new.txt", valid, .directoryTree),
            ("/absolute/new.txt", valid, .currentDirectory), (".svn/wc.db", valid, .currentDirectory),
            (relative + "../new.txt", valid, .directoryTree)
        ]
        for (path, suggestion, scope) in cases {
            try await fixture.expectRejected(path: path, suggestion: suggestion, scope: scope, backups: backups)
        }
        try FileManager.default.removeItem(at: fixture.nested.appendingPathComponent("new.txt"))
        try await fixture.expectRejected(path: relative + "new.txt", suggestion: valid, scope: .currentDirectory, backups: backups)
        let untrackedParent = fixture.project.appendingPathComponent("untracked-parent")
        try fixture.write("untracked parent\n", to: untrackedParent.appendingPathComponent("new.txt"))
        try await fixture.expectRejected(path: fixture.relativeProject + "/untracked-parent/new.txt", suggestion: valid, scope: .currentDirectory, backups: backups)
        try fixture.write("linked parent child\n", to: fixture.nested.appendingPathComponent("new.txt"))
        let linkedParent = fixture.project.appendingPathComponent("linked-parent")
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: fixture.nested)
        try await fixture.expectRejected(path: fixture.relativeProject + "/linked-parent/new.txt", suggestion: valid, scope: .directoryTree, backups: backups)
        try expect(!FileManager.default.fileExists(atPath: backups.path), "Invalid, stale and linked targets must stop before creating any backup")
        let after = try await client.directoryIgnoreSettings(at: fixture.nested)
        try expect(after.ignore == original.ignore && after.globalIgnores == original.globalIgnores)
        let note = try await fixture.value("test:note", at: fixture.nested)
        try expect(note == "preserve original\n")
        try expect(try Data(contentsOf: fixture.config) == originalConfig)
        try await fixture.assertNoSchedulingOrCommit()
    }
}

private struct ScopeIgnoreFixture {
    let root: URL
    let svn: URL
    let repository: URL
    let wc: URL
    let config: URL
    let svnlook: URL
    let relativeProject = "项目 目录@"
    var project: URL { wc.appendingPathComponent(relativeProject, isDirectory: true) }
    var nested: URL { project.appendingPathComponent("nested", isDirectory: true) }
    var other: URL { project.appendingPathComponent("other", isDirectory: true) }

    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("SVNIgnoreScopeChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let bin = try require([FileManager.default.homeDirectoryForCurrentUser.path + "/.local/svn-cli/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].first {
            FileManager.default.isExecutableFile(atPath: $0 + "/svn") && FileManager.default.isExecutableFile(atPath: $0 + "/svnadmin")
        })
        let profile = root.appendingPathComponent("profile")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let config = profile.appendingPathComponent("config")
        try "[miscellany]\nglobal-ignores = *.userkeep\n".write(to: config, atomically: true, encoding: .utf8)
        let svn = root.appendingPathComponent("isolated svn")
        try ("#!/bin/sh\nexec " + scopeIgnoreShellQuote(bin + "/svn") + " --config-dir " + scopeIgnoreShellQuote(profile.path) + " \"$@\"\n").write(to: svn, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: svn.path)
        let fixture = Self(root: root, svn: svn, repository: root.appendingPathComponent("repository"), wc: root.appendingPathComponent("工作副本 @", isDirectory: true), config: config,
            svnlook: URL(fileURLWithPath: bin + "/svnlook"))
        let seed = root.appendingPathComponent("seed")
        for path in ["nested/tracked.txt", "nested/deeper/keep.txt", "other/keep.txt"] {
            try fixture.write("tracked fixture\n", to: seed.appendingPathComponent(fixture.relativeProject + "/" + path))
        }
        let created = try await ProcessRunner.run(executable: bin + "/svnadmin", arguments: ["create", fixture.repository.path])
        guard created.exitCode == 0 else { fixture.remove(); throw CheckFailure.failed("Cannot create isolated scope repository") }
        _ = try await fixture.run(["import", "-m", "scope fixture", "--", seed.path, fixture.repository.absoluteString])
        _ = try await fixture.run(["checkout", "--", fixture.repository.absoluteString + "@", fixture.wc.path])
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
        guard result.exitCode == 0 else { throw CheckFailure.failed("Isolated scope SVN command failed (\(result.exitCode))") }
        return result.text
    }
    func set(_ name: String, _ value: String, at directory: URL) async throws {
        _ = try await run(["propset", name, value, "--", directory.path + "@"])
    }
    func value(_ name: String, at directory: URL) async throws -> String {
        try await run(["propget", "--strict", name, "--", directory.path + "@"])
    }
    func expectRejected(path: String, suggestion: SVNIgnoreSuggestion, scope: SVNIgnoreScope, backups: URL) async throws {
        do {
            _ = try await client().addDirectoryIgnore(at: wc, path: path, suggestion: suggestion, scope: scope, backupDirectory: backups)
            throw CheckFailure.failed("Invalid scope, suggestion or target must be rejected before writing")
        } catch let error as CheckFailure { throw error }
        catch is SVNError { }
    }
    func assertNoSchedulingOrCommit() async throws {
        let status = try await client().status(at: wc, showIgnored: true)
        try expect(!status.contains { ["added", "deleted", "replaced"].contains($0.item) })
        let result = try await ProcessRunner.run(executable: svnlook.path, arguments: ["youngest", repository.path])
        try expect(result.exitCode == 0 && result.text.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
    }
}
private func scopeIgnoreShellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
