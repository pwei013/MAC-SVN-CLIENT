import Foundation
import SVNCore

struct CommitReviewTests {
    func testReadOnlyExpansionMatchesCommittedFilesAndCounts() async throws {
        let f = try ActionFixture(); defer { f.remove() }; try await f.prepare()
        try f.write("edit\n", "clean.txt")
        for path in ["review-new/中文 @.cs", "review-new/sub/child.cs", "review-new/skip-review/file.cs", "review-new/cache.reviewtmp", "outside-new.cs"] {
            try f.write("new\n", path)
        }
        let client = SVNClient(executablePath: f.binary, additionalGlobalIgnores: ["skip-review", "*.reviewtmp"], globalIgnoreConfigurationFiles: [])
        let review = try await client.prepareCommitReview(at: f.wc, paths: ["review-new", "review-new/sub/child.cs", "clean.txt"])
        try expect(review.fileCount == 3 && review.directoryCount == 2)
        try expect(Set(review.entries.map(\.path)) == ["review-new", "review-new/中文 @.cs", "review-new/sub", "review-new/sub/child.cs", "clean.txt"])
        let status = try await client.status(at: f.wc)
        try expect(!status.contains { $0.item == "added" } && f.youngest() == "1", "Reading must not Add or commit")
        let result = try await client.commitIncludingUnversionedWithProgress(at: f.wc, paths: review.selectedPaths,
            message: "reviewed mixed scope", reviewed: review) { _ in }
        try expect(Set(result.paths) == Set(review.entries.map(\.path)) && result.revision == "2")
        try expect(try f.read("review-new/cache.reviewtmp") == "new\n")
    }

    func testUserConfigAndInheritedPropertiesExcludeOnlyApplicableNames() async throws {
        let f = try ActionFixture(); defer { f.remove() }; try await f.prepare()
        let config = f.root.appendingPathComponent("config")
        try "[miscellany]\nreview-pattern = *.reviewconfig\nglobal-ignores = %(review-pattern)s\n".write(to: config, atomically: true, encoding: .utf8)
        _ = try f.svn(["propset", "svn:global-ignores", "*.reviewproperty\nignore tree\n", "--", ".@"], at: f.wc)
        _ = try f.svn(["propset", "svn:ignore", "local-only.cs\n", "--", ".@"], at: f.wc)
        for path in ["review-native/include.cs", "review-native/cache.reviewconfig", "review-native/cache.reviewproperty", "review-native/ignore tree/child.cs", "review-native/local-only.cs"] {
            try f.write("new\n", path)
        }
        let client = try configuredReviewClient(f, additional: ["*.reviewextra"])
        let review = try await client.prepareCommitReview(at: f.wc, paths: ["review-native"])
        try expect(review.fileCount == 2 && review.directoryCount == 1)
        try expect(Set(review.entries.map(\.path)) == ["review-native", "review-native/include.cs", "review-native/local-only.cs"])
        let result: SVNOperationResult
        do {
            result = try await client.commitIncludingUnversionedWithProgress(at: f.wc, paths: review.selectedPaths,
                message: "native rules", reviewed: review) { _ in }
        } catch let failure as SVNAutomaticCommitFailure {
            throw CheckFailure.failed("Review: \(review.entries.map(\.path)); actual: \(failure.paths); \(failure.localizedDescription)")
        }
        try expect(Set(result.paths) == Set(review.entries.map(\.path)))
    }

    func testLeafParentsEmptyDirectoryAndSymlinkAreListedWithoutFollowingLinks() async throws {
        let f = try ActionFixture(); defer { f.remove() }; try await f.prepare()
        try f.write("include\n", "review-parent/nested/one.cs")
        try f.write("unselected\n", "review-parent/nested/other.cs")
        try FileManager.default.createDirectory(at: f.wc.appendingPathComponent("review-empty"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.wc.appendingPathComponent("review-link"), withDestinationURL: f.root)
        let review = try await f.client.prepareCommitReview(at: f.wc,
            paths: ["review-parent/nested/one.cs", "review-empty", "review-link"])
        try expect(review.fileCount == 2 && review.directoryCount == 3)
        try expect(!review.entries.contains { $0.path.hasSuffix("other.cs") || $0.path.hasPrefix("review-link/") })
        try expect(review.entries.first { $0.path == "review-link" }?.nodeKind == .symbolicLink)
        let result = try await f.client.commitIncludingUnversionedWithProgress(at: f.wc, paths: review.selectedPaths,
            message: "leaf empty symlink", reviewed: review) { _ in }
        try expect(Set(result.paths) == Set(review.entries.map(\.path)))
    }

    func testChangedManifestStopsBeforeAddAndCanBeReloaded() async throws {
        let f = try ActionFixture(); defer { f.remove() }; try await f.prepare()
        try f.write("initial\n", "review-changing/one.cs")
        let first = try await f.client.prepareCommitReview(at: f.wc, paths: ["review-changing"])
        try f.write("arrived later\n", "review-changing/two.cs")
        do {
            _ = try await f.client.commitIncludingUnversionedWithProgress(at: f.wc, paths: first.selectedPaths,
                message: "stale review", reviewed: first) { _ in }
            throw CheckFailure.failed("A new file requires another review")
        } catch let error as SVNError { try expect(error.localizedDescription.contains("重新读取清单")) }
        let after = try await f.client.status(at: f.wc)
        try expect(!after.contains { $0.item == "added" } && f.youngest() == "1")
        let second = try await f.client.prepareCommitReview(at: f.wc, paths: first.selectedPaths)
        try expect(second.fileCount == 2)
        _ = try await f.client.commitIncludingUnversionedWithProgress(at: f.wc, paths: second.selectedPaths,
            message: "reloaded review", reviewed: second) { _ in }
        try expect(try f.youngest() == "2")
    }

    func testChangedIgnoreRulesAndNestedWorkingCopyNeverCommitUnreviewedFiles() async throws {
        let f = try ActionFixture(); defer { f.remove() }; try await f.prepare()
        try f.write("include\n", "review-rule/one.cs"); try f.write("exclude\n", "review-rule/cache.reviewrule")
        let config = f.root.appendingPathComponent("config")
        try "[miscellany]\nglobal-ignores = *.reviewrule\n".write(to: config, atomically: true, encoding: .utf8)
        let client = try configuredReviewClient(f, additional: ["*.otherreview"])
        let review = try await client.prepareCommitReview(at: f.wc, paths: ["review-rule"])
        try "[miscellany]\nglobal-ignores =\n".write(to: config, atomically: true, encoding: .utf8)
        do {
            _ = try await client.commitIncludingUnversionedWithProgress(at: f.wc, paths: review.selectedPaths,
                message: "changed rules", reviewed: review) { _ in }
            throw CheckFailure.failed("Changed ignore rules require another review")
        } catch let error as SVNError { try expect(error.localizedDescription.contains("发生变化")) }
        _ = try f.svn(["checkout", "--", f.repo.absoluteString, f.wc.appendingPathComponent("review-rule/nested").path])
        do {
            _ = try await client.prepareCommitReview(at: f.wc, paths: ["review-rule"])
            throw CheckFailure.failed("Nested working copy cannot appear as ordinary new files")
        } catch let error as SVNError { try expect(error.localizedDescription.contains("另一个 SVN 工作副本")) }
        try expect(try f.youngest() == "1")
    }

    func testDeletedFilesCountAndCancellationRemainReadOnly() async throws {
        let f = try ActionFixture(); defer { f.remove() }; try await f.prepare()
        _ = try f.svn(["delete", "--keep-local", "--", "folder/a.txt@"], at: f.wc)
        let review = try await f.client.prepareCommitReview(at: f.wc, paths: ["folder/a.txt"])
        try expect(review.fileCount == 1 && review.directoryCount == 0 && review.entries.first?.item == "deleted")
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await f.client.prepareCommitReview(at: f.wc, paths: ["folder/a.txt"])
        }
        do { _ = try await cancelled.value; throw CheckFailure.failed("Cancelled review must stop") }
        catch is CancellationError { }
        try expect(try f.youngest() == "1" && f.read("folder/a.txt") == "base a\n")
    }

    func testFileArrivingDuringAddStopsBeforeRemoteCommit() async throws {
        let f = try ActionFixture(); defer { f.remove() }; try await f.prepare()
        try f.write("reviewed\n", "review-race/one.cs")
        let review = try await f.client.prepareCommitReview(at: f.wc, paths: ["review-race"])
        let wrapper = f.root.appendingPathComponent("svn-race")
        try "#!/bin/sh\nif [ \"$1\" = add ]; then printf 'late file\\n' > \(reviewQuote(f.wc.appendingPathComponent("review-race/late.cs").path)); fi\nexec \(reviewQuote(f.binary)) \"$@\"\n".write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let client = SVNClient(executablePath: wrapper.path, globalIgnoreConfigurationFiles: [])
        do {
            _ = try await client.commitIncludingUnversionedWithProgress(at: f.wc, paths: review.selectedPaths,
                message: "race must stop", reviewed: review) { _ in }
            throw CheckFailure.failed("A file arriving during Add must not reach the server")
        } catch let failure as SVNAutomaticCommitFailure {
            try expect(failure.additionCompleted && failure.localizedDescription.contains("实际清单与确认清单不一致"))
        }
        try expect(try f.youngest() == "1" && f.read("review-race/late.cs") == "late file\n")
    }

    func testLargeFolderUsesBatchedSVNReads() async throws {
        let f = try ActionFixture(); defer { f.remove() }; try await f.prepare()
        for index in 0..<1_000 { try f.write("new\n", "review-large/f\(index).cs") }
        let calls = f.root.appendingPathComponent("calls"), wrapper = f.root.appendingPathComponent("svn-count")
        try "#!/bin/sh\nprintf '%s\\n' \"$1\" >> \(reviewQuote(calls.path))\nexec \(reviewQuote(f.binary)) \"$@\"\n".write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let client = SVNClient(executablePath: wrapper.path, globalIgnoreConfigurationFiles: [])
        let review = try await client.prepareCommitReview(at: f.wc, paths: ["review-large"])
        try expect(review.fileCount == 1_000 && review.directoryCount == 1)
        let reads = try String(contentsOf: calls, encoding: .utf8).split(separator: "\n")
        try expect(reads.count == 3 && !reads.contains("add") && !reads.contains("commit"), "No per-file SVN commands")
    }
}

private func reviewQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
private func configuredReviewClient(_ fixture: ActionFixture, additional: [String]) throws -> SVNClient {
    let wrapper = fixture.root.appendingPathComponent("svn-configured-review")
    try "#!/bin/sh\nexec \(reviewQuote(fixture.binary)) --config-dir \(reviewQuote(fixture.root.path)) \"$@\"\n".write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    return SVNClient(executablePath: wrapper.path, additionalGlobalIgnores: additional,
                     globalIgnoreConfigurationFiles: [fixture.root.appendingPathComponent("config")])
}
