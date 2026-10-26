import Foundation

public struct SVNHistoryPath: Identifiable, Sendable, Equatable {
    public var id: String { path }
    public let path: String
    public let action: String
    public let kind: String
    public let copyFromPath: String?
    public let copyFromRevision: Int64?
}

public struct SVNHistoryEntry: Identifiable, Sendable, Equatable {
    public var id: Int64 { revision }
    public let revision: Int64
    public let author: String
    public let date: String
    public let message: String
    public let paths: [SVNHistoryPath]
}

public struct SVNHistoryPage: Sendable {
    public let entries: [SVNHistoryEntry]
    public let hasMore: Bool
    public let nextBeforeRevision: Int64?
    public let snapshotRevision: Int64
}

extension SVNClient {
    /// Resolve the selected local node before choosing credentials. Switched
    /// children can map to another repository path than parentURL + relativePath.
    public func workingHistoryURL(at requestedDirectory: URL, path: String = ".") async throws -> String {
        guard requestedDirectory.isFileURL, requestedDirectory.query == nil, requestedDirectory.fragment == nil else {
            throw SVNError.invalid("请选择有效的本地 SVN 工作范围。")
        }
        let directory = requestedDirectory.standardizedFileURL
        guard directory.path == directory.resolvingSymlinksInPath().path else { throw SVNError.invalid("不支持通过符号链接目录读取历史。") }
        if path != "." {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0 != ".svn" }) else {
                throw SVNError.invalid("请选择工作范围内有效的版本化路径。")
            }
            let parent = directory.appendingPathComponent(path).deletingLastPathComponent().standardizedFileURL
            guard parent.path == parent.resolvingSymlinksInPath().path else { throw SVNError.invalid("所选路径经过符号链接父目录，无法确认历史范围。") }
        }
        let targets = try paths([path], at: directory)
        let base = try await info(at: directory)
        let data = try await boundedRead("info", ["--xml", "--depth", "empty", "--"] + targets,
            at: directory, authenticated: false, limit: 256 * 1_024, message: "所选节点信息过大，无法确认历史范围。")
        let node = try SVNXML.parseInfo(data)
        let baseRoot = URL(fileURLWithPath: base.rootPath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let nodeRoot = URL(fileURLWithPath: node.rootPath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        guard baseRoot == nodeRoot, base.repositoryRootURL == node.repositoryRootURL else {
            throw SVNError.invalid("所选节点属于另一个工作副本或仓库，请直接打开对应工作范围。")
        }
        let statusData = try await boundedRead("status", ["--xml", "--verbose", "--ignore-externals", "--no-ignore", "--depth", "empty", "--"] + targets,
            at: directory, authenticated: false, limit: 256 * 1_024, message: "所选节点状态过大，无法确认历史范围。")
        let statuses = try SVNXML.parseStatus(statusData)
        guard statuses.allSatisfy({ ["normal", "none", "modified", "replaced", "conflicted", "deleted", "missing"].contains($0.item) }) else {
            throw SVNError.invalid("该路径尚无已提交的版本历史，请选择已经纳入版本控制的路径。")
        }
        try Task.checkCancellation()
        return try SVNLocation.validated(node.url).absoluteString
    }

    /// Every page follows the same node at a numeric peg revision. A subsequent
    /// commit cannot shift the cursor or cause duplicated/missing log entries.
    public func history(url: String, beforeRevision: Int64? = nil, snapshotRevision: Int64? = nil,
                        limit: Int = 100) async throws -> SVNHistoryPage {
        let location = try SVNLocation.validated(url).absoluteString
        guard (1...100).contains(limit), beforeRevision.map({ $0 >= 0 }) ?? true,
              snapshotRevision.map({ $0 >= 0 }) ?? true else { throw SVNError.invalid("历史分页参数无效。") }
        let snapshot: Int64
        if let value = snapshotRevision { snapshot = value }
        else {
            let data = try await boundedRead("info", ["--show-item", "revision", "--revision", "HEAD", "--", location + "@HEAD"],
                limit: 256, message: "无法确认历史快照版本。")
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = Int64(text), value >= 0, !text.isEmpty,
                  text.utf8.allSatisfy({ (48...57).contains($0) }) else { throw SVNError.invalid("无法确认历史快照版本。") }
            snapshot = value
        }
        let upper = min(beforeRevision ?? snapshot, snapshot)
        guard upper > 0 else { return SVNHistoryPage(entries: [], hasMore: false, nextBeforeRevision: nil, snapshotRevision: snapshot) }
        let data = try await boundedRead("log", ["--xml", "--verbose", "--limit", String(limit + 1),
            "--revision", "\(upper):1", "--", location + "@\(snapshot)"],
            limit: 16 * 1_024 * 1_024, message: "本页历史超过 16 MiB，请缩小目录或读取更少版本。")
        let parsed = try SVNHistoryXML.parse(data, limit: limit + 1)
        guard parsed.allSatisfy({ $0.revision <= upper }),
              zip(parsed, parsed.dropFirst()).allSatisfy({ $0.0.revision > $0.1.revision }) else {
            throw SVNError.invalid("历史版本顺序无效，未应用分页结果。")
        }
        let entries = Array(parsed.prefix(limit))
        let hasMore = parsed.count > limit
        return SVNHistoryPage(entries: entries, hasMore: hasMore,
            nextBeforeRevision: hasMore ? entries.last.map { $0.revision - 1 } : nil, snapshotRevision: snapshot)
    }

    /// Drain process output while retaining only the documented maximum. Crossing
    /// the boundary cancels the read, rather than showing a misleading partial list.
    func boundedRead(_ command: String, _ arguments: [String], at directory: URL? = nil,
                     authenticated: Bool = true, limit: Int, message: String) async throws -> Data {
        let buffer = SVNBoundedReadBuffer(limit: limit)
        let worker = Task {
            try await execute(command, arguments, at: directory, authenticated: authenticated,
                onStdout: { buffer.append($0) }, captureStdout: false)
        }
        buffer.setCancellation { worker.cancel() }
        defer { buffer.clearCancellation() }
        do { _ = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() } }
        catch {
            if Task.isCancelled { throw CancellationError() }
            if buffer.exceeded { throw SVNError.invalid(message) }
            throw error
        }
        try Task.checkCancellation()
        guard !buffer.exceeded else { throw SVNError.invalid(message) }
        return buffer.bytes
    }
}

enum SVNHistoryXML {
    static func parse(_ data: Data, limit: Int) throws -> [SVNHistoryEntry] {
        try Task.checkCancellation()
        let reader = HistoryParser(limit: limit)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        let success = parser.parse()
        try Task.checkCancellation()
        if let error = reader.failure { throw error }
        guard success, reader.root == "log", reader.stack.isEmpty else { throw SVNError.invalid("SVN 历史 XML 无法解析。") }
        return reader.entries
    }
}

private final class HistoryParser: NSObject, XMLParserDelegate {
    let limit: Int
    var entries: [SVNHistoryEntry] = []
    var root: String?
    var stack: [String] = []
    var failure: SVNError?
    private var attributes: [String: String] = [:]
    private var revision: Int64 = 0
    private var author = "", date = "", message = "", path = ""
    private var paths: [SVNHistoryPath] = []
    private var pathCount = 0
    init(limit: Int) { self.limit = limit }
    private func fail(_ parser: XMLParser, _ message: String) {
        failure = .invalid(message); parser.abortParsing()
    }
    private func checkpoint(_ parser: XMLParser) -> Bool {
        if Task.isCancelled { parser.abortParsing(); return false }
        return failure == nil
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes values: [String: String]) {
        guard checkpoint(parser) else { return }
        if root == nil { root = name }
        stack.append(name)
        if stack.count > 8 { fail(parser, "历史 XML 层级异常。"); return }
        if stack == ["log", "logentry"] {
            guard entries.count < limit, let value = Int64(values["revision"] ?? ""), value > 0 else { fail(parser, "历史版本或条数无效。"); return }
            revision = value; author = ""; date = ""; message = ""; paths = []
        } else if stack == ["log", "logentry", "paths", "path"] {
            pathCount += 1
            guard pathCount <= 50_000 else { fail(parser, "本页涉及路径超过 50,000 项，请缩小历史范围。"); return }
            attributes = values; path = ""
        }
    }
    func parser(_ parser: XMLParser, foundCharacters text: String) {
        guard checkpoint(parser) else { return }
        switch stack {
        case ["log", "logentry", "author"]: author += text
        case ["log", "logentry", "date"]: date += text
        case ["log", "logentry", "msg"]: message += text
        case ["log", "logentry", "paths", "path"]: path += text
        default: break
        }
        if author.utf8.count > 4_096 || date.utf8.count > 128 || message.utf8.count > 256 * 1_024 || path.utf8.count > 32_768 {
            fail(parser, "历史字段过大，未显示不完整内容。")
        }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard checkpoint(parser) else { return }
        if stack == ["log", "logentry", "paths", "path"] {
            guard validRepositoryPath(path), let action = attributes["action"], ["A", "D", "M", "R"].contains(action) else { fail(parser, "历史路径或动作无效。"); return }
            let copy = attributes["copyfrom-path"]
            let copyRevision = attributes["copyfrom-rev"].flatMap(Int64.init)
            guard copy.map(validRepositoryPath) ?? true,
                  (copy == nil && attributes["copyfrom-rev"] == nil) || (copy != nil && copyRevision.map { $0 >= 0 } == true) else { fail(parser, "历史复制来源无效。"); return }
            let kind = attributes["kind"] ?? "unknown"
            guard ["file", "dir", "unknown", ""].contains(kind) else { fail(parser, "历史节点类型无效。"); return }
            paths.append(SVNHistoryPath(path: path, action: action, kind: kind, copyFromPath: copy, copyFromRevision: copyRevision))
        } else if stack == ["log", "logentry"] {
            entries.append(SVNHistoryEntry(revision: revision, author: author, date: date, message: message, paths: paths))
        }
        if !stack.isEmpty { stack.removeLast() }
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { fail(parser, "历史 XML 不允许实体声明。") }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { fail(parser, "历史 XML 不允许外部实体。") }
}

func validRepositoryPath(_ path: String) -> Bool {
    guard path.hasPrefix("/"), !path.contains("\0") else { return false }
    return !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." || $0 == ".svn" })
}

private final class SVNBoundedReadBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var overflow = false
    private var cancellation: (@Sendable () -> Void)?
    init(limit: Int) { self.limit = limit }
    var exceeded: Bool { lock.lock(); defer { lock.unlock() }; return overflow }
    var bytes: Data { lock.lock(); defer { lock.unlock() }; return data }
    func append(_ chunk: Data) {
        lock.lock()
        let remaining = max(0, limit - data.count)
        data.append(contentsOf: chunk.prefix(remaining))
        if chunk.count > remaining { overflow = true }
        let action = overflow ? cancellation : nil
        lock.unlock(); action?()
    }
    func setCancellation(_ action: @escaping @Sendable () -> Void) {
        lock.lock(); cancellation = action; let invoke = overflow; lock.unlock()
        if invoke { action() }
    }
    func clearCancellation() { lock.lock(); cancellation = nil; lock.unlock() }
}
