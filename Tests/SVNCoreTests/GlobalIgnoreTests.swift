import Foundation
import SVNCore

struct GlobalIgnoreTests {
    func testShowIgnoredIsOptInAndKeepsIgnoredDirectoriesBounded() async throws {
        let fixture = try IgnoreCheckFixture()
        defer { fixture.remove() }
        let (svn, config, workingCopy) = try await fixture.prepareWorkingCopy()
        _ = try await fixture.run(svn, ["propset", "svn:ignore", "*.localignore", "--", ".@"], at: workingCopy)
        for name in ["cache/child/nested.txt", "one.ctxlog", "old.user", "file.localignore", "keep.txt"] {
            try fixture.write("local file\n", to: workingCopy.appendingPathComponent(name))
        }
        try fixture.write("tracked modification\n", to: workingCopy.appendingPathComponent("tracked.log"))
        let client = SVNClient(executablePath: svn.path, additionalGlobalIgnores: ["cache", "*.ctxlog"], globalIgnoreConfigurationFiles: [config])
        let normal = try await client.status(at: workingCopy)
        try expect(!normal.contains { $0.item == "ignored" }, "Ignored rows remain hidden by default")
        let shown = try await client.status(at: workingCopy, showIgnored: true)
        let ignored = shown.filter { $0.item == "ignored" }
        try expect(Set(ignored.map(\.path)) == ["cache", "one.ctxlog", "old.user", "file.localignore"], "Show both app and native config/property ignores without traversing ignored folders")
        try expect(ignored.allSatisfy { $0.label == "已忽略" && !$0.canCommit })
        try expect(shown.first(where: { $0.path == "tracked.log" })?.canCommit == true)
        try expect(shown.first(where: { $0.path == "keep.txt" })?.item == "unversioned")
    }

    func testUnignorePlanFindsAllMatchingRulesWithoutChangingFilesOrConfiguration() async throws {
        let fixture = try IgnoreCheckFixture()
        defer { fixture.remove() }
        let (svn, config, workingCopy) = try await fixture.prepareWorkingCopy()
        let originalConfig = try Data(contentsOf: config)
        let names = ["one.ctxlog", "cache.v2", "报告[1]*?.ctx", "draft copy.txt", "中文\u{3000}目录", "%(name)s.cfg"]
        let patterns = ["keep-unused", "*.ctxlog"] + names.compactMap {
            SVNGlobalIgnores.suggestions(forName: $0, isDirectory: $0 == "cache.v2" || $0 == "中文\u{3000}目录").first?.pattern
        }
        for name in names {
            let relative = name == "cache.v2" || name == "中文\u{3000}目录" ? name + "/child.txt" : name
            try fixture.write("preserve locally\n", to: workingCopy.appendingPathComponent(relative))
        }
        let client = SVNClient(executablePath: svn.path, additionalGlobalIgnores: patterns, globalIgnoreConfigurationFiles: [config])
        for name in names {
            let removed = try await client.removableIgnorePatterns(at: workingCopy, path: name)
            let literal = try require(SVNGlobalIgnores.suggestions(forName: name, isDirectory: false).first?.pattern)
            try expect(removed == (name == "one.ctxlog" ? ["*.ctxlog", literal] : [literal]), "Remove all overlapping matching rules, preserving unrelated rules")
            let remaining = patterns.filter { !removed.contains($0) }
            let after = try await SVNClient(executablePath: svn.path, additionalGlobalIgnores: remaining, globalIgnoreConfigurationFiles: [config]).status(at: workingCopy, showIgnored: true)
            try expect(after.first(where: { $0.path == name })?.item == "unversioned")
            try expect(FileManager.default.fileExists(atPath: workingCopy.appendingPathComponent(name).path))
        }
        try expect(try Data(contentsOf: config) == originalConfig)
        let finalStatus = try await client.status(at: workingCopy, showIgnored: true)
        try expect(!finalStatus.contains { ["added", "deleted", "replaced"].contains($0.item) })
    }

    func testUnignorePlanRejectsNativeRulesStaleRowsAndEscapingPathsWithoutWrites() async throws {
        let fixture = try IgnoreCheckFixture()
        defer { fixture.remove() }
        let (svn, config, workingCopy) = try await fixture.prepareWorkingCopy()
        let originalConfig = try Data(contentsOf: config)
        _ = try await fixture.run(svn, ["propset", "svn:ignore", "*.localignore", "--", ".@"], at: workingCopy)
        for name in ["old.user", "overlap.localignore", "visible.txt"] {
            try fixture.write("keep locally\n", to: workingCopy.appendingPathComponent(name))
        }
        let client = SVNClient(executablePath: svn.path, additionalGlobalIgnores: ["*.localignore"], globalIgnoreConfigurationFiles: [config])
        for path in ["old.user", "overlap.localignore", "visible.txt", "tracked.log", "missing.txt", "../outside", ".svn/entries", "/absolute"] {
            do {
                _ = try await client.removableIgnorePatterns(at: workingCopy, path: path)
                throw CheckFailure.failed("Cannot unignore native-only rules, stale or invalid targets: \(path)")
            } catch let failure as CheckFailure { throw failure }
            catch is SVNError { }
        }
        try expect(try Data(contentsOf: config) == originalConfig)
        let property = try await fixture.run(svn, ["propget", "svn:ignore", "--", ".@"], at: workingCopy)
        try expect(property.trimmingCharacters(in: .newlines) == "*.localignore", "Native properties must never be removed as a side effect")
        try expect(try String(contentsOf: workingCopy.appendingPathComponent("overlap.localignore"), encoding: .utf8) == "keep locally\n")
    }

    func testContextSuggestionsRespectNodeTypeAndEscapeLiteralNames() throws {
        let directory = SVNGlobalIgnores.suggestions(forName: "cache.v2", isDirectory: true)
        try expect(directory.count == 1 && directory.first?.kind == .directoryName && directory.first?.pattern == "cache.v2")
        let file = SVNGlobalIgnores.suggestions(forName: "报告[1]*?.log", isDirectory: false)
        try expect(file.map(\.pattern) == ["报告\\[1\\]\\*\\?.log", "*.log"])
        try expect(file.map(\.kind) == [.fileName, .fileExtension])
        let hidden = SVNGlobalIgnores.suggestions(forName: ".env", isDirectory: false)
        try expect(hidden.count == 1 && hidden.first?.pattern == ".env")
        try expect(SVNGlobalIgnores.suggestions(forName: "archive.tar.gz", isDirectory: false).last?.pattern == "*.gz")
        let spaced = SVNGlobalIgnores.suggestions(forName: "draft copy.txt", isDirectory: false)
        try expect(spaced.first?.pattern == "draft?copy.txt" && spaced.first?.usesWhitespaceWildcard == true)
        try expect(spaced.last?.usesWhitespaceWildcard == false)
        let interpolation = SVNGlobalIgnores.suggestions(forName: "%(name)s.cfg", isDirectory: false)
        try expect(interpolation.first?.pattern == "[%](name)s.cfg")
        let rules = (file + directory + hidden + spaced + interpolation).map(\.pattern)
        try expect(try SVNGlobalIgnores.parse((["existing"] + rules + rules).joined(separator: "\n")) == ["existing"] + rules,
                   "Appending a context rule preserves existing rules and removes duplicates")
        for invalid in ["", ".", "..", "parent/file", "line\nfeed", "nul\0name"] {
            try expect(SVNGlobalIgnores.suggestions(forName: invalid, isDirectory: false).isEmpty)
        }
    }

    func testContextPatternsMatchNativeSVNWithoutExpandingLiteralGlobNames() async throws {
        let fixture = try IgnoreCheckFixture()
        defer { fixture.remove() }
        let (svn, config, workingCopy) = try await fixture.prepareWorkingCopy()
        let ignored = ["literal[1]*?.ctx", "%(name)s.cfg", "back\\slash.txt", "draft copy.txt", "中文\u{3000}目录", "cache.v2", "extension.a[1]"]
        let visible = ["literal11abc.ctx", "expanded.cfg", "backslash.txt", "draftcopy.txt", "other.v2", "extension.a1"]
        for name in ignored + visible {
            let relative = name == "cache.v2" || name == "中文\u{3000}目录" ? name + "/child.txt" : name
            try fixture.write("local file\n", to: workingCopy.appendingPathComponent(relative))
        }
        var patterns = ignored.dropLast().compactMap {
            SVNGlobalIgnores.suggestions(forName: $0, isDirectory: $0 == "cache.v2" || $0 == "中文\u{3000}目录").first?.pattern
        }
        patterns.append(try require(SVNGlobalIgnores.suggestions(forName: "extension.a[1]", isDirectory: false).last?.pattern))
        let client = SVNClient(executablePath: svn.path, additionalGlobalIgnores: patterns, globalIgnoreConfigurationFiles: [config])
        let changes = try await client.status(at: workingCopy)
        try expect(Set(changes.map(\.path)) == Set(visible), "Generated patterns must match SVN's native glob syntax, with literal metacharacters and UTF-8 whitespace")
        _ = try await client.add(at: workingCopy, paths: visible)
        let added = try await client.status(at: workingCopy)
        try expect(Set(added.filter { $0.item == "added" }.map(\.path)) == Set(visible), "Similar names must remain addable")
        for name in ignored {
            try expect(FileManager.default.fileExists(atPath: workingCopy.appendingPathComponent(name).path), "Ignoring must leave local files in place")
        }
    }

    func testRulesParseDeduplicateAndRejectUnsafeValues() throws {
        let rules = try SVNGlobalIgnores.parse("bin\nobj\t*.log bin 中文目录 file?.[abc]\r\n")
        try expect(rules == ["bin", "obj", "*.log", "中文目录", "file?.[abc]"])
        try expect(try SVNGlobalIgnores.parse(" \n\t").isEmpty)
        for invalid in ["bin\0obj", "*.log\u{1B}", "parent/bin", "%(other)s", ".", ".."] {
            try expectThrows(SVNError.self) { try SVNGlobalIgnores.parse(invalid) }
        }
        try expectThrows(SVNError.self) {
            try SVNGlobalIgnores.configurationOption(additional: ["a b"], configurationFiles: [])
        }
    }

    func testConfigurationMergesPrecedenceContinuationsDefaultsAndExplicitEmpty() throws {
        let fixture = try IgnoreCheckFixture()
        defer { fixture.remove() }
        let system = fixture.root.appendingPathComponent("system.config")
        let user = fixture.root.appendingPathComponent("user.config")
        try fixture.write("[miscellany]\nglobal-ignores = *.system\n  *.continue\n", to: system)
        var option = try require(SVNGlobalIgnores.configurationOption(additional: ["obj"], configurationFiles: [system]))
        try expect(option == "config:miscellany:global-ignores=*.system *.continue obj")

        try fixture.write("\u{FEFF}[DEFAULT]\r\nbase = *.base\r\n[MiScElLaNy]\r\nGLOBAL-IGNORES: %(base)s *.user\r\n *.tail\r\n", to: user)
        option = try require(SVNGlobalIgnores.configurationOption(additional: ["obj"], configurationFiles: [system, user]))
        try expect(option == "config:miscellany:global-ignores=%(base)s *.user *.tail obj", "User config replaces system config; SVN retains ownership of interpolation")

        try fixture.write("[miscellany]\nglobal-ignores =\n", to: user)
        try expect(try SVNGlobalIgnores.configurationOption(additional: ["obj"], configurationFiles: [system, user]) == "config:miscellany:global-ignores=obj", "Explicit empty must not restore defaults or older system rules")
        try fixture.write("[DEFAULT]\nglobal-ignores = *.fallback\n[miscellany]\n", to: user)
        try expect(try SVNGlobalIgnores.configurationOption(additional: ["obj"], configurationFiles: [user]) == "config:miscellany:global-ignores=*.fallback obj")
        try fixture.write("[DEFAULT]\nglobal-ignores = *.fallback\n", to: user)
        option = try require(SVNGlobalIgnores.configurationOption(additional: ["obj"], configurationFiles: [user]))
        try expect(option.contains("*.o") && option.contains(".DS_Store") && !option.contains("*.fallback"), "SVN only searches DEFAULT when miscellany exists")
        try fixture.write("[miscellany]\nglobal-ignores = \u{00A0}literal\u{00A0}\n", to: user)
        try expect(try SVNGlobalIgnores.configurationOption(additional: ["obj"], configurationFiles: [user]) == "config:miscellany:global-ignores=\u{00A0}literal\u{00A0} obj", "SVN treats Unicode space characters as literal bytes rather than ASCII delimiters")
    }

    func testMissingConfigUsesDefaultsButUnsafeConfigFailsWithoutOverride() throws {
        let fixture = try IgnoreCheckFixture()
        defer { fixture.remove() }
        let missing = fixture.root.appendingPathComponent("missing")
        let option = try require(SVNGlobalIgnores.configurationOption(additional: ["obj"], configurationFiles: [missing]))
        try expect(option == "config:miscellany:global-ignores=" + SVNGlobalIgnores.defaultPatterns.joined(separator: " ") + " obj")
        let malformed = fixture.root.appendingPathComponent("malformed")
        for text in ["[miscellany\nglobal-ignores=*.keep", "[miscellany]\nglobal-ignores=*.keep\n\n *.lost", "[miscellany]\nglobal-ignores=*.keep\0"] {
            try fixture.write(text, to: malformed)
            try expectThrows(SVNError.self) {
                try SVNGlobalIgnores.configurationOption(additional: ["obj"], configurationFiles: [malformed])
            }
        }
        try Data([0xFF, 0xFE]).write(to: malformed)
        try expectThrows(SVNError.self) { try SVNGlobalIgnores.configurationOption(additional: ["obj"], configurationFiles: [malformed]) }
        try expect(try SVNGlobalIgnores.configurationOption(additional: [], configurationFiles: [malformed]) == nil, "Clearing app rules must leave SVN's own config handling completely intact")
    }

    func testOnlyStatusAndAddReceiveOneLiteralConfigArgument() async throws {
        let fixture = try IgnoreCheckFixture()
        defer { fixture.remove() }
        let marker = fixture.root.appendingPathComponent("arguments")
        let executable = try fixture.makeExecutable("""
        printf '%s\\0' "$@" > \(ignoreShellQuote(marker.path))
        if [ "$1" = list ]; then
            printf '%s\\n' '<lists><list/></lists>'
        elif [ "$1" = status ]; then
            printf '%s\\n' '<status><target path="."/></status>'
        fi
        """)
        let pattern = "literal;$(id)*.log"
        let client = SVNClient(executablePath: executable.path, additionalGlobalIgnores: [pattern, "obj"], globalIgnoreConfigurationFiles: [])
        _ = try await client.status(at: fixture.root)
        var arguments = try fixture.arguments(at: marker)
        try expect(arguments.filter { $0 == "--config-option" }.count == 1)
        try expect(!arguments.contains("--no-ignore"))
        try expect(arguments.contains { $0.hasSuffix(" " + pattern + " obj") }, "Globs and shell punctuation are a single literal argument, never evaluated by a shell")
        _ = try await client.status(at: fixture.root, showIgnored: true)
        arguments = try fixture.arguments(at: marker)
        try expect(arguments.filter { $0 == "--no-ignore" }.count == 1 && arguments.last == ".@")
        _ = try await client.add(at: fixture.root, paths: ["new.txt"])
        arguments = try fixture.arguments(at: marker)
        try expect(arguments.first == "add" && arguments.contains("--config-option"))
        _ = try await client.list(url: "https://example.invalid/repository")
        try expect(!(try fixture.arguments(at: marker)).contains("--config-option"), "Repository browsing must not be filtered")
        let plain = SVNClient(executablePath: executable.path, globalIgnoreConfigurationFiles: [fixture.root])
        _ = try await plain.status(at: fixture.root)
        try expect(!(try fixture.arguments(at: marker)).contains("--config-option"), "No app rules means no override or attempt to read config")
    }

    func testRealStatusAndRecursiveAddPreserveTrackedChangesAndExistingIgnores() async throws {
        let fixture = try IgnoreCheckFixture()
        defer { fixture.remove() }
        let (svn, config, workingCopy) = try await fixture.prepareWorkingCopy()
        let originalConfig = try Data(contentsOf: config)
        _ = try await fixture.run(svn, ["propset", "svn:ignore", "*.localignore", "--", ".@"], at: workingCopy)
        _ = try await fixture.run(svn, ["propset", "svn:global-ignores", "*.inheritedignore", "--", ".@"], at: workingCopy)
        for name in ["bin/a.txt", "obj/b.txt", "temp.log", "old.user", "tail.keep", "settings.localignore", "中文忽略/c.txt", "new/keep.txt", "new/nested/keep.cs", "new/build.log", "new/bin/output.txt", "new/nested/obj/output.txt", "new/old.user", "new/inherited.inheritedignore"] {
            try fixture.write("temporary fixture\n", to: workingCopy.appendingPathComponent(name))
        }
        try fixture.write("tracked modification\n", to: workingCopy.appendingPathComponent("tracked.log"))
        let rules = ["bin", "obj", "*.log", "中文忽略"]
        let client = SVNClient(executablePath: svn.path, additionalGlobalIgnores: rules, globalIgnoreConfigurationFiles: [config])
        let changes = try await client.status(at: workingCopy)
        try expect(changes.first(where: { $0.path == "tracked.log" })?.item == "modified", "Ignore patterns must never hide already tracked modifications")
        try expect(Set(changes.filter { $0.item == "unversioned" }.map(\.path)) == ["new"])

        _ = try await client.add(at: workingCopy, paths: ["new"])
        let afterAdd = try await client.status(at: workingCopy)
        try expect(Set(afterAdd.filter { $0.item == "added" }.map(\.path)) == ["new", "new/keep.txt", "new/nested", "new/nested/keep.cs"], "Recursive Add must apply app, existing user and inherited property ignores")
        try expect(afterAdd.first(where: { $0.path == "tracked.log" })?.item == "modified")

        let plain = SVNClient(executablePath: svn.path, globalIgnoreConfigurationFiles: [config])
        let restored = try await plain.status(at: workingCopy)
        let untracked = Set(restored.filter { $0.item == "unversioned" }.map(\.path))
        try expect(untracked == ["bin", "obj", "temp.log", "中文忽略", "new/bin", "new/build.log", "new/nested/obj"], "Clearing application patterns restores SVN's original rules, including formerly hidden children of the newly added directories, and leaves property ignores intact")
        try expect(try Data(contentsOf: config) == originalConfig, "Application rules must never rewrite SVN configuration")
        try expect(try String(contentsOf: workingCopy.appendingPathComponent("tracked.log"), encoding: .utf8) == "tracked modification\n")
    }

    func testAddRejectsIgnoredExplicitTargetsAndAncestorsBeforeWriting() async throws {
        let fixture = try IgnoreCheckFixture()
        defer { fixture.remove() }
        let (svn, config, workingCopy) = try await fixture.prepareWorkingCopy()
        try fixture.write("keep locally\n", to: workingCopy.appendingPathComponent("bin/inside.txt"))
        try fixture.write("keep locally\n", to: workingCopy.appendingPathComponent("new.log"))
        let client = SVNClient(executablePath: svn.path, additionalGlobalIgnores: ["bin", "*.log"], globalIgnoreConfigurationFiles: [config])
        for target in ["bin", "bin/inside.txt", "new.log"] {
            do {
                _ = try await client.add(at: workingCopy, paths: [target])
                throw CheckFailure.failed("A stale ignored Add target must be rejected")
            } catch let failure as CheckFailure { throw failure }
            catch let error as SVNError { try expect(error.localizedDescription.contains("忽略")) }
        }
        let all = try await fixture.run(svn, ["status", "--xml", "--no-ignore", "--", ".@"], at: workingCopy)
        try expect(!(try SVNXML.parseStatus(Data(all.utf8))).contains { $0.item == "added" }, "Rejected Add must not schedule any file or parent directory")
    }
}

private struct IgnoreCheckFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SVNGlobalIgnoreChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    func makeExecutable(_ body: String, name: String = "mock svn") throws -> URL {
        let url = root.appendingPathComponent(name)
        try write("#!/bin/sh\n" + body + "\n", to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
    func arguments(at url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\0").map(String.init)
    }
    func prepareWorkingCopy() async throws -> (URL, URL, URL) {
        let directories = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/svn-cli/bin").path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        let directory = try require(directories.first {
            FileManager.default.isExecutableFile(atPath: $0 + "/svn") && FileManager.default.isExecutableFile(atPath: $0 + "/svnadmin")
        }, "Global ignore integration requires svn and svnadmin")
        let configDirectory = root.appendingPathComponent("isolated-config")
        let config = configDirectory.appendingPathComponent("config")
        try write("[DEFAULT]\nbase = *.user\n[miscellany]\nglobal-ignores = %(base)s\n *.keep\n", to: config)
        let svn = try makeExecutable("exec \(ignoreShellQuote(directory + "/svn")) --config-dir \(ignoreShellQuote(configDirectory.path)) \"$@\"", name: "isolated svn")
        let repository = root.appendingPathComponent("repository")
        let seed = root.appendingPathComponent("seed")
        try write("tracked original\n", to: seed.appendingPathComponent("tracked.log"))
        _ = try await run(URL(fileURLWithPath: directory + "/svnadmin"), ["create", repository.path])
        _ = try await run(svn, ["import", "--non-interactive", "-m", "ignore fixture", "--", seed.path, repository.absoluteString])
        let workingCopy = root.appendingPathComponent("working copy")
        _ = try await run(svn, ["checkout", "--non-interactive", "--", repository.absoluteString + "@", workingCopy.path])
        return (svn, config, workingCopy)
    }
    @discardableResult
    func run(_ executable: URL, _ arguments: [String], at directory: URL? = nil) async throws -> String {
        let result = try await ProcessRunner.run(executable: executable.path, arguments: arguments, directory: directory)
        guard result.exitCode == 0 else { throw CheckFailure.failed("Temporary global-ignore SVN command failed (\(result.exitCode))") }
        return result.text
    }
}

private func ignoreShellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
