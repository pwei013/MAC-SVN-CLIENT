import Foundation

/// Retain the actual prepared scope when a commit fails after local Add. The UI
/// can preserve the expanded checks without replaying Add or a remote commit.
public struct SVNAutomaticCommitFailure: LocalizedError, @unchecked Sendable {
    public let underlying: Error
    public let paths: [String]
    public let additionCompleted: Bool
    public var errorDescription: String? { underlying.localizedDescription }
}

extension SVNClient {
    /// A single user confirmation authorizes the selected new trees and their
    /// required parents. All reads and writes run outside the UI actor. Never
    /// recurse into existing modified/added directories to enlarge selection.
    public func commitIncludingUnversionedWithProgress(at requestedDirectory: URL, paths requested: [String], message: String,
        onProgress: @escaping @Sendable (SVNOperationEvent) -> Void) async throws -> SVNOperationResult {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SVNError.invalid("请填写提交说明。")
        }
        let directory = requestedDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let targets = Array(Set(requested)).sorted()
        _ = try paths(targets, at: directory)
        try automaticCommitSizeCheck(targets)
        for path in targets where path != "." {
            let parent = directory.appendingPathComponent(path).deletingLastPathComponent().standardizedFileURL
            guard parent == parent.resolvingSymlinksInPath() else {
                throw SVNError.invalid("所选路径经过符号链接目录，已停止自动 Add 和提交：\(path)")
            }
        }
        var before = try await automaticCommitStatuses(at: directory)
        let ancestors = Set(targets.flatMap(automaticCommitAncestors))
        // An explicitly selected file may sit below a not-yet-versioned parent.
        // Batch targeted reads; the normal status list only shows that parent.
        let extra = try await automaticCommitStatuses(at: directory, targets: Array(ancestors.union(targets)))
        before.merge(extra) { _, latest in latest }
        var inferredParents: [String: [String]] = [:]
        for path in targets where before[path] == nil {
            let parents = automaticCommitAncestors(path)
            if let firstNew = parents.firstIndex(where: { before[$0]?.item == "unversioned" }),
               (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(path).path)) != nil {
                // SVN status stops at an unversioned directory. Add only its
                // necessary empty parents first, then let SVN classify the leaf
                // against native config and inherited properties before Add.
                before[path] = WorkingCopyChange(path: path, item: "unversioned", properties: "none", treeConflicted: false)
                inferredParents[path] = Array(parents[firstNew...])
            }
        }
        var blockedAncestors: [String: WorkingCopyChange] = [:]
        for path in targets {
            if let parent = automaticCommitAncestors(path).first(where: { parent in
                guard let value = before[parent] else { return false }
                return value.treeConflicted || value.properties == "conflicted" ||
                    ["ignored", "missing", "deleted", "external", "obstructed", "incomplete"].contains(value.item)
            }) { blockedAncestors[path] = before[parent] }
        }
        let invalid = targets.filter { before[$0]?.canSubmitWithAutomaticAdd != true || blockedAncestors[$0] != nil }
        if !invalid.isEmpty {
            throw SVNCommitSelectionFailure(issue: .invalidFiles, paths: invalid, reasons: invalid.prefix(30).map { path in
                let reason: String
                if let parent = blockedAncestors[path] {
                    reason = "上级目录 \(parent.path)：\(parent.commitBlockReason ?? parent.label)"
                } else { reason = before[path]?.commitBlockReason ?? "项目不可添加，请刷新并检查忽略规则及 SVN 状态。" }
                return safeCommitDiagnostic("\(path)：\(reason)", password: credentials.password)
            })
        }
        let newPaths = Set(targets.filter { before[$0]?.item == "unversioned" })
        let roots = newPaths.filter { path in !automaticCommitAncestors(path).contains(where: newPaths.contains) }.sorted()
        var prepared = Set(targets)
        for parent in ancestors where ["added", "unversioned"].contains(before[parent]?.item ?? "") {
            prepared.insert(parent)
        }
        let parentAdditions = Set(roots.flatMap { inferredParents[$0] ?? [] })
        prepared.formUnion(parentAdditions)
        try automaticCommitSizeCheck(prepared.sorted())
        let tracker = SVNOperationTracker(kind: .commit, directory: directory, targets: [],
                                           password: credentials.password, onProgress: onProgress)
        var additionCompleted = roots.isEmpty
        do {
            if !roots.isEmpty {
                try Task.checkCancellation()
                onProgress(.preparing("正在自动 Add \(roots.count) 个未跟踪项目；新目录遵守 SVN 忽略规则，完成后统一提交。"))
                do {
                    let levels = Dictionary(grouping: parentAdditions, by: { $0.split(separator: "/").count })
                    for level in levels.keys.sorted() {
                        let parents = levels[level]!.sorted()
                        let states = try await automaticCommitStatuses(at: directory, targets: parents)
                        let blocked = parents.filter { states[$0]?.item != "unversioned" }
                        guard blocked.isEmpty else {
                            throw SVNError.invalid("必要父目录的状态已变化或被忽略，已停止自动 Add：\n" + blocked.joined(separator: "\n"))
                        }
                        try Task.checkCancellation()
                        _ = try await execute("add", ["--depth", "empty", "--"] + paths(parents, at: directory),
                                              at: directory, onStdout: { tracker.append($0) }, captureStdout: false)
                    }
                    let states = try await automaticCommitStatuses(at: directory, targets: roots)
                    let blocked = roots.filter { states[$0]?.item != "unversioned" }
                    guard blocked.isEmpty else {
                        throw SVNError.invalid("所选项目的状态已变化或被忽略，已停止自动 Add：\n" + blocked.joined(separator: "\n"))
                    }
                    try Task.checkCancellation()
                    _ = try await execute("add", ["--parents", "--depth", "infinity", "--"] + paths(roots, at: directory),
                                          at: directory, onStdout: { tracker.append($0) }, captureStdout: false)
                } catch {
                    tracker.finish()
                    throw SVNError.invalid("自动 Add 未完整确认，部分项目可能已添加。本次尚未提交，请刷新核对；文件和草稿保留。\n\(error.localizedDescription)")
                }
                tracker.finish()
                let after = try await automaticCommitStatuses(at: directory)
                for change in after.values where change.item == "added" && before[change.path]?.item != "added" {
                    if automaticCommitAncestors(change.path).contains(where: newPaths.contains) || newPaths.contains(change.path) {
                        prepared.insert(change.path)
                    }
                }
                additionCompleted = true
                onProgress(.preparing("自动 Add 已完成，正在核对 \(prepared.count) 项并提交。"))
            }
            let commitPaths = prepared.sorted()
            try automaticCommitSizeCheck(commitPaths)
            try Task.checkCancellation()
            return try await commitValidatedWithProgress(at: directory, paths: commitPaths, message: message,
                firstRecordID: tracker.nextRecordID, onProgress: onProgress)
        } catch {
            tracker.finish()
            throw SVNAutomaticCommitFailure(underlying: error, paths: prepared.sorted(), additionCompleted: additionCompleted)
        }
    }

    private func automaticCommitStatuses(at directory: URL, targets: [String]? = nil) async throws -> [String: WorkingCopyChange] {
        var batches: [[String]] = []
        if let targets {
            var batch: [String] = [], size = 0
            for path in targets.sorted() {
                if !batch.isEmpty && (batch.count >= 128 || size + path.utf8.count > 24_000) {
                    batches.append(batch); batch = []; size = 0
                }
                batch.append(path); size += path.utf8.count + 2
            }
            if !batch.isEmpty { batches.append(batch) }
        } else { batches = [["."]] }
        var result: [String: WorkingCopyChange] = [:]
        for batch in batches {
            try Task.checkCancellation()
            let depth = targets == nil ? [String]() : ["--depth", "empty"]
            let output = try await boundedRead("status", ["--xml", "--no-ignore", "--ignore-externals"] + depth + ["--"] + paths(batch, at: directory),
                at: directory, authenticated: false, limit: 16 * 1_024 * 1_024,
                message: "提交范围的状态清单过大，请分批选择文件或子目录。")
            for change in try SVNXML.parseStatus(output) { result[change.path] = change }
        }
        return result
    }
}

private func automaticCommitAncestors(_ path: String) -> [String] {
    let components = path.split(separator: "/")
    guard components.count > 1 else { return [] }
    return (1..<components.count).map { components.prefix($0).joined(separator: "/") }
}

private func automaticCommitSizeCheck(_ targets: [String]) throws {
    guard !targets.isEmpty, targets.count <= 20_000,
          targets.reduce(0, { $0 + $1.utf8.count + 2 }) <= 96_000 else {
        throw SVNError.invalid("自动提交清单过大，请分批选择文件或子目录；已发生的 Add 会保留，请刷新核对。")
    }
}
