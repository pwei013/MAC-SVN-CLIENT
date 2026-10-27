import Foundation
import SVNCore

struct CommitRecoveryTests {
    func testOutOfDateRecommendsUpdateAndDoesNotRetryCommit() async throws {
        let f = try ActionFixture(); defer { f.remove() }; try await f.prepare()
        let peer = f.root.appendingPathComponent("peer")
        _ = try f.svn(["checkout", "--", f.repo.absoluteString, peer.path])
        try "remote changed\n".write(to: peer.appendingPathComponent("clean.txt"), atomically: true, encoding: .utf8)
        _ = try f.svn(["commit", "-m", "remote", "--", "clean.txt@"], at: peer)
        try f.write("local changed\n", "clean.txt"); try f.write("extra kept\n", "extra.txt")
        let marker = f.root.appendingPathComponent("commands"), wrapper = try recoveryWrapper(f, marker: marker)
        let client = SVNClient(executablePath: wrapper.path)
        var failure: Error?
        do { _ = try await client.commitWithProgress(at: f.wc, paths: ["clean.txt"], message: "will fail") { _ in } }
        catch { failure = error }
        let plan = try await client.prepareCommitRecovery(at: f.wc, attemptedPaths: ["clean.txt"], error: try require(failure))
        try expect(plan.actions.first == .update && plan.scope(for: .update) == [f.wc.path])
        try expect(plan.problemPaths == ["clean.txt"] && plan.undoAddPlan == nil,
            "Reported paths: \(plan.problemPaths); diagnostic: \(plan.details)")
        try expect(try f.read("clean.txt") == "local changed\n" && f.read("extra.txt") == "extra kept\n")
        try await client.validateCommitRecovery(plan)
        let calls = try String(contentsOf: marker, encoding: .utf8).split(separator: "\n")
        try expect(calls.filter { $0 == "commit" }.count == 1 && !calls.contains("update"))
        _ = try await client.updateWithProgress(at: f.wc) { _ in }
        try expect(try f.read("clean.txt").contains("local changed") && f.read("extra.txt") == "extra kept\n")
        try expect(try f.youngest() == "2", "Recommended update must never resubmit code")
    }

    func testMissingParentsUsesTypedPathsAndOnlyChangesSelection() async throws {
        let f = try ActionFixture(); defer { f.remove() }; try await f.prepare()
        try f.write("new content\n", "new/nested/child.txt")
        _ = try await f.client.add(at: f.wc, paths: ["new"])
        var failure: Error?
        do { _ = try await f.client.commitWithProgress(at: f.wc, paths: ["new/nested/child.txt"], message: "missing parents") { _ in } }
        catch { failure = error }
        try expect(failure is SVNCommitSelectionFailure)
        let plan = try await f.client.prepareCommitRecovery(at: f.wc, attemptedPaths: ["new/nested/child.txt"], error: try require(failure))
        try expect(plan.actions.first == .selectParents && plan.parentPaths == ["new", "new/nested"])
        let selection: Set<String> = ["new/nested/child.txt", "outside.txt"]
        let parents = try await f.client.recoverySelectionPaths(plan, action: .selectParents, currentSelection: selection)
        try expect(Set(parents) == ["new", "new/nested"])
        try expect(selection.union(parents) == ["new", "new/nested", "new/nested/child.txt", "outside.txt"])
        let empty = try await f.client.recoverySelectionPaths(plan, action: .selectParents, currentSelection: selection.union(parents))
        try expect(empty.isEmpty)
        try expect(try f.read("new/nested/child.txt") == "new content\n" && f.youngest() == "1")
        _ = try f.svn(["revert", "--depth", "infinity", "--", "new@"], at: f.wc)
        try await recoveryMustFail { _ = try await f.client.recoverySelectionPaths(plan, action: .selectParents, currentSelection: selection) }
    }

    func testMissingPathDoesNotGuessTargetsAndCanUnaddConfirmedFile() async throws {
        let f = try ActionFixture(); defer { f.remove() }; try await f.prepare()
        let name = "D:\\Local\\internal-nlog.txt"
        try f.write("keep this log\n", name); _ = try await f.client.add(at: f.wc, paths: [name])
        let detail = "svn: E155011: File '\(f.wc.appendingPathComponent(name).path)' is out of date\nsvn: E160013: '/untrusted/not-selected.txt' path not found"
        let plan = try await f.client.prepareCommitRecovery(at: f.wc, attemptedPaths: [name], error: SVNCommitFailure.diagnose(SVNError.command(1, detail)))
        try expect(plan.actions.first == .inspectIncoming && plan.actions.contains(.update) && plan.actions.contains(.undoAdd))
        try expect(plan.problemPaths == [name] && plan.undoAddPlan?.targets == [name])
        let excluded = try await f.client.recoverySelectionPaths(plan, action: .excludeSelection, currentSelection: [name, "outside.txt"])
        try expect(excluded == [name])
        try await f.client.applyLocalAction(try require(plan.undoAddPlan), keepLocal: true)
        try expect(try f.read(name) == "keep this log\n" && f.youngest() == "1")
        let unknown = try await f.client.prepareCommitRecovery(at: f.wc, attemptedPaths: ["outside.txt"], error: SVNError.command(1, "svn: E160013: '/untrusted/outside.txt' path not found"))
        try expect(unknown.problemPaths.isEmpty && !unknown.actions.contains(.undoAdd) && !unknown.actions.contains(.excludeSelection))
        _ = try f.svn(["copy", "--", "folder/a.txt@", "copy.txt"], at: f.wc)
        let copied = try await f.client.prepareCommitRecovery(at: f.wc, attemptedPaths: ["copy.txt"], error: SVNError.command(1, "svn: E160013: 'copy.txt' path not found"))
        try expect(!copied.actions.contains(.undoAdd))
    }

    func testUncertainAndConfirmedResultsRecommendReadOnlyChecks() async throws {
        let f = try ActionFixture(); defer { f.remove() }; try await f.prepare()
        let cases = ["svn: E175002: Connection reset by peer", "svn: E165007: post-commit hook failed", "svn: E999999: unknown failure"]
        for detail in cases {
            let plan = try await f.client.prepareCommitRecovery(at: f.wc, attemptedPaths: ["clean.txt"], error: SVNError.command(1, detail))
            try expect(plan.actions.first == .inspectHistory)
            try expect(!plan.actions.contains(where: \.writesWorkingCopy))
        }
        let committed = try await f.client.prepareCommitRecovery(at: f.wc, attemptedPaths: ["clean.txt"], error: SVNError.invalid("local refresh failed"), confirmedRevision: "8")
        try expect(committed.actions == [.inspectHistory, .refresh, .review] && committed.reason.contains("r8"))
        let hook = try await f.client.prepareCommitRecovery(at: f.wc, attemptedPaths: ["clean.txt"], error: SVNError.command(1, "svn: E165001: pre-commit rejected"))
        try expect(hook.actions == [.editMessage, .review])
        try expect(try f.youngest() == "1")
    }

    func testCleanupRequiresAcknowledgmentAndNeverRemovesFiles() async throws {
        let f = try ActionFixture(); defer { f.remove() }; try await f.prepare()
        try f.write("keep modification\n", "clean.txt"); try f.write("keep extra\n", "extra.txt")
        let marker = f.root.appendingPathComponent("commands"), wrapper = try recoveryWrapper(f, marker: marker)
        let client = SVNClient(executablePath: wrapper.path)
        let plan = try await client.prepareCommitRecovery(at: f.wc, attemptedPaths: ["clean.txt"], error: SVNError.command(1, "svn: E155004: working copy locked"))
        let info = try await client.info(at: f.wc)
        try expect(plan.actions.first == .cleanup && plan.scope(for: .cleanup) == [info.rootPath])
        try await recoveryMustFail { try await client.cleanupForCommitRecovery(plan, confirmedNoOtherClients: false) }
        var calls = try String(contentsOf: marker, encoding: .utf8).split(separator: "\n")
        try expect(!calls.contains("cleanup"))
        try await client.cleanupForCommitRecovery(plan, confirmedNoOtherClients: true)
        calls = try String(contentsOf: marker, encoding: .utf8).split(separator: "\n")
        try expect(calls.filter { $0 == "cleanup" }.count == 1)
        try expect(try f.read("clean.txt") == "keep modification\n" && f.read("extra.txt") == "keep extra\n" && f.youngest() == "1")
    }

    func testIdentityDriftFallbackAndCancellationPreventRepairs() async throws {
        let f = try ActionFixture(); defer { f.remove() }; try await f.prepare()
        let plan = try await f.client.prepareCommitRecovery(at: f.wc, attemptedPaths: ["clean.txt"], error: SVNError.command(1, "svn: E155011: 'clean.txt' is out of date"))
        _ = try f.svn(["switch", "--ignore-ancestry", "--", f.repo.appendingPathComponent("folder").absoluteString + "@", f.wc.path])
        try await recoveryMustFail { try await f.client.validateCommitRecovery(plan) }
        let bad = f.root.appendingPathComponent("bad-svn")
        try "#!/bin/sh\nprintf '<invalid/>'\n".write(to: bad, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bad.path)
        let fallback = try await SVNClient(executablePath: bad.path).prepareCommitRecovery(at: f.root, attemptedPaths: ["file.txt"], error: SVNError.command(1, "svn: E155004: locked"))
        try expect(fallback.actions == [.review] && fallback.inspectionWarning != nil)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await f.client.prepareCommitRecovery(at: f.wc, attemptedPaths: ["file.txt"], error: SVNError.invalid("fixture"))
        }
        do { try await task.value; throw CheckFailure.failed("Cancelled preparation must stop") }
        catch is CancellationError { }
    }

    func testAccountSuggestionUsesRepositoryScopeAndPreservesDiagnostics() async throws {
        let f = try ActionFixture(); defer { f.remove() }
        let executable = f.root.appendingPathComponent("mock-svn")
        let xml = "<info><entry kind=\"dir\" path=\".\" revision=\"1\"><url>https://svn.example.invalid/repository/trunk</url><repository><root>https://svn.example.invalid/repository</root><uuid>fixture</uuid></repository><wc-info><wcroot-abspath>\(f.root.path)</wcroot-abspath><schedule>normal</schedule></wc-info></entry></info>"
        let script = "#!/bin/sh\ncase \"$1\" in info) printf '%s' \(recoveryQuote(xml)) ;; status) printf '<status><target path=\".\"/></status>' ;; *) exit 90 ;; esac\n"
        try script.write(to: executable, atomically: true, encoding: .utf8); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let plan = try await SVNClient(executablePath: executable.path).prepareCommitRecovery(at: f.root, attemptedPaths: ["file.txt"], error: SVNError.command(1, "svn: E175013: access forbidden; token=synthetic-token"))
        try expect(plan.actions == [.changeAccount, .review] && plan.scope(for: .changeAccount) == ["https://svn.example.invalid/repository"])
        try expect(!plan.details.contains("synthetic-token"))
    }
}

private func recoveryMustFail(_ action: () async throws -> Void) async throws {
    do { try await action(); throw CheckFailure.failed("Expected recovery to stop") }
    catch let error as CheckFailure { throw error }
    catch { }
}
private func recoveryQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
private func recoveryWrapper(_ f: ActionFixture, marker: URL) throws -> URL {
    let wrapper = f.root.appendingPathComponent("svn-wrapper")
    let script = "#!/bin/sh\nprintf '%s\\n' \"$1\" >> \(recoveryQuote(marker.path))\nif [ \"$1\" = cleanup ]; then\n for arg in \"$@\"; do case \"$arg\" in --remove-*|--include-externals|--vacuum-pristines) exit 99 ;; esac; done\nfi\nexec \(recoveryQuote(f.binary)) \"$@\"\n"
    try script.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    return wrapper
}
