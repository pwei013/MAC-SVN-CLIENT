import Darwin
import Foundation
import SVNCore

struct IncomingUpdatesTests {
    func testIncomingComparisonUsesCheckedPathForReplacedNodes() async throws {
        let fixture = try await HistoryIncomingFixture.make()
        defer { fixture.remove() }
        let old = fixture.other.appendingPathComponent(fixture.name)
        let moved = fixture.other.appendingPathComponent("moved-original.cs")
        _ = try await fixture.run(["move", "--", old.path + "@", moved.path])
        try fixture.write("replacement node at same path\n", to: old)
        _ = try await fixture.run(["add", "--", old.path + "@"])
        _ = try await fixture.run(["commit", "-m", "replace path with a different node", "--", fixture.other.path + "@"])
        let client = fixture.client()
        let report = try await client.incomingUpdates(at: fixture.wc)
        try expect(report.entries.contains(where: { $0.path == fixture.name && $0.remoteItem == "replaced" }))
        let target = try await client.prepareRemoteFileDiff(at: fixture.wc, path: fixture.name)
        let files = try await client.fileComparison(target, revision: .revision(report.revision), snapshotPath: true)
        try expect(files.local.text == "base 中文\n" && files.remote.text == "replacement node at same path\n")
        try fixture.write("newer replacement content\n", to: old)
        _ = try await fixture.run(["commit", "-m", "advance after checked snapshot", "--", fixture.other.path + "@"])
        let pinned = try await client.fileComparison(target, revision: .revision(report.revision), snapshotPath: true)
        try expect(pinned.remote.text == "replacement node at same path\n", "Incoming comparison must stay at the checked numeric snapshot")
        try expect(try String(contentsOf: fixture.wc.appendingPathComponent(fixture.name), encoding: .utf8) == "base 中文\n")
    }

    func testIncomingUpdatesReportsRemoteChangesAndPreservesLocalState() async throws {
        let fixture = try await HistoryIncomingFixture.make()
        defer { fixture.remove() }
        try fixture.write("local edit retained\n", to: fixture.wc.appendingPathComponent(fixture.name))
        try fixture.write("local only changed\n", to: fixture.wc.appendingPathComponent("local-only.txt"))
        try fixture.write("remote edit\n", to: fixture.other.appendingPathComponent(fixture.name))
        try fixture.write("new remotely\n", to: fixture.other.appendingPathComponent("new @ remote.txt"))
        _ = try await fixture.run(["add", "--", fixture.other.appendingPathComponent("new @ remote.txt").path + "@"])
        _ = try await fixture.run(["delete", "--", fixture.other.appendingPathComponent("remove.txt").path + "@"])
        _ = try await fixture.run(["propset", "svn:ignore", "*.fixture-ignore", "--", fixture.other.path + "@"])
        _ = try await fixture.run(["commit", "--username", "incoming-author", "-m", "remote modifications", "--", fixture.other.path + "@"])
        let before = try await fixture.state()
        let revision = try await fixture.youngest()
        let localBytes = try Data(contentsOf: fixture.wc.appendingPathComponent(fixture.name))
        let report = try await fixture.client().incomingUpdates(at: fixture.wc)
        try expect(report.revision == 2)
        try expect(report.entries.contains(where: { $0.path == fixture.name && $0.remoteItem == "modified" && $0.hasLocalChanges && $0.nodeKind == .file }))
        try expect(report.entries.contains(where: { $0.path == "remove.txt" && $0.remoteItem == "deleted" && !$0.hasLocalChanges }))
        try expect(report.entries.contains(where: { $0.path == "new @ remote.txt" && $0.remoteItem == "added" && $0.nodeKind == .unknown }))
        try expect(report.entries.contains(where: { $0.path == "." && $0.remoteProperties == "modified" && $0.isDirectory }))
        try expect(!report.entries.contains(where: { $0.path == "local-only.txt" }), "Local-only modifications must not appear as incoming changes")
        let after = try await fixture.state()
        let youngest = try await fixture.youngest()
        try expect(before == after && youngest == revision)
        try expect(try Data(contentsOf: fixture.wc.appendingPathComponent(fixture.name)) == localBytes)
        try expect(!FileManager.default.fileExists(atPath: fixture.wc.appendingPathComponent("new @ remote.txt").path))
        try expect(FileManager.default.fileExists(atPath: fixture.wc.appendingPathComponent("remove.txt").path))
        let subreport = try await fixture.client().incomingUpdates(at: fixture.wc.appendingPathComponent("nested"))
        try expect(subreport.entries.isEmpty && subreport.revision == 2)
    }

    func testIncomingUpdatesRejectsInvalidScopesMalformedAndOversizeResponses() async throws {
        let fixture = try await HistoryIncomingFixture.make()
        defer { fixture.remove() }
        let sampleEntry = "<entry path='PATH'><wc-status item='normal' props='none'/><repos-status item='modified' props='none'/></entry>"
        for xml in ["<status><target path='.'/></status>", "<status><target path='.'><against revision='bad'/></target></status>",
                    "<status><target path='.'>" + sampleEntry.replacingOccurrences(of: "PATH", with: "../outside") + "<against revision='1'/></target></status>",
                    "<status><target path='.'>" + sampleEntry.replacingOccurrences(of: "PATH", with: "/absolute") + "<against revision='1'/></target></status>",
                    "<status><target path='.'>" + sampleEntry.replacingOccurrences(of: "PATH", with: ".svn/wc.db") + "<against revision='1'/></target></status>"] {
            let fake = try fixture.wrapper("if [ \"$1\" = status ]; then printf '%s' \(historyIncomingQuote(xml)); exit 0; fi")
            do {
                _ = try await fake.incomingUpdates(at: fixture.wc)
                throw CheckFailure.failed("Invalid incoming response must be rejected")
            } catch let failure as CheckFailure { throw failure }
            catch is SVNError { }
        }
        let huge = try fixture.wrapper("if [ \"$1\" = status ]; then exec /usr/bin/yes x; fi")
        do {
            _ = try await huge.incomingUpdates(at: fixture.wc)
            throw CheckFailure.failed("Incoming output must be bounded")
        } catch let failure as CheckFailure { throw failure }
        catch let failure as SVNError { try expect(failure.localizedDescription.contains("16 MiB")) }
        let linked = fixture.root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(atPath: linked.path, withDestinationPath: fixture.wc.path)
        do {
            _ = try await fixture.client().incomingUpdates(at: linked)
            throw CheckFailure.failed("Symlink scope must be rejected")
        } catch let failure as CheckFailure { throw failure }
        catch is SVNError { }
    }

    func testIncomingUpdatesCanCancelAndKeepsAuthenticationErrors() async throws {
        let fixture = try await HistoryIncomingFixture.make()
        defer { fixture.remove() }
        let auth = try fixture.wrapper("if [ \"$1\" = status ]; then printf '%s\\n' 'svn: E170001: Authorization failed' >&2; exit 1; fi")
        do {
            _ = try await auth.incomingUpdates(at: fixture.wc)
            throw CheckFailure.failed("Authentication errors must propagate for login handling")
        } catch let failure as CheckFailure { throw failure }
        catch let failure as SVNError { try expect(failure.isAuthenticationFailure) }
        let marker = fixture.root.appendingPathComponent("incoming.pid")
        let slow = try fixture.wrapper("if [ \"$1\" = status ]; then printf '%s' \"$$\" > \(historyIncomingQuote(marker.path)); exec /bin/sleep 30; fi")
        let task = Task { try await slow.incomingUpdates(at: fixture.wc) }
        let pid = try await fixture.waitForPID(marker)
        task.cancel()
        do { _ = try await task.value; throw CheckFailure.failed("Cancelled incoming check must fail") }
        catch is CancellationError { }
        try expect(kill(pid, 0) != 0, "Cancelled status process must be reaped")
    }
}
