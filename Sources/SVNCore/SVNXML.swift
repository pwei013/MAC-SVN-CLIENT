import Foundation

private final class XMLNode {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [XMLNode] = []
    init(_ name: String, _ attributes: [String: String] = [:]) {
        self.name = name
        self.attributes = attributes
    }
    func child(_ name: String) -> XMLNode? { children.first { $0.name == name } }
    func value(_ name: String) -> String { child(name)?.text ?? "" }
    func descendants(_ name: String) -> [XMLNode] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) }
    }
}

private final class XMLTree: NSObject, XMLParserDelegate {
    let root = XMLNode("root")
    var stack: [XMLNode] = []
    override init() { super.init(); stack = [root] }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let node = XMLNode(elementName, attributeDict)
        stack.last?.children.append(node)
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        stack.removeLast()
    }
}

/// Recursive checkout planning needs names only: avoid building metadata objects,
/// parsing dates or sorting a potentially large repository tree.
private final class CheckoutListParser: NSObject, XMLParserDelegate {
    var paths = Set<String>()
    var root: String?
    private var inEntry = false
    private var inName = false
    private var name = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if root == nil { root = elementName }
        if elementName == "entry" { inEntry = true }
        if elementName == "name", inEntry { inName = true; name = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inName { name += string }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "name", inName { paths.insert(name); inName = false }
        if elementName == "entry" { inEntry = false }
    }
}

/// The recursive listing can be very large. Keep only the current name and
/// bounded matching metadata instead of constructing an XML tree or parsing a
/// date for every item in the repository.
private final class RepositorySearchListParser: NSObject, XMLParserDelegate {
    let query: String
    let limit: Int
    let directoriesOnly: Bool
    var entries: [RepositoryEntry] = []
    var totalMatches = 0
    var root: String?
    var cancelled = false
    private var stack: [String] = []
    private var callbacks = 0
    private var name = ""
    private var kind = "file"
    private var revision = ""
    private var author = ""
    private var size = ""
    private var date = ""
    private var matches = false
    private var retainMetadata = false

    init(query: String, limit: Int, directoriesOnly: Bool) {
        self.query = query
        self.limit = max(1, limit)
        self.directoriesOnly = directoriesOnly
    }

    private func checkpoint(_ parser: XMLParser) -> Bool {
        callbacks &+= 1
        if cancelled || (callbacks & 127 == 1 && Task.isCancelled) {
            cancelled = true
            parser.abortParsing()
            return false
        }
        return true
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        guard checkpoint(parser) else { return }
        if stack.isEmpty { root = elementName }
        stack.append(elementName)
        if stack == ["lists", "list", "entry"] {
            name = ""
            kind = attributeDict["kind"] ?? "file"
            revision = ""
            author = ""
            size = ""
            date = ""
            matches = false
            retainMetadata = false
        } else if retainMetadata, stack == ["lists", "list", "entry", "commit"] {
            revision = attributeDict["revision"] ?? ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard checkpoint(parser) else { return }
        if stack == ["lists", "list", "entry", "name"] {
            name += string
        } else if retainMetadata {
            switch stack {
            case ["lists", "list", "entry", "size"]: size += string
            case ["lists", "list", "entry", "commit", "author"]: author += string
            case ["lists", "list", "entry", "commit", "date"]: date += string
            default: break
            }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard checkpoint(parser) else { return }
        if stack == ["lists", "list", "entry", "name"] {
            matches = (!directoriesOnly || kind == "dir") && name.localizedCaseInsensitiveContains(query)
            retainMetadata = matches && entries.count < limit
        } else if stack == ["lists", "list", "entry"], matches {
            totalMatches += 1
            if retainMetadata {
                entries.append(RepositoryEntry(name: name, kind: kind, revision: revision,
                                               author: author, size: Int64(size) ?? 0, date: date))
            }
        }
        stack.removeLast()
    }
}

public enum SVNXML {
    private static func parse(_ data: Data, expected: String) throws -> XMLNode {
        let tree = XMLTree()
        let parser = XMLParser(data: data)
        parser.delegate = tree
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = tree.root.child(expected) else {
            throw SVNError.invalid("SVN 返回的数据无法解析（预期 \(expected) XML）。")
        }
        return root
    }

    public static func parseList(_ data: Data) throws -> [RepositoryEntry] {
        try parse(data, expected: "lists").descendants("entry").map {
            RepositoryEntry(name: $0.value("name"), kind: $0.attributes["kind"] ?? "file",
                            revision: $0.child("commit")?.attributes["revision"] ?? "",
                            author: $0.child("commit")?.value("author") ?? "",
                            size: Int64($0.value("size")) ?? 0,
                            date: $0.child("commit")?.value("date") ?? "")
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public static func searchList(_ data: Data, query: String, limit: Int = 5000,
                                  directoriesOnly: Bool = false) throws -> RepositorySearchResult {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw SVNError.invalid("请输入要搜索的名称或相对路径。") }
        try Task.checkCancellation()
        let reader = RepositorySearchListParser(query: query, limit: limit, directoriesOnly: directoriesOnly)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        let parsed = parser.parse()
        try Task.checkCancellation()
        if reader.cancelled { throw CancellationError() }
        guard parsed, reader.root == "lists" else {
            throw SVNError.invalid("SVN 返回的数据无法解析（预期 lists XML）。")
        }
        return RepositorySearchResult(entries: reader.entries, totalMatches: reader.totalMatches)
    }

    public static func parseInfo(_ data: Data) throws -> WorkingCopyInfo {
        guard let entry = try parse(data, expected: "info").child("entry"),
              let wc = entry.child("wc-info"), !wc.value("wcroot-abspath").isEmpty else {
            throw SVNError.invalid("该目录不是有效的 SVN 工作副本，请选择已签出的目录。")
        }
        return WorkingCopyInfo(url: entry.value("url"), rootPath: wc.value("wcroot-abspath"),
                               revision: entry.attributes["revision"] ?? "",
                               repositoryRootURL: entry.child("repository")?.value("root") ?? "")
    }

    public static func parseRepositoryInfo(_ data: Data) throws -> RepositoryIdentity {
        guard let entry = try parse(data, expected: "info").child("entry"),
              let repository = entry.child("repository") else {
            throw SVNError.invalid("SVN 没有返回有效的仓库根地址与标识。")
        }
        let root = repository.value("root").trimmingCharacters(in: .whitespacesAndNewlines)
        let uuid = repository.value("uuid").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty, !uuid.isEmpty else { throw SVNError.invalid("SVN 没有返回有效的仓库根地址与标识。") }
        return RepositoryIdentity(rootURL: root, uuid: uuid)
    }

    public static func parseCheckoutRevision(_ data: Data) throws -> String {
        guard let entry = try parse(data, expected: "info").child("entry"),
              entry.attributes["kind"] == "dir",
              let revision = entry.attributes["revision"],
              let number = Int64(revision), number >= 0 else {
            throw SVNError.invalid("无法确认签出目录及版本，未开始签出。")
        }
        return revision
    }

    public static func parseCheckoutPaths(_ data: Data) throws -> Set<String> {
        let reader = CheckoutListParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), reader.root == "lists" else {
            throw SVNError.invalid("无法读取签出清单，未开始签出。")
        }
        return reader.paths
    }

    public static func parseStatus(_ data: Data) throws -> [WorkingCopyChange] {
        try parse(data, expected: "status").descendants("entry").compactMap {
            guard let status = $0.child("wc-status") else { return nil }
            let change = WorkingCopyChange(path: $0.attributes["path"] ?? "",
                                           item: status.attributes["item"] ?? "none",
                                           properties: status.attributes["props"] ?? "none",
                                           treeConflicted: status.attributes["tree-conflicted"] == "true")
            if ["normal", "none"].contains(change.item), change.properties != "modified",
               change.properties != "conflicted", !change.treeConflicted { return nil }
            return change
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    public static func parseWorkingCopyNodeKinds(_ data: Data) throws -> [String: WorkingCopyNodeKind] {
        var result: [String: WorkingCopyNodeKind] = [:]
        for entry in try parse(data, expected: "info").descendants("entry") {
            guard let path = entry.attributes["path"] else { continue }
            switch entry.attributes["kind"] {
            case "dir": result[path] = .directory
            case "file": result[path] = .file
            default: continue
            }
        }
        return result
    }

    public static func ignoreProperties(_ data: Data) throws -> [SVNIgnorePropertyValue] {
        try parse(data, expected: "properties").descendants("target").flatMap { target in
            try target.children.compactMap { property -> SVNIgnorePropertyValue? in
                guard ["property", "inherited_property"].contains(property.name),
                      let name = property.attributes["name"], ["svn:ignore", "svn:global-ignores"].contains(name),
                      let source = target.attributes["path"] else { return nil }
                let value: String
                if property.attributes["encoding"] == "base64" {
                    guard let bytes = Data(base64Encoded: property.text, options: .ignoreUnknownCharacters),
                          let text = String(data: bytes, encoding: .utf8) else {
                        throw SVNError.invalid("忽略属性不是有效 UTF-8，无法安全修改。")
                    }
                    value = text
                } else { value = property.text }
                guard !value.contains("\0") else { throw SVNError.invalid("忽略属性包含无效字符，无法安全修改。") }
                return SVNIgnorePropertyValue(source: source, name: name, value: value, inherited: property.name == "inherited_property")
            }
        }
    }
}
