import Foundation
import SVNCore

struct NativeUnignoreTests {
    func testCombinedSourcesAndAncestorOutsideOpenedScopePreserveOtherRules() async throws {
        let fixture = try await NativeIgnoreFixture.make()
        defer { fixture.remove() }
        try fixture.write("[miscellany]\nglobal-ignores = *.native *.keep\n", to: fixture.config)
        try await fixture.set("svn:global-ignores", "*.native\n*.rootkeep\n", at: fixture.wc)
        try await fixture.set("svn:global-ignores", "*.native\n*.subkeep\n", at: fixture.sub)
        try await fixture.set("svn:ignore", "*.native\nMy Folder\n", at: fixture.sub)
        try await fixture.set("custom:preserve", "unrelated local property", at: fixture.sub)
        try fixture.write("local file", to: fixture.sub.appendingPathComponent("file.native"))
        let client = fixture.client(patterns: ["*.native", "unused"])
        let plan = try await client.prepareUnignore(at: fixture.sub, path: "file.native")
        try expect(plan.appPatterns == ["*.native"] && plan.configuration?.removedPatterns == ["*.native"])
        try expect(plan.properties.count == 3 && plan.properties.contains { $0.directory.path == fixture.wc.path })
        let result = try await client.applyUnignore(plan, backupDirectory: fixture.root.appendingPathComponent("backups"))
        try expect(result.backups.count == 4 && result.propertyDirectories.count == 2)
        for backup in result.backups {
            try expect((try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        let restored = try await fixture.client(patterns: plan.remainingAppPatterns).status(at: fixture.sub, showIgnored: true)
        try expect(restored.first(where: { $0.path == "file.native" })?.item == "unversioned")
        try await fixture.expectValue("svn:global-ignores", at: fixture.wc, equals: "*.rootkeep\n")
        try await fixture.expectValue("svn:global-ignores", at: fixture.sub, equals: "*.subkeep\n")
        try await fixture.expectValue("svn:ignore", at: fixture.sub, equals: "My Folder\n")
        try await fixture.expectValue("custom:preserve", at: fixture.sub, equals: "unrelated local property")
        try expect(try String(contentsOf: fixture.config, encoding: .utf8).contains("global-ignores = *.keep"))
        try await fixture.assertNoFileSchedulingOrCommit()
    }

    func testPropertyWhitespaceIsLiteralAndParentIgnoreIsNotInherited() async throws {
        let fixture = try await NativeIgnoreFixture.make()
        defer { fixture.remove() }
        try await fixture.set("svn:ignore", "same.skip\n", at: fixture.wc)
        try fixture.write("local", to: fixture.sub.appendingPathComponent("same.skip"))
        do { _ = try await fixture.client().prepareUnignore(at: fixture.sub, path: "same.skip"); throw CheckFailure.failed("Parent svn:ignore must not be inherited") }
        catch let failure as CheckFailure { throw failure }
        catch is SVNError { }
        try await fixture.set("svn:global-ignores", "My Folder\n My Folder \n*.shared\n", at: fixture.wc)
        for name in ["My Folder", " My Folder "] {
            try FileManager.default.createDirectory(at: fixture.sub.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let plan = try await fixture.client().prepareUnignore(at: fixture.sub, path: " My Folder ")
        try expect(plan.properties.first?.removedPatterns == [" My Folder "])
        _ = try await fixture.client().applyUnignore(plan, backupDirectory: fixture.root.appendingPathComponent("backups"))
        let status = try await fixture.client().status(at: fixture.sub, showIgnored: true)
        try expect(status.first(where: { $0.path == " My Folder " })?.item == "unversioned")
        try expect(status.first(where: { $0.path == "My Folder" })?.item == "ignored")
        try await fixture.set("svn:ignore", "*.only\n", at: fixture.sub)
        try fixture.write("local", to: fixture.sub.appendingPathComponent("file.only"))
        let empty = try await fixture.client().prepareUnignore(at: fixture.sub, path: "file.only")
        _ = try await fixture.client().applyUnignore(empty, backupDirectory: fixture.root.appendingPathComponent("backups"))
        let properties = try SVNXML.ignoreProperties(Data((try await fixture.run(["proplist", "--xml", "--verbose", "--", fixture.sub.path + "@"])) .utf8))
        try expect(!properties.contains { $0.name == "svn:ignore" }, "An empty rule list removes only that property")
        try await fixture.assertNoFileSchedulingOrCommit()
    }

    func testConfigOrPropertyDriftStopsBeforeNativeWrites() async throws {
        let fixture = try await NativeIgnoreFixture.make()
        defer { fixture.remove() }
        try fixture.write("[miscellany]\nglobal-ignores = *.native *.keep\n", to: fixture.config)
        try await fixture.set("svn:ignore", "*.native\n", at: fixture.sub)
        try fixture.write("local", to: fixture.sub.appendingPathComponent("file.native"))
        let plan = try await fixture.client().prepareUnignore(at: fixture.sub, path: "file.native")
        let config = try Data(contentsOf: fixture.config)
        try await fixture.set("svn:ignore", "*.native\nexternal-change\n", at: fixture.sub)
        do { _ = try await fixture.client().applyUnignore(plan); throw CheckFailure.failed("Property drift must block config write") }
        catch let failure as CheckFailure { throw failure }
        catch is SVNError { }
        try expect(try Data(contentsOf: fixture.config) == config)
        let newPlan = try await fixture.client().prepareUnignore(at: fixture.sub, path: "file.native")
        try fixture.write("[miscellany]\nglobal-ignores = *.native *.changed\n", to: fixture.config)
        do { _ = try await fixture.client().applyUnignore(newPlan); throw CheckFailure.failed("Config drift must block property write") }
        catch let failure as CheckFailure { throw failure }
        catch is SVNError { }
        try await fixture.expectValue("svn:ignore", at: fixture.sub, equals: "*.native\nexternal-change\n")
        _ = try await fixture.run(["propdel", "svn:ignore", "--", fixture.sub.path + "@"])
        let configOnly = try await fixture.client().prepareUnignore(at: fixture.sub, path: "file.native")
        try expect(configOnly.properties.isEmpty)
        let beforeNewSource = try Data(contentsOf: fixture.config)
        try await fixture.set("svn:global-ignores", "*.native\n", at: fixture.wc)
        do { _ = try await fixture.client().applyUnignore(configOnly); throw CheckFailure.failed("A new matching source must invalidate the confirmation") }
        catch let failure as CheckFailure { throw failure }
        catch is SVNError { }
        try expect(try Data(contentsOf: fixture.config) == beforeNewSource)
    }

    func testFailedPropertyWriteIsNotReplayedAndKeepsBackups() async throws {
        let fixture = try await NativeIgnoreFixture.make()
        defer { fixture.remove() }
        try fixture.write("[miscellany]\nglobal-ignores = *.native *.keep\n", to: fixture.config)
        try await fixture.set("svn:global-ignores", "*.native\n*.other\n", at: fixture.wc)
        try await fixture.set("svn:ignore", "*.native\n*.other\n", at: fixture.sub)
        try fixture.write("local", to: fixture.sub.appendingPathComponent("file.native"))
        let marker = fixture.root.appendingPathComponent("mutations")
        let failing = fixture.root.appendingPathComponent("failing svn")
        let script = """
        #!/bin/sh
        case "$1" in
          propset|propdel)
            printf '%s\\n' "$1" >> \(nativeIgnoreQuote(marker.path))
            for target in "$@"; do
              if [ "$target" = \(nativeIgnoreQuote(fixture.sub.path + "@")) ]; then
                printf '%s\\n' 'svn: E200000: injected property failure' >&2
                exit 1
              fi
            done
            ;;
        esac
        exec \(nativeIgnoreQuote(fixture.svn.path)) "$@"
        """
        try fixture.write(script, to: failing)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: failing.path)
        let client = SVNClient(executablePath: failing.path, globalIgnoreConfigurationFiles: [fixture.config])
        let plan = try await client.prepareUnignore(at: fixture.sub, path: "file.native")
        do {
            _ = try await client.applyUnignore(plan, backupDirectory: fixture.root.appendingPathComponent("backups"))
            throw CheckFailure.failed("The injected property failure must be reported")
        } catch let failure as CheckFailure { throw failure }
        catch let error as SVNError { try expect(error.localizedDescription.contains("未自动重试") && error.localizedDescription.contains("备份")) }
        let calls = try String(contentsOf: marker, encoding: .utf8).split(separator: "\n")
        try expect(calls.count == 2, "A failed write must not be replayed")
        try await fixture.expectValue("svn:global-ignores", at: fixture.wc, equals: "*.other\n")
        try await fixture.expectValue("svn:ignore", at: fixture.sub, equals: "*.native\n*.other\n")
        let files = try FileManager.default.contentsOfDirectory(at: fixture.config.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        try expect(files.contains { $0.lastPathComponent.hasPrefix("config.svnmanager-backup-") })
        try await fixture.assertNoFileSchedulingOrCommit()
    }

    func testUnignoreRemoteInheritedSourceRequiresCheckoutAndDoesNotCommit() async throws {
        let fixture = try await NativeIgnoreFixture.make()
        defer { fixture.remove() }
        try await fixture.set("svn:global-ignores", "*.remote\n", at: fixture.wc)
        _ = try await fixture.run(["commit", "--depth", "empty", "-m", "inherited fixture", "--", fixture.wc.path + "@"])
        let partial = fixture.root.appendingPathComponent("partial checkout")
        _ = try await fixture.run(["checkout", "--", fixture.repository.absoluteString + "/sub@", partial.path])
        try fixture.write("local", to: partial.appendingPathComponent("file.remote"))
        do { _ = try await fixture.client().prepareUnignore(at: partial, path: "file.remote"); throw CheckFailure.failed("A repository-only property source cannot be edited locally") }
        catch let failure as CheckFailure { throw failure }
        catch let error as SVNError { try expect(error.localizedDescription.contains("尚未签出")) }
        let revision = try await fixture.youngest()
        try expect(revision == "2")
    }

    func testIgnorePropertyXMLWhitelistsAndDecodesNativeValues() throws {
        let value = Data(" My Folder \n*.tmp\n".utf8).base64EncodedString()
        let xml = Data("<properties><target path=\"/fixture/root\"><inherited_property name=\"svn:global-ignores\">*.shared</inherited_property><property name=\"svn:ignore\" encoding=\"base64\">\(value)</property><property name=\"custom:unrelated\">ignore this</property></target></properties>".utf8)
        let properties = try SVNXML.ignoreProperties(xml)
        try expect(properties.count == 2 && properties.first?.inherited == true)
        try expect(properties.last?.value == " My Folder \n*.tmp\n")
        try expectThrows(SVNError.self) { try SVNXML.ignoreProperties(Data("<properties><target path=\"/fixture\"><property name=\"svn:ignore\" encoding=\"base64\">/w==</property></target></properties>".utf8)) }
    }
}

private struct NativeIgnoreFixture {
    let root: URL
    let svn: URL
    let repository: URL
    let wc: URL
    let config: URL
    let svnlook: URL
    var sub: URL { wc.appendingPathComponent("sub") }

    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SVNNativeUnignore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directories = [FileManager.default.homeDirectoryForCurrentUser.path + "/.local/svn-cli/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        let binary = try require(directories.first { FileManager.default.isExecutableFile(atPath: $0 + "/svnadmin") })
        let profile = root.appendingPathComponent("profile")
        let config = profile.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try "[miscellany]\nglobal-ignores = *.keep\n".write(to: config, atomically: true, encoding: .utf8)
        let svn = root.appendingPathComponent("isolated svn")
        try ("#!/bin/sh\nexec " + nativeIgnoreQuote(binary + "/svn") + " --config-dir " + nativeIgnoreQuote(profile.path) + " \"$@\"\n").write(to: svn, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: svn.path)
        let fixture = Self(root: root, svn: svn, repository: root.appendingPathComponent("repository"), wc: root.appendingPathComponent("working copy"), config: config,
                           svnlook: URL(fileURLWithPath: binary + "/svnlook"))
        let seed = root.appendingPathComponent("seed/sub")
        try fixture.write("tracked", to: seed.appendingPathComponent("keep.txt"))
        _ = try await ProcessRunner.run(executable: binary + "/svnadmin", arguments: ["create", fixture.repository.path])
        _ = try await fixture.run(["import", "-m", "native ignore fixture", "--", seed.deletingLastPathComponent().path, fixture.repository.absoluteString])
        _ = try await fixture.run(["checkout", "--", fixture.repository.absoluteString + "@", fixture.wc.path])
        return fixture
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func client(patterns: [String] = []) -> SVNClient { SVNClient(executablePath: svn.path, additionalGlobalIgnores: patterns, globalIgnoreConfigurationFiles: [config]) }
    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    func run(_ arguments: [String]) async throws -> String {
        let result = try await ProcessRunner.run(executable: svn.path, arguments: arguments)
        guard result.exitCode == 0 else { throw CheckFailure.failed("Native unignore fixture command failed (\(result.exitCode))") }
        return result.text
    }
    func set(_ name: String, _ value: String, at directory: URL) async throws {
        _ = try await run(["propset", name, value, "--", directory.path + "@"])
    }
    func value(_ name: String, at directory: URL) async throws -> String {
        try await run(["propget", "--strict", name, "--", directory.path + "@"])
    }
    func expectValue(_ name: String, at directory: URL, equals expected: String) async throws {
        let actual = try await value(name, at: directory)
        try expect(actual == expected)
    }
    func youngest() async throws -> String {
        let result = try await ProcessRunner.run(executable: svnlook.path, arguments: ["youngest", repository.path])
        guard result.exitCode == 0 else { throw CheckFailure.failed("Cannot inspect native fixture revision") }
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func assertNoFileSchedulingOrCommit() async throws {
        let status = try await client().status(at: wc, showIgnored: true)
        try expect(!status.contains { ["added", "deleted", "replaced"].contains($0.item) })
        let revision = try await youngest()
        try expect(revision == "1")
    }
}

private func nativeIgnoreQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
