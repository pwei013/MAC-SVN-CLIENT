import Foundation
import Darwin
import SVNCore

struct IgnoreConfigEditTests {
    func testConfigSettingsLoadsUserSystemDefaultsAndExplicitEmptySources() throws {
        let fixture = try ConfigEditFixture()
        defer { fixture.remove() }
        let system = fixture.root.appendingPathComponent("system.config")
        let user = fixture.root.appendingPathComponent("user.config")
        try fixture.write("[miscellany]\nglobal-ignores = *.system *.keep\n", to: system)
        try fixture.write("[helpers]\ndiff-cmd = private-fixture-command\n", to: user)
        let inherited = try SVNIgnoreConfigSettings.load(configurationFiles: [system, user])
        try expect(inherited.file == user && inherited.patterns == ["*.system", "*.keep"])
        try expect(inherited.sourceDescription.contains("SVN 系统配置") && !inherited.sourceDescription.contains("private-fixture-command"))

        try fixture.write("[DEFAULT]\nbase = *.user *.keep\n[miscellany]\nglobal-ignores = %(base)s *.user\n", to: user)
        let explicit = try SVNIgnoreConfigSettings.load(configurationFiles: [system, user])
        try expect(explicit.patterns == ["*.user", "*.keep"], "Display expanded effective rules with stable deduplication")
        try expect(explicit.sourceDescription.contains("SVN 用户配置"))

        try fixture.write("[DEFAULT]\nglobal-ignores = *.fallback\n[miscellany]\n", to: user)
        let fallback = try SVNIgnoreConfigSettings.load(configurationFiles: [user])
        try expect(fallback.patterns == ["*.fallback"] && fallback.sourceDescription.contains("SVN 用户配置"))
        try fixture.write("[miscellany]\nglobal-ignores =\n", to: user)
        let empty = try SVNIgnoreConfigSettings.load(configurationFiles: [system, user])
        try expect(empty.patterns.isEmpty && empty.sourceDescription.contains("SVN 用户配置"))

        let missing = fixture.root.appendingPathComponent("missing/config")
        let defaults = try SVNIgnoreConfigSettings.load(configurationFiles: [missing])
        try expect(defaults.file == missing && defaults.patterns == SVNGlobalIgnores.defaultPatterns)
        try expect(defaults.sourceDescription.contains("SVN 内置默认规则"))
        try expect(!FileManager.default.fileExists(atPath: missing.path), "Loading defaults must not create user configuration")
        try expectThrows(SVNError.self) { try SVNIgnoreConfigSettings.load(configurationFiles: []) }
    }

    func testConfigSettingsSavePreservesBytesClearsExplicitlyAndRejectsDriftOrInjection() throws {
        let fixture = try ConfigEditFixture()
        defer { fixture.remove() }
        let user = fixture.root.appendingPathComponent("config")
        let original = "\u{FEFF}# unchanged\r\n[DEFAULT]\r\nbase = *.old *.keep\r\n[miscellany]\r\nglobal-ignores = %(base)s\r\nuse-commit-times = yes\r\n[helpers]\r\ndiff-cmd = keep-command\r\n"
        try fixture.write(original, to: user)
        let settings = try SVNIgnoreConfigSettings.load(configurationFiles: [user])
        let literal = "中文\u{00A0}目录"
        let edit = try settings.prepareSaving("*.new\n*.keep\t*.new " + literal + " [%](literal)s")
        try expect(edit.removedPatterns == ["*.old"])
        try expect(edit.remainingPatterns == ["*.new", "*.keep", literal, "[%](literal)s"])
        let expected = original.replacingOccurrences(of: "global-ignores = %(base)s\r\n", with: "global-ignores = *.new *.keep " + literal + " [%](literal)s\r\n")
        try expect(edit.updatedData == Data(expected.utf8), "Editing rules must preserve BOM, CRLF, interpolation source and unrelated options byte-for-byte")
        _ = try edit.apply()
        let saved = try SVNIgnoreConfigSettings.load(configurationFiles: [user])
        try expect(saved.patterns == edit.remainingPatterns)
        let clear = try saved.prepareSaving(" \t\n\r\u{0B}\u{0C}")
        try expect(clear.remainingPatterns.isEmpty)
        _ = try clear.apply()
        try expect(try SVNIgnoreConfigSettings.load(configurationFiles: [user]).patterns.isEmpty, "Clearing must write an explicit empty override instead of restoring defaults")

        let clean = try SVNIgnoreConfigSettings.load(configurationFiles: [user])
        for invalid in ["bad\0rule", "*.log\u{1B}", "%(other)s", "%(unfinished"] {
            try expectThrows(SVNError.self) { try clean.prepareSaving(invalid) }
        }
        try expect(try clean.prepareSaving("[%](other)s").remainingPatterns == ["[%](other)s"])
        let external = "[miscellany]\nglobal-ignores = *.external\n"
        try fixture.write(external, to: user)
        try expectThrows(SVNError.self) { try clean.prepareSaving("*.replacement") }
        try expect(try Data(contentsOf: user) == Data(external.utf8))

        try fixture.write("[miscellany]\nglobal-ignores = %(absent)s %(unfinished *.keep\n", to: user)
        let literals = try SVNIgnoreConfigSettings.load(configurationFiles: [user])
        try expect(try literals.prepareSaving("%(absent)s %(unfinished *.new").remainingPatterns == ["%(absent)s", "%(unfinished", "*.new"], "Existing unresolved percent fragments can only be preserved as exact literal tokens")
        try expectThrows(SVNError.self) { try literals.prepareSaving("%(absent)s.extra") }
        try fixture.write("[DEFAULT]\ntwo words = *.expanded\n[miscellany]\nglobal-ignores = %(two\twords)s *.keep\n", to: user)
        let splitReference = try SVNIgnoreConfigSettings.load(configurationFiles: [user])
        try expectThrows(SVNError.self, "Normalizing ASCII separators must not turn a previously literal fragment into a defined config reference") {
            try splitReference.prepareSaving(splitReference.patterns.joined(separator: "\n"))
        }
    }

    func testConfigSettingsNativeSaveAndExplicitClearReadback() async throws {
        let fixture = try ConfigEditFixture()
        defer { fixture.remove() }
        let (svn, config, workingCopy) = try await fixture.prepareNativeWorkingCopy(configText:
            "# preserve\n[DEFAULT]\nbase = *.old\n[miscellany]\nglobal-ignores = %(base)s *.keep\n")
        for name in ["old.old", "added.new", "other.keep", "visible.txt", "build.o"] {
            try fixture.write("preserve local\n", to: workingCopy.appendingPathComponent(name))
        }
        let client = SVNClient(executablePath: svn.path)
        let before = try await client.status(at: workingCopy, showIgnored: true)
        try expect(Set(before.filter { $0.item == "ignored" }.map(\.path)) == ["old.old", "other.keep"])
        let settings = try SVNIgnoreConfigSettings.load(configurationFiles: [config])
        let save = try settings.prepareSaving("*.new\n*.keep *.new")
        _ = try save.apply()
        let changed = try await client.status(at: workingCopy, showIgnored: true)
        try expect(Set(changed.filter { $0.item == "ignored" }.map(\.path)) == ["added.new", "other.keep"])
        try expect(changed.first(where: { $0.path == "old.old" })?.item == "unversioned")
        let reload = try SVNIgnoreConfigSettings.load(configurationFiles: [config])
        _ = try reload.prepareSaving("").apply()
        let cleared = try await client.status(at: workingCopy, showIgnored: true)
        try expect(!cleared.contains { $0.item == "ignored" }, "Explicit empty must not restore *.o or any compiled-in ignore")
        try expect(!cleared.contains { ["added", "deleted", "replaced"].contains($0.item) })
        try expect(try String(contentsOf: config, encoding: .utf8).contains("base = *.old"))
        for name in ["old.old", "added.new", "other.keep", "visible.txt", "build.o"] {
            try expect(try String(contentsOf: workingCopy.appendingPathComponent(name), encoding: .utf8) == "preserve local\n")
        }
    }

    func testConfigEditPreservesUnrelatedTextInterpolationAndPermissionsWithRestrictedBackup() throws {
        let fixture = try ConfigEditFixture()
        defer { fixture.remove() }
        let system = fixture.root.appendingPathComponent("system.config")
        let user = fixture.root.appendingPathComponent("user.config")
        try fixture.write("[miscellany]\nglobal-ignores = *.system\n", to: system)
        let original = "\u{FEFF}# keep this comment\r\n[DEFAULT]\r\nbase = *.keep *.native\r\n[MiScElLaNy]\r\nGLOBAL-IGNORES: %(base)s\r\n *.tail\r\nuse-commit-times = yes\r\n\r\n[helpers]\r\ndiff-cmd = custom-diff\r\n"
        try fixture.write(original, to: user)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: user.path)
        let attributeName = "com.mky.svnmanager.config-fixture"
        let attribute = Data("preserve-metadata".utf8)
        try expect(attribute.withUnsafeBytes { setxattr(user.path, attributeName, $0.baseAddress, $0.count, 0, 0) } == 0)
        let edit = try require(SVNIgnoreConfigEdit.prepare(forName: "target.native", configurationFiles: [system, user]))
        try expect(edit.file == user && edit.removedPatterns == ["*.native"])
        try expect(edit.remainingPatterns == ["*.keep", "*.tail"])
        try expect(edit.originalData == Data(original.utf8))
        let expected = original.replacingOccurrences(of: "GLOBAL-IGNORES: %(base)s\r\n *.tail\r\n", with: "GLOBAL-IGNORES: *.keep *.tail\r\n")
        try expect(edit.updatedData == Data(expected.utf8), "Only the effective option and its continuations may change; preserve BOM and every other byte")
        let backup = try require(edit.apply())
        try expect(try Data(contentsOf: backup) == Data(original.utf8))
        let backupAttributes = try FileManager.default.attributesOfItem(atPath: backup.path)
        let currentAttributes = try FileManager.default.attributesOfItem(atPath: user.path)
        try expect((backupAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try expect((currentAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o640)
        try expect(try Data(contentsOf: user) == edit.updatedData)
        var metadataReadback = Data(count: attribute.count)
        let metadataCount = metadataReadback.withUnsafeMutableBytes { getxattr(user.path, attributeName, $0.baseAddress, $0.count, 0, 0) }
        try expect(metadataCount == attribute.count && metadataReadback == attribute, "Atomic replacement must preserve existing extended metadata")
        try expect(try String(contentsOf: system, encoding: .utf8) == "[miscellany]\nglobal-ignores = *.system\n")
    }

    func testConfigEditOverridesSystemAndCompiledDefaultsOnlyInUserFile() throws {
        let fixture = try ConfigEditFixture()
        defer { fixture.remove() }
        let system = fixture.root.appendingPathComponent("system.config")
        let user = fixture.root.appendingPathComponent("new-user/config")
        try fixture.write("[miscellany]\nglobal-ignores = *.system *.keep\n", to: system)
        let systemData = try Data(contentsOf: system)
        let inherited = try require(SVNIgnoreConfigEdit.prepare(forName: "target.system", configurationFiles: [system, user]))
        try expect(inherited.originalData == nil && inherited.remainingPatterns == ["*.keep"])
        try expect(try inherited.apply() == nil)
        try expect(try String(contentsOf: user, encoding: .utf8) == "[miscellany]\nglobal-ignores = *.keep\n")
        try expect(try Data(contentsOf: system) == systemData)

        let defaultsUser = fixture.root.appendingPathComponent("defaults/config")
        let compiled = try require(SVNIgnoreConfigEdit.prepare(forName: "build.o", configurationFiles: [defaultsUser]))
        try expect(compiled.removedPatterns == ["*.o"])
        try expect(compiled.remainingPatterns == SVNGlobalIgnores.defaultPatterns.filter { $0 != "*.o" })
        _ = try compiled.apply()
        try expect(try String(contentsOf: defaultsUser, encoding: .utf8).contains(".DS_Store"))
        try expectThrows(SVNError.self) { try SVNIgnoreConfigEdit.prepare(forName: "build.o", configurationFiles: []) }
        try expect(try SVNIgnoreConfigEdit.prepare(forName: "visible.txt", configurationFiles: []) == nil)
    }

    func testConfigEditHandlesDefaultFallbackEmptyAndUnsafeInterpolationWithoutWriting() throws {
        let fixture = try ConfigEditFixture()
        defer { fixture.remove() }
        let user = fixture.root.appendingPathComponent("config")
        try fixture.write("[DEFAULT]\nbase = *.native\nglobal-ignores = %(base)s *.keep\n[miscellany]\nuse-commit-times = yes\n", to: user)
        let fallback = try require(SVNIgnoreConfigEdit.prepare(forName: "target.native", configurationFiles: [user]))
        let updated = try require(String(data: fallback.updatedData, encoding: .utf8))
        try expect(updated.contains("[miscellany]\nglobal-ignores = *.keep\nuse-commit-times = yes"))
        try expect(updated.contains("global-ignores = %(base)s *.keep"), "Shared DEFAULT/interpolation sources must remain intact")
        try fixture.write("[DEFAULT]\nglobal-ignores = *.native\n[miscellany]\nglobal-ignores =\n", to: user)
        try expect(try SVNIgnoreConfigEdit.prepare(forName: "target.native", configurationFiles: [user]) == nil)
        for literal in ["%(absent)s", "%(unfinished"] {
            try fixture.write("[miscellany]\nglobal-ignores = " + literal + " *.native\n", to: user)
            let preserved = try require(SVNIgnoreConfigEdit.prepare(forName: "target.native", configurationFiles: [user]))
            try expect(preserved.remainingPatterns == [literal], "SVN treats undefined or unfinished references as literal patterns")
        }
        for raw in ["[miscellany]\nglobal-ignores = %(cycle)s\ncycle = %(cycle)s\n", "[miscellany\nglobal-ignores = *.native\n"] {
            try fixture.write(raw, to: user)
            try expectThrows(SVNError.self) { try SVNIgnoreConfigEdit.prepare(forName: "target.native", configurationFiles: [user]) }
            try expect(try Data(contentsOf: user) == Data(raw.utf8))
        }
        try Data([0xff, 0xfe]).write(to: user)
        try expectThrows(SVNError.self) { try SVNIgnoreConfigEdit.prepare(forName: "target.native", configurationFiles: [user]) }
    }

    func testConfigEditRefusesDriftAndSymlinksBeforeWriting() throws {
        let fixture = try ConfigEditFixture()
        defer { fixture.remove() }
        let system = fixture.root.appendingPathComponent("system.config")
        let user = fixture.root.appendingPathComponent("config")
        try fixture.write("[miscellany]\nglobal-ignores = *.native *.keep\n", to: system)
        try fixture.write("# user settings\n", to: user)
        let edit = try require(SVNIgnoreConfigEdit.prepare(forName: "target.native", configurationFiles: [system, user]))
        try fixture.write("[miscellany]\nglobal-ignores = *.native *.different\n", to: system)
        try expectThrows(SVNError.self) { try edit.validateUnchanged() }
        try expectThrows(SVNError.self) { try edit.apply() }
        try expect(try String(contentsOf: user, encoding: .utf8) == "# user settings\n")
        let unchanged = try require(SVNIgnoreConfigEdit.prepare(forName: "target.native", configurationFiles: [system, user]))
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: user.path)
        try expectThrows(SVNError.self) { try unchanged.apply() }
        let link = fixture.root.appendingPathComponent("linked-config")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: system)
        try expectThrows(SVNError.self) { try SVNIgnoreConfigEdit.prepare(forName: "target.native", configurationFiles: [link]) }
        let missing = fixture.root.appendingPathComponent("missing")
        let absent = try require(SVNIgnoreConfigEdit.prepare(forName: "build.o", configurationFiles: [missing]))
        try fixture.write("[miscellany]\nglobal-ignores = *.new\n", to: missing)
        try expectThrows(SVNError.self) { try absent.apply() }
        try expect(!(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)).contains { $0.hasPrefix("config.svnmanager-backup-") }, "A stale preview must not even create a backup")
    }

    func testConfigEditNativeSVNReadbackPreservesOtherIgnoresAndUnicodeLiteralWhitespace() async throws {
        let fixture = try ConfigEditFixture()
        defer { fixture.remove() }
        let directory = try require([
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/svn-cli/bin").path,
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"
        ].first { FileManager.default.isExecutableFile(atPath: $0 + "/svn") && FileManager.default.isExecutableFile(atPath: $0 + "/svnadmin") })
        let configDirectory = fixture.root.appendingPathComponent("isolated-config")
        let config = configDirectory.appendingPathComponent("config")
        let literal = "literal\u{00A0}.cfg"
        try fixture.write("# preserve\n[DEFAULT]\nbase = *.native *.keep\n[miscellany]\nglobal-ignores = %(base)s " + literal + "\n", to: config)
        let svn = fixture.root.appendingPathComponent("isolated svn")
        try fixture.write("#!/bin/sh\nexec " + configEditShellQuote(directory + "/svn") + " --config-dir " + configEditShellQuote(configDirectory.path) + " \"$@\"\n", to: svn)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: svn.path)
        let repository = fixture.root.appendingPathComponent("repository")
        let seed = fixture.root.appendingPathComponent("seed")
        try fixture.write("tracked\n", to: seed.appendingPathComponent("tracked.txt"))
        try await fixture.run(URL(fileURLWithPath: directory + "/svnadmin"), ["create", repository.path])
        try await fixture.run(svn, ["import", "--non-interactive", "-m", "config ignore fixture", "--", seed.path, repository.absoluteString])
        let workingCopy = fixture.root.appendingPathComponent("working copy")
        try await fixture.run(svn, ["checkout", "--non-interactive", "--", repository.absoluteString + "@", workingCopy.path])
        for name in ["target.native", "other.keep", literal, "visible.txt"] {
            try fixture.write("preserve local\n", to: workingCopy.appendingPathComponent(name))
        }
        let client = SVNClient(executablePath: svn.path)
        let before = try await client.status(at: workingCopy, showIgnored: true)
        try expect(Set(before.filter { $0.item == "ignored" }.map(\.path)) == ["target.native", "other.keep", literal])
        let nativeEdit = try require(SVNIgnoreConfigEdit.prepare(forName: "target.native", configurationFiles: [config]))
        _ = try nativeEdit.apply()
        let after = try await client.status(at: workingCopy, showIgnored: true)
        try expect(after.first(where: { $0.path == "target.native" })?.item == "unversioned")
        try expect(Set(after.filter { $0.item == "ignored" }.map(\.path)) == ["other.keep", literal])
        let literalEdit = try require(SVNIgnoreConfigEdit.prepare(forName: literal, configurationFiles: [config]))
        try expect(literalEdit.removedPatterns == [literal], "Unicode whitespace is a literal byte sequence, not a config delimiter")
        _ = try literalEdit.apply()
        let final = try await client.status(at: workingCopy, showIgnored: true)
        try expect(final.first(where: { $0.path == literal })?.item == "unversioned")
        try expect(final.first(where: { $0.path == "other.keep" })?.item == "ignored")
        try expect(!final.contains { ["added", "deleted", "replaced"].contains($0.item) })
        try expect(try String(contentsOf: config, encoding: .utf8).contains("base = *.native *.keep"))
    }
}

private struct ConfigEditFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SVNIgnoreConfigEditChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    func run(_ executable: URL, _ arguments: [String]) async throws {
        let result = try await ProcessRunner.run(executable: executable.path, arguments: arguments)
        guard result.exitCode == 0 else { throw CheckFailure.failed("Isolated configuration SVN command failed (\(result.exitCode))") }
    }
    func prepareNativeWorkingCopy(configText: String) async throws -> (URL, URL, URL) {
        let directory = try require([
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/svn-cli/bin").path,
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"
        ].first { FileManager.default.isExecutableFile(atPath: $0 + "/svn") && FileManager.default.isExecutableFile(atPath: $0 + "/svnadmin") })
        let configDirectory = root.appendingPathComponent("isolated-config")
        let config = configDirectory.appendingPathComponent("config")
        try write(configText, to: config)
        let svn = root.appendingPathComponent("isolated svn")
        try write("#!/bin/sh\nexec " + configEditShellQuote(directory + "/svn") + " --config-dir " + configEditShellQuote(configDirectory.path) + " \"$@\"\n", to: svn)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: svn.path)
        let repository = root.appendingPathComponent("repository")
        let seed = root.appendingPathComponent("seed")
        try write("tracked\n", to: seed.appendingPathComponent("tracked.txt"))
        try await run(URL(fileURLWithPath: directory + "/svnadmin"), ["create", repository.path])
        try await run(svn, ["import", "--non-interactive", "-m", "settings fixture", "--", seed.path, repository.absoluteString])
        let workingCopy = root.appendingPathComponent("working copy")
        try await run(svn, ["checkout", "--non-interactive", "--", repository.absoluteString + "@", workingCopy.path])
        return (svn, config, workingCopy)
    }
}

private func configEditShellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
