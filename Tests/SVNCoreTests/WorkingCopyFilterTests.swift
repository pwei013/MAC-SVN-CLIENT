import Foundation
import SVNCore

struct WorkingCopyFilterTests {
    func testSelectAllUsesVisibleEligibleRowsAndPreservesHiddenChecks() throws {
        let entries = [item("src/modified.cs", "modified"), item("src/new", "unversioned", kind: .directory),
                       item("src/missing.cs", "missing"), item("src/property.cs", "normal", props: "modified"),
                       item("src/ignored", "ignored"), item("src/conflict.cs", "conflicted"),
                       item("src/tree.cs", "missing", tree: true), item("src/props.cs", "unversioned", props: "conflicted"),
                       item("src/blocked", "obstructed"), item("src/external", "external"), item("docs/hidden.md", "modified")]
        let visible = try WorkingCopyFilterResult.evaluate(entries, query: "src/", status: .all, kind: .all)
        try expect(visible.checkablePaths == ["src/modified.cs", "src/new", "src/missing.cs", "src/property.cs"])
        try expect(Set(visible.entries.filter(\.canCheck).map(\.path)) == visible.checkablePaths)
        var checked: Set<String> = ["docs/hidden.md"]
        checked.formUnion(visible.checkablePaths)
        try expect(checked.count == 5 && checked.contains("docs/hidden.md"))
        checked.subtract(visible.visiblePaths)
        try expect(checked == ["docs/hidden.md"])
        let ignored = try WorkingCopyFilterResult.evaluate(entries, query: "", status: .ignored, kind: .all)
        let empty = try WorkingCopyFilterResult.evaluate(entries, query: "not-found", status: .all, kind: .all)
        try expect(ignored.checkablePaths.isEmpty && empty.checkablePaths.isEmpty)
    }

    func testStatusGroupsPrioritizeAllConflictKindsAndProperties() throws {
        let entries = [
            item("modified.cs", "modified"), item("property.cs", "normal", props: "modified"),
            item("added.cs", "added"), item("deleted", "deleted", kind: .directory), item("new.cs", "unversioned"),
            item("tree.cs", "modified", tree: true), item("prop-conflict.cs", "added", props: "conflicted"),
            item("conflict.cs", "conflicted"), item("missing.cs", "missing"), item("ignored", "ignored", kind: .directory),
            item("replaced.cs", "replaced"), item("blocked", "obstructed", kind: .directory),
            item("incomplete", "incomplete", kind: .directory), item("external", "external", kind: .directory),
            item(".", "none", props: "modified", kind: .directory)
        ]
        let all = try WorkingCopyFilterResult.evaluate(entries, query: "", status: .all, kind: .all)
        try expect(all.entries.count == 15 && all.counts[.all] == 15)
        try expect(all.counts[.modified] == 3 && all.counts[.conflicted] == 3 && all.counts[.versioned] == 12)
        try expect(all.counts[.other] == 4 && all.counts[.added] == 1 && all.counts[.deleted] == 1)
        let conflicts = try WorkingCopyFilterResult.evaluate(entries, query: "", status: .conflicted, kind: .all)
        try expect(conflicts.entries.map(\.path) == ["tree.cs", "prop-conflict.cs", "conflict.cs"])
        let tracked = try WorkingCopyFilterResult.evaluate(entries, query: "", status: .versioned, kind: .all)
        try expect(tracked.entries.count == 12 && !tracked.entries.contains { ["new.cs", "ignored", "external"].contains($0.path) })
        try expect(tracked.counts == all.counts, "Shortcut counts are independent of the selected status")
    }

    func testPathTypeAndStatusComposeWithoutChangingInput() throws {
        let values = [item("src/中文 A.cs", "modified"), item("src/中文 B.cs", "unversioned"),
                      item("src/中文目录", "unversioned", kind: .directory), item("src/other.cs", "modified"),
                      item("docs/中文.md", "modified")]
        let checked = Set(["docs/中文.md", "src/中文 B.cs"])
        let result = try WorkingCopyFilterResult.evaluate(values, query: "sRc/中文", status: .modified, kind: .files)
        try expect(result.entries.map(\.path) == ["src/中文 A.cs"])
        try expect(result.counts[.all] == 2 && result.counts[.modified] == 1 && result.counts[.unversioned] == 1)
        try expect(checked.subtracting(result.visiblePaths).count == 2, "Hidden checked entries must remain in the original checked set")
        try expect(values.map(\.path) == ["src/中文 A.cs", "src/中文 B.cs", "src/中文目录", "src/other.cs", "docs/中文.md"])
        let all = try WorkingCopyFilterResult.evaluate(values, query: "", status: .all, kind: .all)
        try expect(all.entries.count == values.count && checked.isSubset(of: all.visiblePaths))
        let empty = try WorkingCopyFilterResult.evaluate(values, query: "not-found", status: .added, kind: .directories)
        try expect(empty.entries.isEmpty && empty.counts.isEmpty)
    }

    func testNodeKindsUseMetadataInsteadOfExtensions() throws {
        let values = [item("folder.cs", "unversioned", kind: .directory), item("no-extension", "modified"),
                      item("link", "modified", kind: .symbolicLink), item("unknown.cs", "missing", kind: .unknown)]
        let files = try WorkingCopyFilterResult.evaluate(values, query: "", status: .all, kind: .files)
        let directories = try WorkingCopyFilterResult.evaluate(values, query: "", status: .all, kind: .directories)
        try expect(files.entries.map(\.path) == ["no-extension", "link"])
        try expect(directories.entries.map(\.path) == ["folder.cs"])
        let all = try WorkingCopyFilterResult.evaluate(values, query: "", status: .all, kind: .all)
        try expect(all.entries.count == 4)
    }

    func testLegacyProjectDraftsKeepContentWhenFiltersAreMissing() throws {
        let old = """
        {"commitMessage":"旧版草稿","checkedPaths":["src/文件.cs"],"changeSearch":"文件","changeSelection":"src/文件.cs"}
        """
        let legacy = try JSONDecoder().decode(SVNProjectState.self, from: Data(old.utf8))
        try expect(legacy.commitMessage == "旧版草稿" && legacy.checkedPaths == ["src/文件.cs"] && legacy.changeSearch == "文件")
        try expect(legacy.statusFilter == .all && legacy.kindFilter == .all)
        let state = SVNProjectState(commitMessage: legacy.commitMessage, checkedPaths: legacy.checkedPaths,
            changeSearch: legacy.changeSearch, changeSelection: legacy.changeSelection, statusFilter: .modified, kindFilter: .files)
        try expect(try JSONDecoder().decode(SVNProjectState.self, from: JSONEncoder().encode(state)) == state)
        var unknown = try require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        unknown["statusFilter"] = "future-status"; unknown["kindFilter"] = "future-kind"
        let restored = try JSONDecoder().decode(SVNProjectState.self, from: JSONSerialization.data(withJSONObject: unknown))
        try expect(restored.commitMessage == "旧版草稿" && restored.checkedPaths == legacy.checkedPaths && restored.statusFilter == .all && restored.kindFilter == .all)
    }

    func testLargeFilteringAndCancellationStayBounded() async throws {
        let values = (0..<50_000).map { index in item("src/file\(index).cs", index.isMultiple(of: 5) ? "modified" : "unversioned") }
        let worker = Task.detached { try WorkingCopyFilterResult.evaluate(values, query: "src/", status: .modified, kind: .files) }
        let result = try await worker.value
        try expect(result.entries.count == 10_000 && result.visiblePaths.count == 10_000 && result.counts[.all] == 50_000)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try WorkingCopyFilterResult.evaluate(values, query: "", status: .all, kind: .all)
        }
        do { _ = try await cancelled.value; throw CheckFailure.failed("Filtering cancellation must stop") }
        catch is CancellationError { }
    }

    private func item(_ path: String, _ state: String, props: String = "none", tree: Bool = false,
                      kind: WorkingCopyNodeKind = .file) -> WorkingCopyChange {
        WorkingCopyChange(path: path, item: state, properties: props, treeConflicted: tree, nodeKind: kind)
    }
}
