import Foundation
import Darwin

public enum SVNCommitSelectionIssue: Sendable, Equatable { case invalidFiles, missingParents }

public struct SVNCommitSelectionFailure: LocalizedError, Sendable {
    public let issue: SVNCommitSelectionIssue
    public let paths: [String]
    public let reasons: [String]
    public var errorDescription: String? {
        issue == .missingParents ? "新增文件的以下待新增父目录也需要勾选提交：\n" + reasons.joined(separator: "\n") :
            "以下项目不能提交，请刷新并处理对应状态：\n" + reasons.joined(separator: "\n")
    }
}

public enum SVNCommitRecoveryAction: String, Sendable, Identifiable {
    case update, selectParents, undoAdd, excludeSelection, inspectIncoming, inspectHistory, filterConflicts, changeAccount, refresh, editMessage, review, cleanup
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .update: return "更新当前工作目录"
        case .selectParents: return "补充勾选待新增父目录"
        case .undoAdd: return "撤销问题文件的 Add，保留文件"
        case .excludeSelection: return "将问题文件移出本次提交勾选"
        case .inspectIncoming: return "检查云端更新"
        case .inspectHistory: return "查看提交历史，核对服务器版本"
        case .filterConflicts: return "刷新并筛选冲突项目"
        case .changeAccount: return "更换当前仓库账号"
        case .refresh: return "刷新本地状态"
        case .editMessage: return "返回修改提交说明"
        case .review: return "返回检查提交清单"
        case .cleanup: return "清理工作副本锁（Cleanup）"
        }
    }
    public var confirmationTitle: String {
        switch self {
        case .update: return "确认并更新"
        case .selectParents: return "确认补充勾选"
        case .undoAdd: return "确认撤销 Add"
        case .excludeSelection: return "确认取消这些勾选"
        case .inspectIncoming: return "执行只读检查"
        case .inspectHistory: return "读取提交历史"
        case .filterConflicts: return "刷新并显示冲突"
        case .changeAccount: return "打开仓库登录"
        case .refresh: return "刷新状态"
        case .editMessage: return "返回编辑说明"
        case .review: return "返回检查"
        case .cleanup: return "确认执行 Cleanup"
        }
    }
    public var effect: String {
        switch self {
        case .update: return "接收当前工作目录及子目录的云端新增、修改和删除；合并本地修改，冲突保留供处理。完成后请重新检查，不会自动提交。"
        case .selectParents: return "仅补充以下父目录的提交勾选，保留其他勾选和说明；不会 Add 文件或提交代码。"
        case .undoAdd: return "仅取消以下项目的普通新增标记，保留文件内容；适合不需要入库的日志或生成物，不会添加忽略规则或自动提交。"
        case .excludeSelection: return "仅取消以下文件的提交勾选，不改变文件、SVN 状态或其他勾选。"
        case .inspectIncoming: return "只读查看服务器相对本地的变化，不更新或覆盖文件。"
        case .inspectHistory: return "只读查看已提交版本，先核对上一次提交是否已经到达服务器。"
        case .filterConflicts: return "刷新并筛选冲突；不会自动选择本地或云端版本，也不会标记冲突已解决。"
        case .changeAccount: return "打开该仓库的账号输入窗口；验证成功并确认记住后替换保存账号，不重新提交。权限配置仍需仓库管理员处理。"
        case .refresh: return "重新读取本地 SVN 状态，保留仍有效的勾选和提交说明，不更新文件。"
        case .editMessage: return "保留草稿并返回提交说明编辑；请依据服务器钩子要求修改，不自动生成或重提。"
        case .review: return "保留当前文件、勾选和提交说明，返回工作副本检查。"
        case .cleanup: return "清理整个工作副本的操作锁；不移除未跟踪或忽略文件，不清理外部工作副本。其他 SVN 客户端仍在操作时执行 Cleanup 可能损坏工作副本。"
        }
    }
    public var writesWorkingCopy: Bool { [.update, .undoAdd, .cleanup].contains(self) }
}

public struct SVNCommitRecoveryPlan: Identifiable, Sendable {
    public let id = UUID()
    public let directory: URL
    public let reason: String
    public let guidance: String
    public let details: String
    public let actions: [SVNCommitRecoveryAction]
    public let attemptedPaths: [String]
    public let problemPaths: [String]
    public let parentPaths: [String]
    public let conflictPaths: [String]
    public let undoAddPlan: SVNLocalActionPlan?
    public let inspectionWarning: String?
    let identity: CommitRecoveryIdentity?
    public var repositoryURL: String? { identity?.url }
    public func scope(for action: SVNCommitRecoveryAction) -> [String] {
        switch action {
        case .selectParents: return parentPaths
        case .undoAdd: return undoAddPlan?.items.map(\.path) ?? []
        case .excludeSelection: return problemPaths
        case .filterConflicts: return conflictPaths
        case .cleanup: return identity.map { [$0.root] } ?? []
        case .inspectHistory, .changeAccount: return identity.map { [SVNLocation.display(action == .changeAccount ? $0.repository : $0.url)] } ?? []
        default: return [directory.path]
        }
    }
}

struct CommitRecoveryIdentity: Sendable, Equatable {
    let root: String
    let url: String
    let repository: String
    let uuid: String
}

extension SVNClient {
    /// Recommendations use trusted submitted paths and fresh local metadata.
    /// Diagnostics can identify a known path, never introduce a command target.
    public func prepareCommitRecovery(at directory: URL, attemptedPaths: [String], error: Error,
                                      confirmedRevision: String? = nil) async throws -> SVNCommitRecoveryPlan {
        try Task.checkCancellation()
        let selection = error as? SVNCommitSelectionFailure
        let failure = (error as? SVNCommitFailure) ?? SVNCommitFailure.diagnose(error)
        let reason = confirmedRevision.map { "服务器已确认提交 r\($0)，后续检查未完成" } ??
            selection.map { $0.issue == .missingParents ? "新增父目录未勾选" : "部分勾选项当前不能提交" } ?? failure.reason
        let guidance = confirmedRevision != nil ? "不要重复提交。请先核对历史版本，再刷新本地状态。" :
            (selection == nil ? failure.suggestion : "请核对下方具体文件和推荐操作；修复勾选后仍需单独检查并确认提交。")
        let details = safeCommitDiagnostic(error.localizedDescription, password: credentials.password)
        let targets = Array(Set(attemptedPaths)).sorted()
        var identity: CommitRecoveryIdentity?
        var statuses: [WorkingCopyChange] = []
        var warning: String?
        do {
            _ = try paths(targets, at: directory)
            let data = try await execute("info", ["--xml", "--", ".@"], at: directory).stdout
            identity = try recoveryIdentity(data)
            let status = try await boundedRead("status", ["--xml", "--ignore-externals", "--", ".@"], at: directory,
                authenticated: false, limit: 16 * 1_024 * 1_024, message: "本地状态清单过大，请进入更具体的目录后处理。")
            statuses = try SVNXML.parseStatus(status)
        } catch is CancellationError { throw CancellationError() }
        catch { warning = "无法完整核对当前工作副本，暂不提供会修改它的操作。\n" + safeCommitDiagnostic(error.localizedDescription, password: credentials.password); identity = nil }
        let canonicalDirectory = recoveryPhysicalDirectory(directory)
        let reported = targets.filter { path in
            [path, directory.appendingPathComponent(path).path, canonicalDirectory.appendingPathComponent(path).path].contains { value in
                details.contains("'\(value)'") || details.contains("\"\(value)\"")
            }
        }
        let problems = selection?.issue == .invalidFiles ? targets.filter { selection?.paths.contains($0) == true } : reported
        let parents = selection?.issue == .missingParents ? statuses.filter { change in
            change.item == "added" && change.canCommit && selection?.paths.contains(change.path) == true &&
                targets.contains { $0.hasPrefix(change.path + "/") }
        }.map(\.path).sorted() : []
        let conflicts = statuses.filter { $0.treeConflicted || $0.item == "conflicted" || $0.properties == "conflicted" }.map(\.path)
        var undo: SVNLocalActionPlan?
        if confirmedRevision == nil, identity != nil, selection == nil,
           [.outOfDate, .missingPath, .invalidPath].contains(failure.kind) {
            let added = problems.filter { path in statuses.contains { $0.path == path && $0.item == "added" && $0.canCommit } }
            if !added.isEmpty { undo = try? await prepareLocalAction(.undoAdd, at: directory, paths: added) }
        }
        try Task.checkCancellation()
        var actions: [SVNCommitRecoveryAction]
        if identity == nil { actions = [.review] }
        else if confirmedRevision != nil { actions = [.inspectHistory, .refresh, .review] }
        else if let selection {
            if selection.issue == .missingParents { actions = (parents.isEmpty ? [] : [.selectParents]) + [.review] }
            else { actions = [.refresh] + (conflicts.isEmpty ? [] : [.filterConflicts]) + (problems.isEmpty ? [] : [.excludeSelection]) + [.review] }
        } else {
            switch failure.kind {
            case .outOfDate: actions = details.contains("E160013") ? [.inspectIncoming, .update, .review] : [.update, .inspectIncoming, .review]
            case .missingPath, .invalidPath: actions = [.inspectIncoming, .review]
            case .authorization: actions = RepositoryCredentialScope.requiresPassword(identity!.url) ? [.changeAccount, .review] : [.review]
            case .conflict: actions = [.filterConflicts, .review]
            case .hook: actions = [.editMessage, .review]
            case .workingCopy: actions = [.cleanup, .refresh, .review]
            case .locked: actions = [.inspectHistory, .refresh, .review]
            case .localFile: actions = [.refresh, .review]
            case .network, .postCommit, .unknown: actions = [.inspectHistory, .refresh, .review]
            }
            if [.outOfDate, .missingPath, .invalidPath].contains(failure.kind), !problems.isEmpty {
                actions.insert(.excludeSelection, at: max(1, actions.count - 1))
                if undo != nil { actions.insert(.undoAdd, at: actions.count - 1) }
            }
        }
        return SVNCommitRecoveryPlan(directory: directory, reason: reason, guidance: guidance, details: details,
            actions: actions, attemptedPaths: targets, problemPaths: problems, parentPaths: parents, conflictPaths: conflicts,
            undoAddPlan: undo, inspectionWarning: warning, identity: identity)
    }

    public func validateCommitRecovery(_ plan: SVNCommitRecoveryPlan) async throws {
        guard let identity = plan.identity else { throw SVNError.invalid("尚未核对工作副本身份，请关闭建议并重新检查状态。") }
        let data = try await execute("info", ["--xml", "--", ".@"], at: plan.directory).stdout
        guard try recoveryIdentity(data) == identity else {
            throw SVNError.invalid("工作副本地址或仓库身份已变化，未执行推荐操作。请重新检查。")
        }
        try Task.checkCancellation()
    }

    public func recoverySelectionPaths(_ plan: SVNCommitRecoveryPlan, action: SVNCommitRecoveryAction,
                                       currentSelection: Set<String>) async throws -> [String] {
        guard plan.actions.contains(action), [.selectParents, .excludeSelection].contains(action) else {
            throw SVNError.invalid("该建议不支持此勾选操作。")
        }
        try await validateCommitRecovery(plan)
        let changes = try await status(at: plan.directory)
        if action == .excludeSelection { return plan.problemPaths.filter { currentSelection.contains($0) } }
        let parents = plan.parentPaths.filter { parent in !currentSelection.contains(parent) && currentSelection.contains { $0.hasPrefix(parent + "/") } }
        guard parents.allSatisfy({ path in changes.contains { $0.path == path && $0.item == "added" && $0.canCommit } }) else {
            throw SVNError.invalid("待新增父目录状态已变化，请刷新后重新检查；未修改勾选。")
        }
        return parents
    }

    public func cleanupForCommitRecovery(_ plan: SVNCommitRecoveryPlan, confirmedNoOtherClients: Bool) async throws {
        guard plan.actions.contains(.cleanup), confirmedNoOtherClients, let identity = plan.identity else {
            throw SVNError.invalid("请先确认其他 SVN 客户端均已停止操作此工作副本，再执行 Cleanup。")
        }
        try await validateCommitRecovery(plan)
        // The reviewed scope is the whole WC root. Never remove user files,
        // vacuum pristines, include externals, or repeat a failed cleanup.
        _ = try await execute("cleanup", ["--", "."], at: URL(fileURLWithPath: identity.root, isDirectory: true))
        try await validateCommitRecovery(plan)
    }
}

private func recoveryIdentity(_ data: Data) throws -> CommitRecoveryIdentity {
    let info = try SVNXML.parseInfo(data), repository = try SVNXML.parseRepositoryInfo(data)
    return CommitRecoveryIdentity(root: info.rootPath, url: info.url, repository: info.repositoryRootURL, uuid: repository.uuid)
}

// Foundation may retain macOS /var and /tmp aliases even when SVN reports their
// physical /private paths. Resolve our known local directory, never an error path.
private func recoveryPhysicalDirectory(_ directory: URL) -> URL {
    guard let resolved = directory.withUnsafeFileSystemRepresentation({ value in value.flatMap { realpath($0, nil) } }) else {
        return directory.resolvingSymlinksInPath()
    }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
}
