import Foundation

public struct SVNCredentials: Sendable {
    public var username: String
    public var password: String
    public init(username: String = "", password: String = "") {
        self.username = username
        self.password = password
    }
}

public struct RepositoryEntry: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public let name: String
    public let kind: String
    public let revision: String
    public let author: String
    public let size: Int64
    public let date: String
    public let lastCommitDate: Date?
    public var isDirectory: Bool { kind == "dir" }
    public var revisionNumber: Int64 { Int64(revision) ?? -1 }
    public var lastCommitTimestamp: Double { lastCommitDate?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude }

    public init(name: String, kind: String, revision: String, author: String, size: Int64, date: String) {
        self.name = name
        self.kind = kind
        self.revision = revision
        self.author = author
        self.size = size
        self.date = date
        lastCommitDate = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(date)) ??
            (try? Date.ISO8601FormatStyle().parse(date))
    }

    public static var defaultSortOrder: [KeyPathComparator<RepositoryEntry>] {
        [KeyPathComparator(\.name, comparator: .localizedStandard)]
    }

    public static func sorted(_ entries: [RepositoryEntry], using order: [KeyPathComparator<RepositoryEntry>]) -> [RepositoryEntry] {
        entries.sorted { left, right in
            if left.isDirectory != right.isDirectory { return left.isDirectory }
            for comparator in order {
                let result = comparator.compare(left, right)
                if result != .orderedSame { return result == .orderedAscending }
            }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }
}

public struct RepositorySearchResult: Sendable, Equatable {
    public let entries: [RepositoryEntry]
    public let totalMatches: Int
    public var isTruncated: Bool { totalMatches > entries.count }

    public init(entries: [RepositoryEntry], totalMatches: Int) {
        self.entries = entries
        self.totalMatches = totalMatches
    }
}

public struct WorkingCopyInfo: Sendable {
    public let url: String
    public let rootPath: String
    public let revision: String
    public let repositoryRootURL: String
}

public struct RepositoryIdentity: Sendable {
    public let rootURL: String
    public let uuid: String
}

public enum WorkingCopyNodeKind: String, Sendable {
    case file, directory, symbolicLink, unknown
}

public struct WorkingCopyChange: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let item: String
    public let properties: String
    public let treeConflicted: Bool
    public let nodeKind: WorkingCopyNodeKind

    public init(path: String, item: String, properties: String, treeConflicted: Bool,
                nodeKind: WorkingCopyNodeKind = .unknown) {
        self.path = path
        self.item = item
        self.properties = properties
        self.treeConflicted = treeConflicted
        self.nodeKind = nodeKind
    }
    public var canCommit: Bool {
        !treeConflicted && properties != "conflicted" &&
        (["modified", "added", "deleted", "replaced"].contains(item) ||
         (["normal", "none"].contains(item) && properties == "modified"))
    }
    public var commitBlockReason: String? {
        guard !canCommit else { return nil }
        if treeConflicted { return "存在树冲突，请先处理冲突。" }
        if properties == "conflicted" { return "存在属性冲突，请先处理冲突。" }
        switch item {
        case "unversioned": return "未跟踪：请先 Add 到版本控制，或取消勾选。"
        case "missing": return "文件缺失：请先恢复文件或标记为待删除，或取消勾选。"
        case "ignored": return "已忽略：请先取消忽略并 Add，或取消勾选。"
        case "conflicted": return "存在内容冲突，请先处理冲突。"
        case "obstructed": return "路径被阻挡，请检查同名文件或目录的类型。"
        case "incomplete": return "工作副本状态不完整，请先更新或修复。"
        case "external": return "外部工作副本，请在对应工作副本中单独提交。"
        default: return "当前没有可提交变更，请刷新状态或取消勾选。"
        }
    }
    public var canCheck: Bool {
        !treeConflicted && properties != "conflicted" &&
        (canCommit || item == "unversioned" || item == "missing")
    }
    public var label: String {
        if treeConflicted || properties == "conflicted" { return "冲突" }
        switch item {
        case "modified": return "已修改"
        case "added": return "待新增"
        case "deleted": return "待删除"
        case "replaced": return "已替换"
        case "unversioned": return "未跟踪"
        case "ignored": return "已忽略"
        case "missing": return "文件缺失"
        case "conflicted": return "冲突"
        case "obstructed": return "路径阻塞"
        case "external": return "外部引用"
        default: return properties == "modified" ? "属性修改" : item
        }
    }
}

public enum SVNError: LocalizedError {
    case invalid(String)
    case command(Int32, String)
    case authentication(Int32, String)
    public var isAuthenticationFailure: Bool {
        if case .authentication = self { return true }
        guard case .command(_, let detail) = self else { return false }
        return ["E170001", "E215004", "E215003"].contains { detail.contains($0) }
    }
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .command(let code, let message): return "SVN 执行失败（\(code)）\n\(message)"
        case .authentication(let code, let message): return "SVN 身份验证失败（\(code)）\n\(message)"
        }
    }
}

public enum SVNLocation {
    private static let inputURLCharacters = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%")
    /// Show Unicode path text without decoding reserved ASCII characters such as
    /// %2F, %23 or %25, which would change the URL when copied back into an input.
    public static func display(_ text: String) -> String {
        let bytes = Array(text.utf8)
        func hex(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 55
            case 97...102: return byte - 87
            default: return nil
            }
        }
        func escapedByte(_ index: Int) -> UInt8? {
            guard index + 2 < bytes.count, bytes[index] == 37,
                  let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) else { return nil }
            return high * 16 + low
        }
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if let first = escapedByte(index) {
                let length = first >= 0xC2 && first <= 0xDF ? 2 :
                    first >= 0xE0 && first <= 0xEF ? 3 : first >= 0xF0 && first <= 0xF4 ? 4 : 0
                if length > 0 {
                    let sequence = (0..<length).compactMap { escapedByte(index + $0 * 3) }
                    if sequence.count == length, let decoded = String(bytes: sequence, encoding: .utf8),
                       !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                        result.append(contentsOf: sequence)
                        index += length * 3
                        continue
                    }
                }
            }
            result.append(bytes[index])
            index += 1
        }
        return String(decoding: result, as: UTF8.self)
    }

    public static func validated(_ text: String) throws -> URL {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Foundation otherwise re-encodes existing % escapes when raw Unicode is
        // also present. Encode the readable characters first, preserving escapes.
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: inputURLCharacters),
              let url = URL(string: encoded), let scheme = url.scheme?.lowercased(),
              ["http", "https", "svn", "svn+ssh", "file"].contains(scheme),
              scheme == "file" || !(url.host ?? "").isEmpty else {
            throw SVNError.invalid("请输入完整仓库地址，支持 https://、http://、svn://、svn+ssh:// 和 file://。")
        }
        guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw SVNError.invalid("仓库地址不能包含账号密码、查询参数或片段，请在登录弹窗中填写账号密码。")
        }
        return url
    }

    public static func child(_ name: String, of parent: String) throws -> String {
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        guard !name.isEmpty, !name.contains("\0"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw SVNError.invalid("无效的仓库相对路径。")
        }
        // Append each literal name separately: a recursive result may contain
        // slashes, but percent escapes, @, # and ? still belong to file names.
        return try components.reduce(validated(parent)) {
            $0.appendingPathComponent(String($1), isDirectory: false)
        }.absoluteString
    }

    public static func parent(of text: String) throws -> String {
        try validated(text).deletingLastPathComponent().absoluteString
    }
}
