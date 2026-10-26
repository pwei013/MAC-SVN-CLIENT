import Foundation

public struct SVNIncomingUpdate: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let localItem: String
    public let localProperties: String
    public let remoteItem: String
    public let remoteProperties: String
    public let revision: Int64?
    public let author: String
    public let date: String
    public let nodeKind: WorkingCopyNodeKind
    public var hasLocalChanges: Bool {
        !["normal", "none", ""].contains(localItem) || !["normal", "none", ""].contains(localProperties)
    }
    public var isDirectory: Bool { nodeKind == .directory }
    public var remoteLabel: String {
        switch remoteItem {
        case "added": return "云端新增"
        case "deleted": return "云端删除"
        case "replaced": return "云端替换"
        case "modified": return "云端修改"
        default: return remoteProperties == "modified" ? "云端属性修改" : remoteItem
        }
    }
}

public struct SVNIncomingUpdateReport: Sendable {
    public let entries: [SVNIncomingUpdate]
    public let revision: Int64
}

extension SVNClient {
    /// Reports repository-side changes relative to each node's working revision.
    /// This does not run update, acquire a write lock, or alter working-copy bytes.
    public func incomingUpdates(at requestedDirectory: URL) async throws -> SVNIncomingUpdateReport {
        guard requestedDirectory.isFileURL else { throw SVNError.invalid("请选择本地 SVN 工作目录。") }
        let directory = requestedDirectory.standardizedFileURL
        guard directory.path == directory.resolvingSymlinksInPath().path else { throw SVNError.invalid("不支持通过符号链接目录检查云端更新。") }
        let before = try await info(at: directory)
        let data = try await boundedRead("status", ["--xml", "--show-updates", "--ignore-externals", "--", ".@"],
            at: directory, limit: 16 * 1_024 * 1_024, message: "云端更新清单超过 16 MiB，请进入更具体的目录后检查。")
        let report = try SVNIncomingXML.parse(data, at: directory)
        let after = try await info(at: directory)
        guard before.url == after.url, before.rootPath == after.rootPath, before.repositoryRootURL == after.repositoryRootURL else {
            throw SVNError.invalid("检查期间工作副本地址发生变化，请重新检查。")
        }
        return report
    }
}

enum SVNIncomingXML {
    static func parse(_ data: Data, at directory: URL) throws -> SVNIncomingUpdateReport {
        try Task.checkCancellation()
        let reader = IncomingParser(directory: directory)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        let success = parser.parse()
        try Task.checkCancellation()
        if let failure = reader.failure { throw failure }
        guard success, reader.root == "status", reader.stack.isEmpty,
              let revision = reader.revision, reader.targetCount == 1 else { throw SVNError.invalid("SVN 云端状态 XML 无法解析或缺少检查版本。") }
        return SVNIncomingUpdateReport(entries: reader.entries, revision: revision)
    }
}

private final class IncomingParser: NSObject, XMLParserDelegate {
    let directory: URL
    var root: String?
    var stack: [String] = []
    var failure: SVNError?
    var entries: [SVNIncomingUpdate] = []
    var revision: Int64?
    var targetCount = 0
    private var path = "", localItem = "", localProperties = "", remoteItem = "", remoteProperties = ""
    private var remoteRevision: Int64?
    private var author = "", date = ""
    private var count = 0
    private var seen = Set<String>()
    init(directory: URL) { self.directory = directory }
    private func fail(_ parser: XMLParser, _ message: String) { failure = .invalid(message); parser.abortParsing() }
    private func checkpoint(_ parser: XMLParser) -> Bool {
        if Task.isCancelled { parser.abortParsing(); return false }
        return failure == nil
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes values: [String: String]) {
        guard checkpoint(parser) else { return }
        if root == nil { root = name }
        stack.append(name)
        if stack.count > 10 { fail(parser, "云端状态 XML 层级异常。"); return }
        if stack == ["status", "target"] {
            targetCount += 1
            guard values["path"] == ".", targetCount == 1 else { fail(parser, "云端状态范围异常。"); return }
        } else if stack == ["status", "target", "entry"] {
            count += 1
            guard count <= 100_000, let value = values["path"], validPath(value), !seen.contains(value) else { fail(parser, "云端状态路径无效、重复或范围过大。"); return }
            path = value; seen.insert(value)
            localItem = ""; localProperties = ""; remoteItem = ""; remoteProperties = ""; author = ""; date = ""; remoteRevision = nil
        } else if stack == ["status", "target", "entry", "wc-status"] {
            localItem = values["item"] ?? ""; localProperties = values["props"] ?? ""
            if values["tree-conflicted"] == "true" { localItem = "conflicted" }
        } else if stack == ["status", "target", "entry", "repos-status"] {
            remoteItem = values["item"] ?? ""; remoteProperties = values["props"] ?? ""
        } else if stack == ["status", "target", "entry", "repos-status", "commit"] {
            guard let value = values["revision"].flatMap(Int64.init), value >= 0 else { fail(parser, "云端状态提交版本无效。"); return }
            remoteRevision = value
        } else if stack == ["status", "target", "against"] {
            guard revision == nil, let value = values["revision"].flatMap(Int64.init), value >= 0 else { fail(parser, "云端检查版本无效。"); return }
            revision = value
        }
    }
    func parser(_ parser: XMLParser, foundCharacters text: String) {
        guard checkpoint(parser) else { return }
        if stack == ["status", "target", "entry", "repos-status", "commit", "author"] { author += text }
        else if stack == ["status", "target", "entry", "repos-status", "commit", "date"] { date += text }
        if author.utf8.count > 4_096 || date.utf8.count > 128 { fail(parser, "云端状态字段过大。") }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard checkpoint(parser) else { return }
        if stack == ["status", "target", "entry"] {
            let validItems = ["", "normal", "none", "added", "deleted", "replaced", "modified", "missing", "unversioned", "ignored", "external", "incomplete", "obstructed", "conflicted"]
            let validProperties = ["", "normal", "none", "modified", "conflicted"]
            guard validItems.contains(localItem), validProperties.contains(localProperties),
                  ["", "none", "normal", "added", "deleted", "replaced", "modified"].contains(remoteItem), validProperties.contains(remoteProperties) else { fail(parser, "云端状态类型无效。"); return }
            let hasRemote = !["", "none", "normal"].contains(remoteItem) || remoteProperties == "modified"
            if hasRemote {
                guard entries.count < 20_000 else { fail(parser, "云端变更超过 20,000 项，请进入更具体的目录后检查。"); return }
                let full = path == "." ? directory : directory.appendingPathComponent(path)
                let type = (try? FileManager.default.attributesOfItem(atPath: full.path))?[.type] as? FileAttributeType
                let kind: WorkingCopyNodeKind
                switch type {
                case .typeDirectory: kind = .directory
                case .typeRegular: kind = .file
                case .typeSymbolicLink: kind = .symbolicLink
                default: kind = .unknown
                }
                entries.append(SVNIncomingUpdate(path: path, localItem: localItem, localProperties: localProperties,
                    remoteItem: remoteItem, remoteProperties: remoteProperties, revision: remoteRevision,
                    author: author, date: date, nodeKind: kind))
            }
        }
        if !stack.isEmpty { stack.removeLast() }
    }
    private func validPath(_ value: String) -> Bool {
        if value == "." { return true }
        guard !value.isEmpty, value.utf8.count <= 32_768, !value.hasPrefix("/"), !value.contains("\0") else { return false }
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0 != ".svn" }
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { fail(parser, "云端状态 XML 不允许实体声明。") }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { fail(parser, "云端状态 XML 不允许外部实体。") }
}
