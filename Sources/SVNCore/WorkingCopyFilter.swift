import Foundation

public enum WorkingCopyStatusFilter: String, CaseIterable, Codable, Identifiable, Sendable {
    case all, modified, unversioned, versioned, added, deleted, conflicted, missing, ignored, other
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .all: return "全部"
        case .modified: return "已修改"
        case .unversioned: return "未跟踪"
        case .versioned: return "已版本化"
        case .added: return "待新增"
        case .deleted: return "待删除"
        case .conflicted: return "冲突"
        case .missing: return "缺失"
        case .ignored: return "已忽略"
        case .other: return "其他"
        }
    }

    public static func category(of change: WorkingCopyChange) -> Self {
        if change.treeConflicted || change.item == "conflicted" || change.properties == "conflicted" { return .conflicted }
        switch change.item {
        case "modified": return .modified
        case "unversioned": return .unversioned
        case "added": return .added
        case "deleted": return .deleted
        case "missing": return .missing
        case "ignored": return .ignored
        case "normal", "none": return change.properties == "modified" ? .modified : .other
        default: return .other
        }
    }

    public static func isVersioned(_ change: WorkingCopyChange) -> Bool {
        ["normal", "none", "modified", "added", "deleted", "replaced", "missing", "conflicted", "obstructed", "incomplete"].contains(change.item)
    }
}

public enum WorkingCopyKindFilter: String, CaseIterable, Codable, Identifiable, Sendable {
    case all, files, directories
    public var id: String { rawValue }
    public var title: String {
        switch self { case .all: return "全部类型"; case .files: return "只看文件"; case .directories: return "只看文件夹" }
    }
    public func includes(_ change: WorkingCopyChange) -> Bool {
        switch self {
        case .all: return true
        case .files: return change.nodeKind == .file || change.nodeKind == .symbolicLink
        case .directories: return change.nodeKind == .directory
        }
    }
}

public struct WorkingCopyFilterResult: Sendable {
    public let entries: [WorkingCopyChange]
    public let counts: [WorkingCopyStatusFilter: Int]
    public let visiblePaths: Set<String>
    public let checkablePaths: Set<String>
    public static let empty = WorkingCopyFilterResult(entries: [], counts: [:], visiblePaths: [], checkablePaths: [])

    /// One cancellable in-memory pass. Counts use the path/type scope, so every
    /// shortcut shows how many rows it would display without changing selection.
    public static func evaluate(_ changes: [WorkingCopyChange], query: String,
        status: WorkingCopyStatusFilter, kind: WorkingCopyKindFilter) throws -> WorkingCopyFilterResult {
        try Task.checkCancellation()
        var entries: [WorkingCopyChange] = []
        var counts: [WorkingCopyStatusFilter: Int] = [:]
        var paths = Set<String>()
        var checkablePaths = Set<String>()
        for (index, change) in changes.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard kind.includes(change), query.isEmpty || change.path.localizedCaseInsensitiveContains(query) else { continue }
            let category = WorkingCopyStatusFilter.category(of: change)
            let versioned = WorkingCopyStatusFilter.isVersioned(change)
            counts[.all, default: 0] += 1
            counts[category, default: 0] += 1
            if versioned { counts[.versioned, default: 0] += 1 }
            if status == .all || status == category || (status == .versioned && versioned) {
                entries.append(change); paths.insert(change.path)
                if change.canCheck { checkablePaths.insert(change.path) }
            }
        }
        try Task.checkCancellation()
        return WorkingCopyFilterResult(entries: entries, counts: counts, visiblePaths: paths, checkablePaths: checkablePaths)
    }
}
