import CoreFoundation
import Foundation
import SVNCore

struct ConflictResolutionTests {
    func testMineResolutionIsReviewedLocalAndPreservesBackupsAndOtherFiles() async throws {
        let f = try await ConflictFixture.make(); defer { f.remove() }
        try f.base.write("other edit must remain\n", "outside.txt")
        try f.base.write("extra must remain\n", "extra.txt")
        let before = try f.bytes(), revision = try f.base.youngest()
        let plan = try await f.client.prepareConflict(at: f.wc, path: f.path)
        try expect(plan.blockingReason == nil && plan.comparison?.local.text == "local change\n")
        try expect(plan.comparison?.remote.text == "incoming change\n" && plan.operation == "update")
        let decision = try await f.client.prepareConflictResolution(plan, choice: .mine)
        try expect(try f.bytes() == before && f.isConflicted(), "Preparing and reviewing must not change a conflict")
        let result = try await f.client.applyConflictResolution(decision, backupRoot: f.backups)
        try expect(try f.bytes() == f.mine && !f.isConflicted())
        let contents = try conflictBackupContents(result.backupDirectory)
        try expect(contents.contains(before) && contents.contains(f.mine) && contents.contains(f.theirs), "All reviewed versions must remain recoverable")
        let permissions = try FileManager.default.attributesOfItem(atPath: result.backupDirectory.path)[.posixPermissions] as? NSNumber
        try expect(permissions?.intValue == 0o700)
        try expect(try f.base.read("outside.txt") == "other edit must remain\n" && f.base.read("extra.txt") == "extra must remain\n")
        try expect(try f.base.youngest() == revision, "Resolving must not commit")
    }

    func testTheirsUsesPinnedConflictVersionEvenWhenHeadAdvances() async throws {
        let f = try await ConflictFixture.make(); defer { f.remove() }
        let conflictRevision = try f.base.youngest()
        try Data("later HEAD must not be used\n".utf8).write(to: f.peer.appendingPathComponent(f.path))
        _ = try f.base.svn(["commit", "-m", "later HEAD", "--", f.path + "@"], at: f.peer)
        let plan = try await f.client.prepareConflict(at: f.wc, path: f.path)
        try expect(plan.incomingRevision == conflictRevision && plan.comparison?.remote.text == "incoming change\n")
        let reviewed = try await f.client.prepareConflictResolution(plan, choice: .theirs)
        let revision = try f.base.youngest()
        _ = try await f.client.applyConflictResolution(reviewed, backupRoot: f.backups)
        try expect(try f.bytes() == f.theirs && !f.isConflicted() && f.base.youngest() == revision)
    }

    func testManualMergeRejectsMarkersAndWritesExplicitLineEndings() async throws {
        let f = try await ConflictFixture.make(); defer { f.remove() }
        let plan = try await f.client.prepareConflict(at: f.wc, path: f.path)
        try expect(plan.canMerge && plan.workingDocument?.text.contains("<<<<<<<") == true)
        let before = try f.bytes()
        for text in ["<<<<<<< .mine\nlocal\n=======\nremote\n>>>>>>> .r2\n", "kept\n>>>>>>> .r2\n", "||||||| .r1\nbase\n"] {
            try await conflictMustFail { _ = try await f.client.prepareConflictResolution(plan, choice: .manual, mergedText: text, lineEnding: .lf) }
        }
        try expect(try f.bytes() == before && f.isConflicted())
        let reviewed = try await f.client.prepareConflictResolution(plan, choice: .manual, mergedText: "local and incoming\n合并完成\n", lineEnding: .crlf)
        try expect(try f.bytes() == before)
        _ = try await f.client.applyConflictResolution(reviewed, backupRoot: f.backups)
        try expect(try f.bytes() == Data("local and incoming\r\n合并完成\r\n".utf8) && !f.isConflicted())
        try expect(try f.base.youngest() == f.initialConflictRevision)
    }

    func testManualMergePreservesUTF16BOMAndLegacyEncodingLosslessly() async throws {
        let utf16: (String) -> Data = { text in Data([0xFF, 0xFE]) + (text.data(using: .utf16LittleEndian) ?? Data()) }
        let f = try await ConflictFixture.make(base: utf16("基础\r\n"), mine: utf16("本地\r\n"), theirs: utf16("云端\r\n"), mime: "application/octet-stream")
        defer { f.remove() }
        let plan = try await f.client.prepareConflict(at: f.wc, path: f.path)
        try expect(plan.canMerge && plan.comparison?.local.encoding.contains("UTF-16 LE") == true)
        let reviewed = try await f.client.prepareConflictResolution(plan, choice: .manual, mergedText: "本地与云端\n", lineEnding: .crlf)
        _ = try await f.client.applyConflictResolution(reviewed, backupRoot: f.backups)
        try expect(try f.bytes() == utf16("本地与云端\r\n") && !f.isConflicted())

        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0632)))
        let g = try await ConflictFixture.make(base: try require("基础\r\n".data(using: encoding)),
            mine: try require("本地\r\n".data(using: encoding)), theirs: try require("云端\r\n".data(using: encoding)), mime: "application/octet-stream")
        defer { g.remove() }
        let legacy = try await g.client.prepareConflict(at: g.wc, path: g.path)
        try expect(legacy.canMerge && legacy.comparison?.local.encoding.hasPrefix("GB") == true)
        let merged = try await g.client.prepareConflictResolution(legacy, choice: .manual, mergedText: "合并中文\n", lineEnding: .crlf)
        _ = try await g.client.applyConflictResolution(merged, backupRoot: g.backups)
        try expect(try g.bytes() == "合并中文\r\n".data(using: encoding) && !g.isConflicted())
    }

    func testBinaryChoicesKeepRawBytesAndMislabeledCodeRemainsComparable() async throws {
        for choice in [SVNConflictChoice.mine, .theirs] {
            let f = try await ConflictFixture.make(base: Data([0, 1, 2, 3]), mine: Data([0, 4, 5, 6]), theirs: Data([0, 7, 8, 9]), mime: "application/octet-stream")
            defer { f.remove() }
            let plan = try await f.client.prepareConflict(at: f.wc, path: f.path)
            try expect(plan.comparison == nil && !plan.canMerge && plan.blockingReason == nil)
            try await conflictMustFail { _ = try await f.client.prepareConflictResolution(plan, choice: .manual, mergedText: "not binary") }
            let reviewed = try await f.client.prepareConflictResolution(plan, choice: choice)
            _ = try await f.client.applyConflictResolution(reviewed, backupRoot: f.backups)
            try expect(try f.bytes() == (choice == .mine ? f.mine : f.theirs) && !f.isConflicted())
            try expect(try f.base.youngest() == f.initialConflictRevision)
        }
        let text = try await ConflictFixture.make(mime: "application/octet-stream"); defer { text.remove() }
        let plan = try await text.client.prepareConflict(at: text.wc, path: text.path)
        try expect(plan.comparison?.local.text == "local change\n" && plan.canMerge, "Content, not the SVN MIME label, decides whether text can be merged")
    }

    func testMergeConflictUsesIncomingBranchSnapshotRatherThanWorkingBranchHead() async throws {
        let f = try ActionFixture(); defer { f.remove() }; try await f.prepare()
        let trunk = f.repo.appendingPathComponent("trunk"), branches = f.repo.appendingPathComponent("branches")
        _ = try f.svn(["mkdir", "-m", "layout", "--", trunk.absoluteString, branches.absoluteString])
        _ = try f.svn(["move", "-m", "move source", "--", f.repo.appendingPathComponent("clean.txt").absoluteString, trunk.appendingPathComponent("code.txt").absoluteString])
        let branch = branches.appendingPathComponent("feature")
        _ = try f.svn(["copy", "-m", "branch", "--", trunk.absoluteString, branch.absoluteString])
        let branchWC = f.root.appendingPathComponent("feature"), trunkWC = f.root.appendingPathComponent("trunk")
        _ = try f.svn(["checkout", "--", branch.absoluteString, branchWC.path])
        _ = try f.svn(["checkout", "--", trunk.absoluteString, trunkWC.path])
        let start = try f.youngest()
        try "incoming from trunk\n".write(to: trunkWC.appendingPathComponent("code.txt"), atomically: true, encoding: .utf8)
        _ = try f.svn(["commit", "-m", "trunk edit", "--", "code.txt@"], at: trunkWC)
        try "local feature edit\n".write(to: branchWC.appendingPathComponent("code.txt"), atomically: true, encoding: .utf8)
        let end = try f.youngest()
        _ = try f.svn(["merge", "--accept", "postpone", "-r", start + ":" + end, "--", trunk.absoluteString + "@", branchWC.path])
        let plan = try await f.client.prepareConflict(at: branchWC, path: "code.txt")
        try expect(plan.operation == "merge" && plan.comparison?.remote.text == "incoming from trunk\n")
        try expect(plan.comparison?.local.text == "local feature edit\n")
        let reviewed = try await f.client.prepareConflictResolution(plan, choice: .theirs)
        _ = try await f.client.applyConflictResolution(reviewed, backupRoot: f.root.appendingPathComponent("backups"))
        try expect(try String(contentsOf: branchWC.appendingPathComponent("code.txt"), encoding: .utf8) == "incoming from trunk\n")
        try expect(try f.youngest() == end)
    }

    func testWorkingAuxiliaryAndRepositoryIdentityDriftStopBeforeWriting() async throws {
        for changed in ["working", "incoming", "identity"] {
            let f = try await ConflictFixture.make(); defer { f.remove() }
            let calls = f.base.root.appendingPathComponent("calls"), flag = f.base.root.appendingPathComponent("drift")
            let client = try conflictClient(f.base, calls: calls, driftFlag: flag)
            let plan = try await client.prepareConflict(at: f.wc, path: f.path)
            let reviewed = try await client.prepareConflictResolution(plan, choice: .theirs)
            if changed == "working" { try Data("new external edit\n".utf8).write(to: f.wc.appendingPathComponent(f.path)) }
            if changed == "incoming" {
                let auxiliary = try f.auxiliary("cur-base-file")
                try Data("changed incoming artifact\n".utf8).write(to: auxiliary)
            }
            if changed == "identity" { try Data().write(to: flag) }
            let before = try f.bytes()
            try await conflictMustFail { _ = try await client.applyConflictResolution(reviewed, backupRoot: f.backups) }
            try expect(try f.bytes() == before && f.isConflicted())
            let commands = try String(contentsOf: calls, encoding: .utf8).split(separator: "\n")
            try expect(!commands.contains("resolve"), "Drift must be rejected before any resolve command")
        }
    }

    func testPropertyTreeAndCompositeConflictsAreNeverSilentlyResolved() async throws {
        for textAlso in [false, true] {
            let f = try ActionFixture(); defer { f.remove() }; try await f.prepare()
            _ = try f.svn(["propset", "fixture:value", "base", "--", "clean.txt@"], at: f.wc)
            _ = try f.svn(["commit", "-m", "base prop", "--", "clean.txt@"], at: f.wc)
            let peer = f.root.appendingPathComponent("peer")
            _ = try f.svn(["checkout", "--", f.repo.absoluteString, peer.path])
            _ = try f.svn(["propset", "fixture:value", "mine", "--", "clean.txt@"], at: f.wc)
            _ = try f.svn(["propset", "fixture:value", "theirs", "--", "clean.txt@"], at: peer)
            if textAlso {
                try f.write("mine text\n", "clean.txt")
                try "their text\n".write(to: peer.appendingPathComponent("clean.txt"), atomically: true, encoding: .utf8)
            }
            _ = try f.svn(["commit", "-m", "remote prop", "--", "clean.txt@"], at: peer)
            _ = try f.svn(["update", "--accept", "postpone", "--", ".@"], at: f.wc)
            let before = try Data(contentsOf: f.wc.appendingPathComponent("clean.txt"))
            let plan = try await f.client.prepareConflict(at: f.wc, path: "clean.txt")
            try expect(plan.blockingReason != nil)
            try await conflictMustFail { _ = try await f.client.prepareConflictResolution(plan, choice: .mine) }
            try expect(try Data(contentsOf: f.wc.appendingPathComponent("clean.txt")) == before)
            let status = try await f.client.status(at: f.wc)
            try expect(status.contains { $0.path == "clean.txt" && $0.properties == "conflicted" })
        }
        let f = try ActionFixture(); defer { f.remove() }; try await f.prepare()
        let peer = f.root.appendingPathComponent("peer")
        _ = try f.svn(["checkout", "--", f.repo.absoluteString, peer.path])
        try f.write("retained local tree edit\n", "clean.txt")
        _ = try f.svn(["delete", "--", "clean.txt@"], at: peer)
        _ = try f.svn(["commit", "-m", "remote delete", "--", "clean.txt@"], at: peer)
        _ = try f.svn(["update", "--accept", "postpone", "--", ".@"], at: f.wc)
        let plan = try await f.client.prepareConflict(at: f.wc, path: "clean.txt")
        try expect(plan.blockingReason != nil)
        try await conflictMustFail { _ = try await f.client.prepareConflictResolution(plan, choice: .theirs) }
        try expect(try f.read("clean.txt") == "retained local tree edit\n")
        let status = try await f.client.status(at: f.wc)
        try expect(status.contains { $0.path == "clean.txt" && $0.treeConflicted })
    }

    func testPathBoundariesSymbolicLinksBackupScopeAndCancellationDoNotWrite() async throws {
        let f = try await ConflictFixture.make(); defer { f.remove() }
        for path in ["../clean.txt", ".svn/wc.db", "/absolute.txt", "new/../../clean.txt"] {
            try await conflictMustFail { _ = try await f.client.prepareConflict(at: f.wc, path: path) }
        }
        let plan = try await f.client.prepareConflict(at: f.wc, path: f.path)
        let reviewed = try await f.client.prepareConflictResolution(plan, choice: .theirs)
        let before = try f.bytes(), badBackups = f.wc.appendingPathComponent("backups")
        try await conflictMustFail { _ = try await f.client.applyConflictResolution(reviewed, backupRoot: badBackups) }
        try expect(!FileManager.default.fileExists(atPath: badBackups.path) && (try f.bytes()) == before)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await f.client.applyConflictResolution(reviewed, backupRoot: f.backups)
        }
        do { try await cancelled.value; throw CheckFailure.failed("Cancelled resolution must not write") }
        catch is CancellationError { }
        try expect(try f.bytes() == before && f.isConflicted())
        let target = f.base.root.appendingPathComponent("outside-file")
        try Data("outside must remain\n".utf8).write(to: target)
        try FileManager.default.removeItem(at: f.wc.appendingPathComponent(f.path))
        try FileManager.default.createSymbolicLink(atPath: f.wc.appendingPathComponent(f.path).path, withDestinationPath: target.path)
        do {
            let symlink = try await f.client.prepareConflict(at: f.wc, path: f.path)
            try expect(symlink.blockingReason != nil)
        } catch let failure as CheckFailure { throw failure }
        catch { }
        try await conflictMustFail { _ = try await f.client.applyConflictResolution(reviewed, backupRoot: f.backups) }
        try expect(try Data(contentsOf: target) == Data("outside must remain\n".utf8))
    }

    func testResolveFailureIsNotReplayedAndLeavesRecoverableBackup() async throws {
        let f = try await ConflictFixture.make(); defer { f.remove() }
        let calls = f.base.root.appendingPathComponent("calls")
        let client = try conflictClient(f.base, calls: calls, failResolve: true)
        let plan = try await client.prepareConflict(at: f.wc, path: f.path)
        let reviewed = try await client.prepareConflictResolution(plan, choice: .theirs)
        let before = try f.bytes(), revision = try f.base.youngest()
        try await conflictMustFail { _ = try await client.applyConflictResolution(reviewed, backupRoot: f.backups) }
        let commands = try String(contentsOf: calls, encoding: .utf8).split(separator: "\n")
        try expect(commands.filter { $0 == "resolve" }.count == 1 && !commands.contains("commit") && !commands.contains("update"))
        try expect(try f.bytes() == before && f.isConflicted() && f.base.youngest() == revision)
        try expect(try conflictBackupContents(f.backups).contains(before), "A failed write must retain a recovery backup")
    }

    func testSpecialNamedFilesAndSizeLimitsStayBounded() async throws {
        let named = try await ConflictFixture.make(path: "中文 文件 @.txt"); defer { named.remove() }
        let plan = try await named.client.prepareConflict(at: named.wc, path: named.path)
        try expect(plan.path == named.path && plan.blockingReason == nil)
        let reviewed = try await named.client.prepareConflictResolution(plan, choice: .theirs)
        _ = try await named.client.applyConflictResolution(reviewed, backupRoot: named.backups)
        try expect(try named.bytes() == named.theirs && !named.isConflicted())
        try expect(try named.base.youngest() == named.initialConflictRevision)

        let oversized = try await ConflictFixture.make(); defer { oversized.remove() }
        let huge = Data(repeating: UInt8(ascii: "x"), count: 4 * 1_024 * 1_024 + 1)
        try huge.write(to: oversized.wc.appendingPathComponent(oversized.path))
        let blocked = try await oversized.client.prepareConflict(at: oversized.wc, path: oversized.path)
        try expect(blocked.blockingReason != nil && blocked.comparison == nil && !blocked.canMerge,
            "Over-limit content must not produce an interactive full-file comparison")
        for choice in [SVNConflictChoice.mine, .theirs, .manual] {
            try await conflictMustFail { _ = try await oversized.client.prepareConflictResolution(blocked, choice: choice, mergedText: "replacement") }
        }
        try expect(try oversized.bytes() == huge && oversized.isConflicted())
        try expect(!FileManager.default.fileExists(atPath: oversized.backups.path))

        let length = 600 * 1_024
        let medium = try await ConflictFixture.make(base: Data(repeating: UInt8(ascii: "b"), count: length) + Data([10]),
            mine: Data(repeating: UInt8(ascii: "m"), count: length) + Data([10]),
            theirs: Data(repeating: UInt8(ascii: "t"), count: length) + Data([10]))
        defer { medium.remove() }
        let bounded = try await medium.client.prepareConflict(at: medium.wc, path: medium.path)
        try expect(bounded.blockingReason == nil && bounded.comparison != nil && !bounded.canMerge,
            "Medium text files support complete versions while keeping the manual editor bounded")
        let before = try medium.bytes()
        try await conflictMustFail { _ = try await medium.client.prepareConflictResolution(bounded, choice: .manual, mergedText: "manual result") }
        try expect(try medium.bytes() == before && medium.isConflicted())
        let full = try await medium.client.prepareConflictResolution(bounded, choice: .mine)
        _ = try await medium.client.applyConflictResolution(full, backupRoot: medium.backups)
        try expect(try medium.bytes() == medium.mine && !medium.isConflicted())
        try expect(try medium.base.youngest() == medium.initialConflictRevision)
    }
}

private struct ConflictFixture {
    let base: ActionFixture
    let peer: URL
    let mine: Data
    let theirs: Data
    let initialConflictRevision: String
    let path: String
    var wc: URL { base.wc }
    var client: SVNClient { base.client }
    var backups: URL { base.root.appendingPathComponent("conflict backups") }
    func remove() { base.remove() }
    func bytes() throws -> Data { try Data(contentsOf: wc.appendingPathComponent(path)) }
    func isConflicted() throws -> Bool {
        try base.svn(["status", "--xml", "--", path + "@"], at: wc).contains("item=\"conflicted\"")
    }
    func auxiliary(_ tag: String) throws -> URL {
        let text = try base.svn(["info", "--xml", "--", path + "@"], at: wc)
        let regex = try NSRegularExpression(pattern: "<" + tag + ">([^<]+)</" + tag + ">")
        let match = try require(regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)))
        let range = try require(Range(match.range(at: 1), in: text))
        let value = String(text[range]).replacingOccurrences(of: "&amp;", with: "&")
        return value.hasPrefix("/") ? URL(fileURLWithPath: value) : wc.appendingPathComponent(value)
    }
    static func make(base content: Data = Data("base clean\n".utf8), mine: Data = Data("local change\n".utf8),
                     theirs: Data = Data("incoming change\n".utf8), mime: String? = nil, path: String = "clean.txt") async throws -> ConflictFixture {
        let f = try ActionFixture()
        do {
            try await f.prepare()
            if path != "clean.txt" { _ = try f.svn(["move", "--", "clean.txt@", path], at: f.wc) }
            if content != Data("base clean\n".utf8) || mime != nil || path != "clean.txt" {
                try content.write(to: f.wc.appendingPathComponent(path))
                if let mime { _ = try f.svn(["propset", "svn:mime-type", mime, "--", path + "@"], at: f.wc) }
                _ = try f.svn(["commit", "-m", "conflict baseline", "--", ".@"], at: f.wc)
            }
            let peer = f.root.appendingPathComponent("peer")
            _ = try f.svn(["checkout", "--", f.repo.absoluteString, peer.path])
            try mine.write(to: f.wc.appendingPathComponent(path))
            try theirs.write(to: peer.appendingPathComponent(path))
            _ = try f.svn(["commit", "-m", "incoming conflict", "--", path + "@"], at: peer)
            _ = try f.svn(["update", "--accept", "postpone", "--", ".@"], at: f.wc)
            let result = ConflictFixture(base: f, peer: peer, mine: mine, theirs: theirs, initialConflictRevision: try f.youngest(), path: path)
            try expect(try result.isConflicted(), "Fixture must create a real SVN text conflict")
            return result
        } catch { f.remove(); throw error }
    }
}

private func conflictBackupContents(_ directory: URL) throws -> [Data] {
    guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
    var contents: [Data] = []
    for case let file as URL in enumerator where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
        contents.append(try Data(contentsOf: file))
    }
    return contents
}

private func conflictMustFail(_ operation: () async throws -> Void) async throws {
    do { try await operation(); throw CheckFailure.failed("Expected conflict operation to stop without resolving") }
    catch let error as CheckFailure { throw error }
    catch { }
}

private func conflictClient(_ f: ActionFixture, calls: URL, driftFlag: URL? = nil, failResolve: Bool = false) throws -> SVNClient {
    let wrapper = f.root.appendingPathComponent("conflict-svn-wrapper")
    var script = "#!/bin/sh\nprintf '%s\\n' \"$1\" >> " + conflictQuote(calls.path) + "\n"
    if failResolve { script += "if [ \"$1\" = resolve ]; then printf 'svn: E155004: fixture resolve failure\\n' >&2; exit 1; fi\n" }
    if let driftFlag {
        script += "if [ \"$1\" = info ] && [ -f " + conflictQuote(driftFlag.path) + " ]; then\n" + conflictQuote(f.binary) + " \"$@\" | /usr/bin/sed -E 's|<uuid>[^<]+</uuid>|<uuid>changed-fixture-identity</uuid>|g'\nexit $?\nfi\n"
    }
    script += "exec " + conflictQuote(f.binary) + " \"$@\"\n"
    try script.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    return SVNClient(executablePath: wrapper.path, globalIgnoreConfigurationFiles: [])
}

private func conflictQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
