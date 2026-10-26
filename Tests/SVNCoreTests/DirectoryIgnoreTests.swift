import Foundation
import SVNCore

struct DirectoryIgnoreTests {
    func testDirectoryIgnoreSettingsReadsLocalAndInheritedScope() async throws {
        let fixture = try await DirectoryIgnoreFixture.make()
        defer { fixture.remove() }
        try await fixture.set("svn:global-ignores", "*.root\n", at: fixture.wc)
        try await fixture.set("svn:ignore", "root-local-only\n", at: fixture.wc)
        try await fixture.set("svn:global-ignores", "*.parent\n", at: fixture.parent)
        try await fixture.set("svn:ignore", "parent-local-only\n", at: fixture.parent)
        try await fixture.set("svn:ignore", "file name\n*.local\n", at: fixture.target)
        try await fixture.set("svn:global-ignores", "*.child\n", at: fixture.target)
        try await fixture.set("test:note", "unrelated fixture\n", at: fixture.target)
        let settings = try await fixture.client().directoryIgnoreSettings(at: fixture.target)
        try expect(settings.directory.path == fixture.target.path && settings.workingCopyRoot.path == fixture.wc.path)
        try expect(settings.ignore == "file name\n*.local\n" && settings.globalIgnores == "*.child\n")
        try expect(settings.inherited.count == 2 && settings.inherited.allSatisfy { $0.name == "svn:global-ignores" && $0.inherited })
        try expect(Set(settings.inherited.map(\.source)) == [fixture.wc.path, fixture.parent.path], "Local inherited sources must be real absolute ancestor paths")
        try expect(!settings.inherited.contains { $0.value.contains("local-only") }, "Parent svn:ignore is not inherited")

        _ = try await fixture.run(["commit", "-m", "inherited fixture", "--", fixture.wc.path + "@"])
        let partial = fixture.root.appendingPathComponent("partial checkout", isDirectory: true)
        let url = fixture.repository.appendingPathComponent("祖先 @").appendingPathComponent("项目 目录@")
        _ = try await fixture.run(["checkout", "--", url.absoluteString + "@", partial.path])
        let remote = try await fixture.client().directoryIgnoreSettings(at: partial)
        try expect(remote.inherited.count == 2 && remote.inherited.allSatisfy { $0.source.hasPrefix("file://") })
        try expect(remote.ignore == settings.ignore && remote.globalIgnores == settings.globalIgnores)
        let result = try await fixture.client().saveDirectoryIgnores(using: remote, ignore: "new partial rule", globalIgnores: remote.globalIgnores ?? "",
            backupDirectory: fixture.root.appendingPathComponent("partial backups"))
        try expect(result.settings.ignore == "new partial rule\n" && result.settings.inherited.count == 2, "Remote inherited sources remain read-only while local properties can be edited")
        let revision = try await fixture.youngest()
        try expect(revision == "2")
    }

    func testDirectoryIgnoreSavePreservesSpacesAndClearsOnlyLocalProperties() async throws {
        let fixture = try await DirectoryIgnoreFixture.make()
        defer { fixture.remove() }
        try await fixture.set("svn:global-ignores", "*.ancestor\n", at: fixture.wc)
        try await fixture.set("svn:ignore", "old name\n", at: fixture.target)
        try await fixture.set("svn:global-ignores", "*.old\n", at: fixture.target)
        try await fixture.set("test:note", "preserve unrelated\n", at: fixture.target)
        for name in [" file name ", "a.new", "a.child", "x.ancestor", "nested/a.new", "nested/a.child"] {
            try fixture.write("local fixture\n", to: fixture.target.appendingPathComponent(name))
        }
        let baseline = try await fixture.client().directoryIgnoreSettings(at: fixture.target)
        let backupBase = fixture.root.appendingPathComponent("backups")
        let result = try await fixture.client().saveDirectoryIgnores(using: baseline,
            ignore: " file name \r\n*.new", globalIgnores: "*.child", backupDirectory: backupBase)
        try expect(result.changed && result.settings.ignore == " file name \n*.new\n" && result.settings.globalIgnores == "*.child\n")
        let note = try await fixture.value("test:note", at: fixture.target)
        try expect(note == "preserve unrelated\n")
        let folder = try require(result.backupDirectory)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        try expect(Set(names) == ["0-original-property.txt", "0-updated-property.txt", "1-original-property.txt", "1-updated-property.txt", "sources.json"])
        for name in names {
            let mode = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.posixPermissions] as? NSNumber
            try expect(mode?.intValue == 0o600)
        }
        try expect(try String(contentsOf: folder.appendingPathComponent("0-original-property.txt"), encoding: .utf8) == "old name\n")
        let shown = try await fixture.client().status(at: fixture.target, showIgnored: true)
        try expect(shown.first(where: { $0.path == " file name " })?.item == "ignored")
        try expect(shown.first(where: { $0.path == "nested/a.new" })?.item == "unversioned", "Local svn:ignore must not affect descendant directories")
        try expect(shown.first(where: { $0.path == "nested/a.child" })?.item == "ignored", "Local svn:global-ignores must affect descendants")
        let noChange = try await fixture.client().saveDirectoryIgnores(using: result.settings,
            ignore: result.settings.ignore ?? "", globalIgnores: result.settings.globalIgnores ?? "", backupDirectory: backupBase)
        try expect(!noChange.changed && noChange.backupDirectory == nil)
        let cleared = try await fixture.client().saveDirectoryIgnores(using: noChange.settings, ignore: "", globalIgnores: "\r\n\n", backupDirectory: backupBase)
        try expect(cleared.changed && cleared.settings.ignore == nil && cleared.settings.globalIgnores == nil)
        try expect(cleared.settings.inherited.count == 1)
        let after = try await fixture.client().status(at: fixture.target, showIgnored: true)
        try expect(after.first(where: { $0.path == "x.ancestor" })?.item == "ignored")
        try expect(after.first(where: { $0.path == "a.new" })?.item == "unversioned")
        try await fixture.assertNoSchedulingOrCommit()
    }

    func testDirectoryIgnoreSaveRejectsDriftAndInvalidControlsBeforeWriting() async throws {
        let fixture = try await DirectoryIgnoreFixture.make()
        defer { fixture.remove() }
        try await fixture.set("svn:ignore", "*.original\n", at: fixture.target)
        try await fixture.set("test:note", "first\n", at: fixture.target)
        var baseline = try await fixture.client().directoryIgnoreSettings(at: fixture.target)
        let backups = fixture.root.appendingPathComponent("backups")
        for value in ["nul\0name", "escape\u{1B}", "tab\tname"] {
            do {
                _ = try await fixture.client().saveDirectoryIgnores(using: baseline, ignore: value, globalIgnores: "", backupDirectory: backups)
                throw CheckFailure.failed("Control characters must be rejected before writing")
            } catch let error as CheckFailure { throw error }
            catch is SVNError { }
        }
        try await fixture.set("svn:ignore", "*.external\n", at: fixture.target)
        try await fixture.expectStale(baseline, backupDirectory: backups)
        baseline = try await fixture.client().directoryIgnoreSettings(at: fixture.target)
        try await fixture.set("test:note", "second\n", at: fixture.target)
        try await fixture.expectStale(baseline, backupDirectory: backups)
        baseline = try await fixture.client().directoryIgnoreSettings(at: fixture.target)
        try await fixture.set("svn:global-ignores", "*.new-ancestor\n", at: fixture.parent)
        try await fixture.expectStale(baseline, backupDirectory: backups)
        try expect(!FileManager.default.fileExists(atPath: backups.path), "Drift must stop before creating backups or writing properties")
        let externalIgnore = try await fixture.value("svn:ignore", at: fixture.target)
        let externalNote = try await fixture.value("test:note", at: fixture.target)
        try expect(externalIgnore == "*.external\n")
        try expect(externalNote == "second\n")
        try await fixture.assertNoSchedulingOrCommit()
    }

    func testDirectoryIgnoreSettingsRejectsUnsafeTargetsAndSupportsAddedDirectories() async throws {
        let fixture = try await DirectoryIgnoreFixture.make()
        defer { fixture.remove() }
        let outside = fixture.root.appendingPathComponent("outside")
        let untracked = fixture.wc.appendingPathComponent("untracked")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: untracked, withIntermediateDirectories: true)
        let link = fixture.root.appendingPathComponent("linked-directory")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.target)
        let ancestorLink = fixture.root.appendingPathComponent("linked-parent")
        try FileManager.default.createSymbolicLink(at: ancestorLink, withDestinationURL: fixture.parent)
        for directory in [outside, untracked, link, ancestorLink.appendingPathComponent("项目 目录@"), fixture.target.appendingPathComponent("tracked.txt"), fixture.wc.appendingPathComponent(".svn"), URL(string: "https://example.invalid/repo")!] {
            do {
                _ = try await fixture.client().directoryIgnoreSettings(at: directory)
                throw CheckFailure.failed("Unsafe or unversioned directory must be rejected")
            } catch let error as CheckFailure { throw error }
            catch is SVNError { }
        }
        let conflictClient = try fixture.makeClientWrapper("""
        if [ "$1" = status ]; then
            printf '%s\\n' '<status><target path="."><entry path="."><wc-status item="normal" props="conflicted" tree-conflicted="true"/></entry></target></status>'
            exit 0
        fi
        """, name: "conflict svn")
        do {
            _ = try await conflictClient.directoryIgnoreSettings(at: fixture.target)
            throw CheckFailure.failed("Conflicted directory must be rejected")
        } catch let error as CheckFailure { throw error }
        catch is SVNError { }
        _ = try await fixture.run(["delete", "--keep-local", "--force", "--", fixture.target.path + "@"])
        do {
            _ = try await fixture.client().directoryIgnoreSettings(at: fixture.target)
            throw CheckFailure.failed("Scheduled-deleted directory must be rejected")
        } catch let error as CheckFailure { throw error }
        catch is SVNError { }
        _ = try await fixture.run(["revert", "--depth", "infinity", "--", fixture.target.path + "@"])
        let added = fixture.wc.appendingPathComponent("新增 @目录")
        try FileManager.default.createDirectory(at: added, withIntermediateDirectories: true)
        _ = try await fixture.run(["add", "--", added.path + "@"])
        let addedSettings = try await fixture.client().directoryIgnoreSettings(at: added)
        let result = try await fixture.client().saveDirectoryIgnores(using: addedSettings, ignore: "space name", globalIgnores: "", backupDirectory: fixture.root.appendingPathComponent("added backups"))
        try expect(result.settings.ignore == "space name\n")
        let revision = try await fixture.youngest()
        try expect(revision == "1")
    }

    func testDirectoryIgnoreSaveFailureIsNotReplayedAndReportsBackups() async throws {
        let fixture = try await DirectoryIgnoreFixture.make()
        defer { fixture.remove() }
        try await fixture.set("svn:ignore", "*.old\n", at: fixture.target)
        try await fixture.set("svn:global-ignores", "*.old-global\n", at: fixture.target)
        let marker = fixture.root.appendingPathComponent("writes.log")
        let client = try fixture.makeClientWrapper("""
        if [ "$1" = propset ] || [ "$1" = propdel ]; then
            printf '%s\\n' "$1" >> \(directoryIgnoreShellQuote(marker.path))
            \(directoryIgnoreShellQuote(fixture.svn.path)) "$@" >/dev/null || exit "$?"
            printf '%s\\n' 'svn: E200009: simulated response failure' >&2
            exit 1
        fi
        """, name: "failing svn")
        let baseline = try await client.directoryIgnoreSettings(at: fixture.target)
        let backups = fixture.root.appendingPathComponent("failure backups")
        do {
            _ = try await client.saveDirectoryIgnores(using: baseline, ignore: "*.new", globalIgnores: "*.new-global", backupDirectory: backups)
            throw CheckFailure.failed("Ambiguous write result must fail without replay")
        } catch let error as CheckFailure { throw error }
        catch let error as SVNError {
            try expect(error.localizedDescription.contains("部分本地目录属性可能已经修改") && error.localizedDescription.contains(backups.path))
        }
        let writes = try String(contentsOf: marker, encoding: .utf8).split(separator: "\n")
        try expect(writes.count == 1, "Never replay a failed write or continue to the second property")
        let actualIgnore = try await fixture.value("svn:ignore", at: fixture.target)
        let actualGlobal = try await fixture.value("svn:global-ignores", at: fixture.target)
        try expect(actualIgnore == "*.new\n")
        try expect(actualGlobal == "*.old-global\n")
        let folders = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        try expect(folders.count == 1)
        try expect(try String(contentsOf: folders[0].appendingPathComponent("0-original-property.txt"), encoding: .utf8) == "*.old\n")
        try expect(FileManager.default.fileExists(atPath: folders[0].appendingPathComponent("sources.json").path))
        try await fixture.assertNoSchedulingOrCommit()
    }
}

private struct DirectoryIgnoreFixture {
    let root: URL
    let svn: URL
    let repository: URL
    let wc: URL
    let config: URL
    let svnlook: URL
    var parent: URL { wc.appendingPathComponent("祖先 @", isDirectory: true) }
    var target: URL { parent.appendingPathComponent("项目 目录@", isDirectory: true) }

    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("SVNDirectoryIgnoreChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let bin = try require([FileManager.default.homeDirectoryForCurrentUser.path + "/.local/svn-cli/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].first {
            FileManager.default.isExecutableFile(atPath: $0 + "/svn") && FileManager.default.isExecutableFile(atPath: $0 + "/svnadmin")
        })
        let configDirectory = root.appendingPathComponent("profile")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let config = configDirectory.appendingPathComponent("config")
        try "[miscellany]\nglobal-ignores =\n".write(to: config, atomically: true, encoding: .utf8)
        let svn = root.appendingPathComponent("isolated svn")
        try ("#!/bin/sh\nexec " + directoryIgnoreShellQuote(bin + "/svn") + " --config-dir " + directoryIgnoreShellQuote(configDirectory.path) + " \"$@\"\n").write(to: svn, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: svn.path)
        let fixture = Self(root: root, svn: svn, repository: root.appendingPathComponent("repository"), wc: root.appendingPathComponent("工作副本 @", isDirectory: true), config: config,
            svnlook: URL(fileURLWithPath: bin + "/svnlook"))
        let seed = root.appendingPathComponent("seed", isDirectory: true)
        try fixture.write("tracked fixture\n", to: seed.appendingPathComponent("祖先 @/项目 目录@/tracked.txt"))
        try fixture.write("tracked nested\n", to: seed.appendingPathComponent("祖先 @/项目 目录@/nested/keep.txt"))
        let created = try await ProcessRunner.run(executable: bin + "/svnadmin", arguments: ["create", fixture.repository.path])
        guard created.exitCode == 0 else { fixture.remove(); throw CheckFailure.failed("Cannot create isolated directory-ignore repository") }
        _ = try await fixture.run(["import", "-m", "directory ignore fixture", "--", seed.path, fixture.repository.absoluteString])
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
        let output = try await ProcessRunner.run(executable: svn.path, arguments: arguments)
        guard output.exitCode == 0 else { throw CheckFailure.failed("Isolated directory-ignore command failed (\(output.exitCode))") }
        return output.text
    }
    func set(_ name: String, _ value: String, at directory: URL) async throws {
        _ = try await run(["propset", name, value, "--", directory.path + "@"])
    }
    func value(_ name: String, at directory: URL) async throws -> String {
        try await run(["propget", "--strict", name, "--", directory.path + "@"])
    }
    func youngest() async throws -> String {
        let output = try await ProcessRunner.run(executable: svnlook.path, arguments: ["youngest", repository.path])
        guard output.exitCode == 0 else { throw CheckFailure.failed("Cannot inspect isolated repository revision") }
        return output.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func assertNoSchedulingOrCommit() async throws {
        let status = try await client().status(at: wc, showIgnored: true)
        try expect(!status.contains { ["added", "deleted", "replaced"].contains($0.item) })
        let revision = try await youngest()
        try expect(revision == "1")
    }
    func expectStale(_ baseline: SVNDirectoryIgnoreSettings, backupDirectory: URL) async throws {
        do {
            _ = try await client().saveDirectoryIgnores(using: baseline, ignore: "replacement", globalIgnores: "*.replacement", backupDirectory: backupDirectory)
            throw CheckFailure.failed("A stale directory or inheritance preview must not write")
        } catch let error as CheckFailure { throw error }
        catch is SVNError { }
    }
    func makeClientWrapper(_ body: String, name: String) throws -> SVNClient {
        let file = root.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\nexec " + directoryIgnoreShellQuote(svn.path) + " \"$@\"\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return SVNClient(executablePath: file.path, globalIgnoreConfigurationFiles: [config])
    }
}
private func directoryIgnoreShellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
