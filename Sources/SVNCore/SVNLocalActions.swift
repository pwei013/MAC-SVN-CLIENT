import Foundation

public enum SVNLocalAction: Sendable, Equatable { case undoAdd, delete }

public struct SVNLocalActionItem: Identifiable, Sendable, Equatable {
    public var id: String { path }
    public let path: String
    public let kind: WorkingCopyNodeKind
}

public struct SVNLocalActionPlan: Identifiable, Sendable {
    public let id = UUID()
    public let directory: URL
    public let action: SVNLocalAction
    public let targets: [String]
    public let items: [SVNLocalActionItem]
    public let modifiedCount: Int
    let snapshot: LocalActionSnapshot
}

struct LocalActionNode: Sendable, Equatable {
    var path: String
    let kind: WorkingCopyNodeKind
    let schedule: String
    let revision: String
    let url: String
    let root: String
    let repository: String
    let copyFrom: String
    let movedFrom: String
    let movedTo: String
}

struct LocalActionStatus: Sendable, Equatable {
    var path: String
    let item: String
    let properties: String
    let revision: String
    let unsafe: Bool
}

struct LocalActionSnapshot: Sendable, Equatable {
    let root: String
    let url: String
    let repository: String
    let uuid: String
    let nodes: [LocalActionNode]
    let statuses: [LocalActionStatus]
}

extension SVNClient {
    /// All planning is local and off the main actor. Bound both metadata reads;
    /// never inspect file contents or walk unrelated working-copy directories.
    public func prepareLocalAction(_ action: SVNLocalAction, at requestedDirectory: URL,
                                   paths requested: [String]) async throws -> SVNLocalActionPlan {
        try Task.checkCancellation()
        guard requestedDirectory.isFileURL else { throw SVNError.invalid("请选择本地工作副本。") }
        let directory = requestedDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let targets = try localActionTargets(requested, directory: directory)
        let baseData = try await execute("info", ["--xml", "--", ".@"], at: directory).stdout
        let base = try SVNXML.parseInfo(baseData), identity = try SVNXML.parseRepositoryInfo(baseData)
        let arguments = try paths(targets, at: directory)
        let nodeData = try await boundedRead("info", ["--xml", "--depth", "infinity", "--"] + arguments,
            at: directory, authenticated: false, limit: 8 * 1_024 * 1_024,
            message: "选中目录的版本化项目过多，请分批选择文件或子目录。")
        var nodes = try SVNXML.localActionNodes(nodeData)
        let statusData = try await boundedRead("status", ["--xml", "--verbose", "--no-ignore", "--ignore-externals", "--depth", "infinity", "--"] + arguments,
            at: directory, authenticated: false, limit: 8 * 1_024 * 1_024,
            message: "选中目录的状态清单过大，请分批选择文件或子目录。")
        var statuses = try SVNXML.localActionStatuses(statusData)
        func relative(_ path: String) throws -> String {
            let full = path.hasPrefix("/") ? URL(fileURLWithPath: path).standardizedFileURL : directory.appendingPathComponent(path).standardizedFileURL
            guard full.path.hasPrefix(directory.path + "/") else { throw SVNError.invalid("操作路径超出当前工作目录。") }
            let value = String(full.path.dropFirst(directory.path.count + 1))
            guard targets.contains(where: { value == $0 || value.hasPrefix($0 + "/") }) else {
                throw SVNError.invalid("SVN 返回了所选范围以外的路径，未修改文件。")
            }
            return value
        }
        for index in nodes.indices { nodes[index].path = try relative(nodes[index].path) }
        for index in statuses.indices { statuses[index].path = try relative(statuses[index].path) }
        nodes.sort { $0.path < $1.path }; statuses.sort { $0.path < $1.path }
        guard !nodes.isEmpty, nodes.count <= 20_000,
              Set(nodes.map(\.path)).count == nodes.count,
              targets.allSatisfy({ target in nodes.contains { $0.path == target } && statuses.contains { $0.path == target } }),
              nodes.allSatisfy({ URL(fileURLWithPath: $0.root).resolvingSymlinksInPath().path == URL(fileURLWithPath: base.rootPath).resolvingSymlinksInPath().path && $0.repository == base.repositoryRootURL }),
              statuses.allSatisfy({ !$0.unsafe && !["conflicted", "obstructed", "incomplete", "external"].contains($0.item) && $0.properties != "conflicted" }) else {
            throw SVNError.invalid("所选项目存在冲突、外部工作副本、异常状态或清单不完整，请刷新后单独处理。")
        }
        if action == .undoAdd {
            guard nodes.allSatisfy({ $0.schedule == "add" && $0.copyFrom.isEmpty && $0.movedFrom.isEmpty && $0.movedTo.isEmpty }),
                  statuses.allSatisfy({ ["added", "unversioned", "ignored"].contains($0.item) }) else {
                throw SVNError.invalid("撤销 Add 仅支持普通待新增项目；已提交、复制、移动或其他状态的项目不会被还原。")
            }
        } else {
            guard nodes.allSatisfy({ $0.schedule == "normal" && $0.copyFrom.isEmpty && $0.movedFrom.isEmpty && $0.movedTo.isEmpty }),
                  statuses.allSatisfy({ ["normal", "modified", "missing", "unversioned", "ignored"].contains($0.item) }),
                  targets.allSatisfy({ target in statuses.contains { $0.path == target && ["normal", "modified", "missing"].contains($0.item) } }) else {
                throw SVNError.invalid("删除仅支持已版本化项目；目录中存在待新增、待删除、复制或移动项目时，请先单独处理。")
            }
        }
        try Task.checkCancellation()
        let snapshot = LocalActionSnapshot(root: base.rootPath, url: base.url, repository: base.repositoryRootURL,
            uuid: identity.uuid, nodes: nodes, statuses: statuses)
        return SVNLocalActionPlan(directory: directory, action: action, targets: targets,
            items: nodes.map { SVNLocalActionItem(path: $0.path, kind: $0.kind) },
            modifiedCount: statuses.filter { $0.item == "modified" || $0.properties == "modified" }.count, snapshot: snapshot)
    }

    public func applyLocalAction(_ plan: SVNLocalActionPlan, keepLocal: Bool = true) async throws {
        let current = try await prepareLocalAction(plan.action, at: plan.directory, paths: plan.targets)
        guard current.snapshot == plan.snapshot else {
            throw SVNError.invalid("确认期间项目状态或范围已变化，请重新检查清单；本次未执行操作。")
        }
        if plan.action == .delete, !keepLocal {
            let unsafe = current.snapshot.statuses.filter {
                !["normal", "missing"].contains($0.item) || !["normal", "none"].contains($0.properties)
            }
            guard unsafe.isEmpty else {
                throw SVNError.invalid("以下项目有本地修改、未跟踪或忽略内容，请保留本地文件或先处理这些内容：\n" + unsafe.prefix(12).map(\.path).joined(separator: "\n"))
            }
        }
        try Task.checkCancellation()
        let command = plan.action == .undoAdd ? "revert" : "delete"
        // No --remove-added, --force or URL targets. Only the reviewed local roots.
        let options = plan.action == .undoAdd ? ["--depth", "infinity"] : (keepLocal ? ["--keep-local"] : [])
        _ = try await execute(command, options + ["--"] + paths(plan.targets, at: plan.directory), at: plan.directory)
        let data = try await execute("status", ["--xml", "--no-ignore", "--ignore-externals", "--depth", "empty", "--"] +
            paths(plan.targets, at: plan.directory), at: plan.directory).stdout
        let after = try SVNXML.localActionStatuses(data)
        let expected = plan.action == .undoAdd ? ["unversioned", "ignored"] : ["deleted"]
        guard plan.targets.allSatisfy({ target in after.contains { $0.path == target && expected.contains($0.item) } }) else {
            throw SVNError.invalid("操作已执行，但状态核对未完整通过。请刷新检查，不要直接重复操作。")
        }
    }
}

private func localActionTargets(_ requested: [String], directory: URL) throws -> [String] {
    guard !requested.isEmpty, requested.count <= 128, requested.reduce(0, { $0 + $1.utf8.count + 2 }) <= 32 * 1_024 else {
        throw SVNError.invalid("请一次选择 1 至 128 个项目，路径过长时请分批操作。")
    }
    var result: [String] = []
    for path in Set(requested).sorted() {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0 != ".svn" }) else {
            throw SVNError.invalid("不能操作工作副本根目录、管理目录或无效相对路径。")
        }
        let parent = directory.appendingPathComponent(path).deletingLastPathComponent().standardizedFileURL
        guard parent.path == parent.resolvingSymlinksInPath().path else {
            throw SVNError.invalid("所选路径经过符号链接目录，未修改文件。")
        }
        if !result.contains(where: { path.hasPrefix($0 + "/") }) { result.append(path) }
    }
    return result
}
