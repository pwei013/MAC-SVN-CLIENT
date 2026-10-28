import Foundation

/// Read-only expansion of the exact scope shown before automatic Add. No
/// working-copy metadata, configuration or remote repository is changed.
public struct SVNCommitReview: Sendable {
    public let directory: URL
    public let selectedPaths: [String]
    public let entries: [WorkingCopyChange]
    public let fileCount: Int
    public let directoryCount: Int
    fileprivate let stamps: [String: CommitReviewStamp]

    func matches(_ other: SVNCommitReview) -> Bool {
        directory == other.directory && selectedPaths == other.selectedPaths && stamps == other.stamps
    }
}

private struct CommitReviewStamp: Equatable, Sendable {
    let item: String
    let properties: String
    let kind: WorkingCopyNodeKind
    let inode: UInt64
    let size: UInt64
    let modified: Date?
}

extension SVNClient {
    public func prepareCommitReview(at requestedDirectory: URL, paths requested: [String]) async throws -> SVNCommitReview {
        let directory = requestedDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let selected = Array(Set(requested)).sorted()
        _ = try paths(selected, at: directory)
        try automaticCommitSizeCheck(selected)
        var statuses = try await automaticCommitStatuses(at: directory)
        let ancestors = Set(selected.flatMap(automaticCommitAncestors))
        statuses.merge(try await automaticCommitStatuses(at: directory, targets: Array(ancestors.union(selected)))) { _, new in new }
        let configured: [String]
        if globalIgnoreConfigurationFiles == [] { configured = SVNGlobalIgnores.defaultPatterns }
        else { configured = try SVNIgnoreConfigSettings.load(configurationFiles: globalIgnoreConfigurationFiles).patterns }
        let globals = configured + additionalGlobalIgnores
        var contexts: [String: [String]] = [:]
        var rows: [String: WorkingCopyChange] = [:]
        var stamps: [String: CommitReviewStamp] = [:]
        var visited = 0
        var argumentBytes = 0

        func record(_ path: String, status: WorkingCopyChange, attributes: [FileAttributeKey: Any]?) throws {
            let kind: WorkingCopyNodeKind
            switch attributes?[.type] as? FileAttributeType {
            case .typeDirectory: kind = .directory
            case .typeRegular: kind = .file
            case .typeSymbolicLink: kind = .symbolicLink
            default: kind = status.nodeKind
            }
            guard kind != .unknown else { throw SVNError.invalid("无法识别提交项目的文件类型，请刷新后重试：\(path)") }
            if rows[path] == nil { argumentBytes += path.utf8.count + 2 }
            guard rows.count < 20_000, argumentBytes <= 96_000 else {
                throw SVNError.invalid("实际提交清单过大，请分批选择文件或子目录；本次尚未 Add 或提交。")
            }
            rows[path] = WorkingCopyChange(path: path, item: status.item, properties: status.properties,
                                          treeConflicted: status.treeConflicted, nodeKind: kind)
            stamps[path] = CommitReviewStamp(item: status.item, properties: status.properties, kind: kind,
                inode: (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                size: kind == .directory ? 0 : (attributes?[.size] as? NSNumber)?.uint64Value ?? 0,
                modified: kind == .directory ? nil : attributes?[.modificationDate] as? Date)
        }
        func newStatus(_ path: String) -> WorkingCopyChange {
            WorkingCopyChange(path: path, item: "unversioned", properties: "none", treeConflicted: false)
        }
        func attributes(_ path: String) throws -> [FileAttributeKey: Any] {
            let target = directory.appendingPathComponent(path)
            guard target.deletingLastPathComponent().standardizedFileURL == target.deletingLastPathComponent().resolvingSymlinksInPath() else {
                throw SVNError.invalid("提交路径经过符号链接目录，请选择真实路径：\(path)")
            }
            do { return try FileManager.default.attributesOfItem(atPath: target.path) }
            catch { throw SVNError.invalid("无法读取提交项目，请检查访问权限或重新读取清单：\(path)") }
        }
        func walk(_ path: String, patterns: [String], depth: Int) throws {
            try Task.checkCancellation()
            visited += 1
            guard visited <= 50_000, depth <= 256 else {
                throw SVNError.invalid("待提交目录过大或层级过深，请分批选择后检查；本次尚未 Add 或提交。")
            }
            let name = (path as NSString).lastPathComponent
            if name == ".svn" { throw SVNError.invalid("待添加目录包含另一个 SVN 工作副本，请分开选择：\(path)") }
            if try !SVNIgnorePatternMatcher.matching(name: name, patterns: patterns).isEmpty { return }
            let values = try attributes(path)
            try record(path, status: newStatus(path), attributes: values)
            if values[.type] as? FileAttributeType == .typeDirectory {
                let folder = directory.appendingPathComponent(path)
                if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".svn").path) {
                    throw SVNError.invalid("待添加目录包含另一个 SVN 工作副本，请分开选择：\(path)")
                }
                let children: [URL]
                do { children = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) }
                catch { throw SVNError.invalid("无法完整读取目录，已停止生成清单：\(path)") }
                for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    try walk(path + "/" + child.lastPathComponent, patterns: patterns, depth: depth + 1)
                }
            }
        }

        // Deleted/missing entries need the versioned kind, not a filesystem guess.
        let absent = selected.filter { ["deleted", "missing"].contains(statuses[$0]?.item ?? "") }
        if !absent.isEmpty {
            let data = try await boundedRead("info", ["--xml", "--depth", "empty", "--"] + paths(absent, at: directory),
                at: directory, authenticated: false, limit: 4 * 1_024 * 1_024, message: "提交项目元数据过大，请分批检查。")
            let kinds = try SVNXML.parseWorkingCopyNodeKinds(data)
            for path in absent {
                if let status = statuses[path], let kind = kinds[path] {
                    statuses[path] = WorkingCopyChange(path: path, item: status.item, properties: status.properties,
                                                       treeConflicted: status.treeConflicted, nodeKind: kind)
                }
            }
        }
        for path in selected {
            try Task.checkCancellation()
            if rows[path] != nil { continue }
            let parents = automaticCommitAncestors(path)
            let firstNew = (parents + [path]).first { statuses[$0]?.item == "unversioned" }
            if let blocked = parents.first(where: { ["ignored", "missing", "deleted", "external", "obstructed", "incomplete"].contains(statuses[$0]?.item ?? "") || statuses[$0]?.treeConflicted == true || statuses[$0]?.properties == "conflicted" }) {
                throw SVNError.invalid("上级目录暂不可提交：\(blocked)。请刷新并处理忽略规则或 SVN 状态。")
            }
            if firstNew != nil && (statuses[path]?.item == "unversioned" || statuses[path] == nil) {
                let first = firstNew!
                let parentPath = automaticCommitAncestors(first).last ?? "."
                let patterns: [String]
                if let cached = contexts[parentPath] { patterns = cached }
                else {
                    let data = try await boundedRead("proplist", ["--xml", "--verbose", "--show-inherited-props", "--depth", "empty", "--"] + paths([parentPath], at: directory),
                        at: directory, authenticated: false, limit: 4 * 1_024 * 1_024, message: "目录忽略属性过大，无法完整核对提交清单。")
                    let inherited = try SVNXML.ignoreProperties(data).filter { $0.name == "svn:global-ignores" }
                    patterns = globals + inherited.flatMap { $0.value.components(separatedBy: CharacterSet(charactersIn: "\r\n")).filter { !$0.isEmpty } }
                    contexts[parentPath] = patterns
                }
                // svn:ignore only applies to immediate children. Native status
                // already classifies that first new child; it is not inherited.
                for component in (parents + [path]).drop(while: { $0 != first }) {
                    guard try SVNIgnorePatternMatcher.matching(name: (component as NSString).lastPathComponent, patterns: patterns).isEmpty else {
                        throw SVNError.invalid("所选项目被忽略规则排除，请取消勾选或调整规则：\(component)")
                    }
                }
                for parent in parents where statuses[parent]?.item == "added" || parent == first || parent.hasPrefix(first + "/") {
                    try record(parent, status: statuses[parent] ?? newStatus(parent), attributes: attributes(parent))
                }
                try walk(path, patterns: patterns, depth: 0)
            } else {
                guard let status = statuses[path], status.canSubmitWithAutomaticAdd else {
                    throw SVNError.invalid("\(path)：\(statuses[path]?.commitBlockReason ?? "项目状态已变化，请刷新后重试。")")
                }
                try record(path, status: status, attributes: try? attributes(path))
                for parent in parents where statuses[parent]?.item == "added" {
                    try record(parent, status: statuses[parent]!, attributes: attributes(parent))
                }
            }
        }
        let entries = rows.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let folders = entries.filter { $0.nodeKind == .directory }.count
        return SVNCommitReview(directory: directory, selectedPaths: selected, entries: entries,
                               fileCount: entries.count - folders, directoryCount: folders, stamps: stamps)
    }
}
