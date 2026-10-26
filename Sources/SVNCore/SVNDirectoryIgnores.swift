import Foundation

public struct SVNDirectoryIgnoreSettings: Sendable {
    public let directory: URL
    public let workingCopyRoot: URL
    public let ignore: String?
    public let globalIgnores: String?
    public let inherited: [SVNIgnorePropertyValue]
    fileprivate let snapshot: DirectoryIgnoreSnapshot
}

public struct SVNDirectoryIgnoreSaveResult: Sendable {
    public let settings: SVNDirectoryIgnoreSettings
    public let backupDirectory: URL?
    public let changed: Bool
}

extension SVNClient {
    public func directoryIgnoreSettings(at requestedDirectory: URL) async throws -> SVNDirectoryIgnoreSettings {
        let directory = try normalIgnoreDirectory(requestedDirectory)
        let attributes = try directoryIgnoreAttributes(directory)
        let infoData = try await execute("info", ["--xml", "--", ".@"], at: directory).stdout
        let info = try SVNXML.parseInfo(infoData)
        let kinds = try SVNXML.parseWorkingCopyNodeKinds(infoData)
        guard kinds.count == 1, kinds.values.first == .directory else {
            throw SVNError.invalid("请选择已经纳入 SVN 版本控制的本地目录。")
        }
        let root = URL(fileURLWithPath: info.rootPath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        guard ignoreDirectoryContains(root, directory) else { throw SVNError.invalid("目录不在该 SVN 工作副本范围内。") }
        let statuses = try SVNXML.parseStatus(await execute("status", ["--xml", "--verbose", "--ignore-externals", "--no-ignore", "--depth", "empty", "--", ".@"], at: directory).stdout)
        guard statuses.allSatisfy({
            !$0.treeConflicted && ["none", "normal", "modified"].contains($0.properties) &&
                ["none", "normal", "modified", "added"].contains($0.item)
        }) else { throw SVNError.invalid("目录存在删除、冲突或其他异常状态，请先处理后再编辑忽略属性。") }
        let propertiesData = try await execute("proplist", ["--xml", "--verbose", "--show-inherited-props", "--depth", "empty", "--", ".@"], at: directory).stdout
        // Use the existing whitelist/UTF-8 validation for publicly exposed ignore properties.
        _ = try SVNXML.ignoreProperties(propertiesData)
        let records = try DirectoryPropertyDocument.read(propertiesData)
        var local: [String: Data] = [:]
        var inherited: [SVNIgnorePropertyValue] = []
        for record in records {
            if !record.inherited {
                let source = try normalizeIgnoreSource(record.source, relativeTo: directory, root: root, inherited: false)
                guard source == directory.path, local[record.name] == nil else {
                    throw SVNError.invalid("目录属性来源或内容重复，无法安全读取。")
                }
                local[record.name] = record.value
            } else if record.name == "svn:global-ignores" {
                let source = try normalizeIgnoreSource(record.source, relativeTo: directory, root: root, inherited: true)
                inherited.append(SVNIgnorePropertyValue(source: source, name: record.name,
                    value: try directoryIgnoreText(record.value), inherited: true))
            }
        }
        inherited.sort { ($0.source, $0.name, $0.value) < ($1.source, $1.name, $1.value) }
        let status = statuses.first
        let identity = DirectoryIgnoreIdentity(device: attributes.device, inode: attributes.inode,
            permissions: attributes.permissions, owner: attributes.owner, group: attributes.group,
            root: root.path, url: info.url, repository: info.repositoryRootURL, revision: info.revision,
            item: status?.item ?? "normal")
        let snapshot = DirectoryIgnoreSnapshot(identity: identity, statusProperties: status?.properties ?? "none",
                                               properties: local, inherited: inherited.map(DirectoryInheritedIgnore.init))
        // Confirm no file-system path was swapped while the local SVN reads ran.
        guard try directoryIgnoreAttributes(directory) == attributes else {
            throw SVNError.invalid("目录在读取期间发生变化，请重新读取。")
        }
        return SVNDirectoryIgnoreSettings(directory: directory, workingCopyRoot: root,
            ignore: try local["svn:ignore"].map(directoryIgnoreText),
            globalIgnores: try local["svn:global-ignores"].map(directoryIgnoreText), inherited: inherited, snapshot: snapshot)
    }

    public func saveDirectoryIgnores(using baseline: SVNDirectoryIgnoreSettings, ignore: String, globalIgnores: String,
                                     backupDirectory: URL? = nil) async throws -> SVNDirectoryIgnoreSaveResult {
        let desired: [(String, String?)] = [
            ("svn:ignore", try normalizedDirectoryIgnore(ignore)),
            ("svn:global-ignores", try normalizedDirectoryIgnore(globalIgnores))
        ]
        return try await writeDirectoryIgnoreChanges(using: baseline, desired: desired, backupDirectory: backupDirectory)
    }

    // Context-menu actions append to one property, leaving even an explicitly
    // empty value of the other property untouched.
    func saveDirectoryIgnoreProperty(using baseline: SVNDirectoryIgnoreSettings, name: String, value: String,
                                     backupDirectory: URL?) async throws -> SVNDirectoryIgnoreSaveResult {
        guard ["svn:ignore", "svn:global-ignores"].contains(name) else { throw SVNError.invalid("不支持的目录忽略属性。") }
        return try await writeDirectoryIgnoreChanges(using: baseline,
            desired: [(name, try normalizedDirectoryIgnore(value))], backupDirectory: backupDirectory)
    }

    private func writeDirectoryIgnoreChanges(using baseline: SVNDirectoryIgnoreSettings, desired: [(String, String?)],
                                            backupDirectory: URL?) async throws -> SVNDirectoryIgnoreSaveResult {
        let changes = desired.filter { name, value in baseline.snapshot.properties[name] != value.map { Data($0.utf8) } }
        let current = try await directoryIgnoreSettings(at: baseline.directory)
        guard current.snapshot == baseline.snapshot else {
            throw SVNError.invalid("目录状态、属性或继承来源已变化，请重新读取后再保存；本次未修改属性。")
        }
        guard !changes.isEmpty else {
            return SVNDirectoryIgnoreSaveResult(settings: current, backupDirectory: nil, changed: false)
        }
        try Task.checkCancellation()
        let base = backupDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "SVNManager", isDirectory: true)
            .appendingPathComponent("DirectoryIgnoreBackups", isDirectory: true)
        let folder = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var startedWrite = false
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var manifest: [[String: Any]] = []
            for (index, change) in changes.enumerated() {
                var entry: [String: Any] = ["directory": baseline.directory.path, "workingCopyRoot": baseline.workingCopyRoot.path,
                    "property": change.0, "originalPresent": baseline.snapshot.properties[change.0] != nil]
                if let original = baseline.snapshot.properties[change.0] {
                    let name = "\(index)-original-property.txt"
                    try writeDirectoryIgnoreBackup(original, to: folder.appendingPathComponent(name))
                    entry["originalFile"] = name
                }
                if let value = change.1 {
                    let name = "\(index)-updated-property.txt"
                    try writeDirectoryIgnoreBackup(Data(value.utf8), to: folder.appendingPathComponent(name))
                    entry["updatedFile"] = name
                }
                manifest.append(entry)
            }
            try writeDirectoryIgnoreBackup(try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]),
                                           to: folder.appendingPathComponent("sources.json"))
            var expected = baseline.snapshot
            var result = current
            for (index, change) in changes.enumerated() {
                try Task.checkCancellation()
                let before = try await directoryIgnoreSettings(at: baseline.directory)
                guard before.snapshot == expected else {
                    throw SVNError.invalid("目录状态、属性或继承来源已变化，已停止后续修改。")
                }
                startedWrite = true
                if change.1 != nil {
                    _ = try await execute("propset", [change.0, "--file", folder.appendingPathComponent("\(index)-updated-property.txt").path,
                        "--", baseline.directory.path + "@"])
                } else {
                    _ = try await execute("propdel", [change.0, "--", baseline.directory.path + "@"])
                }
                var predicted = expected.properties
                predicted[change.0] = change.1.map { Data($0.utf8) }
                let after = try await directoryIgnoreSettings(at: baseline.directory)
                guard after.snapshot.identity == expected.identity, after.snapshot.properties == predicted,
                      after.snapshot.inherited == expected.inherited else {
                    throw SVNError.invalid("属性写入后读回或来源核对不一致，已停止后续修改。")
                }
                expected = after.snapshot
                result = after
            }
            return SVNDirectoryIgnoreSaveResult(settings: result, backupDirectory: folder, changed: true)
        } catch {
            let state = startedWrite ? "部分本地目录属性可能已经修改，请先刷新核对；不会自动重试、回滚或提交。" : "尚未写入目录属性，请重新读取后再操作。"
            let reason: String
            if case SVNError.invalid(let detail) = error { reason = detail }
            else if case SVNError.command(let code, _) = error { reason = "SVN 命令失败（\(code)）。" }
            else if error is CancellationError { reason = "操作已取消。" }
            else { reason = "备份、写入或读回未完整确认。" }
            throw SVNError.invalid("目录忽略属性保存未完整确认。\(state)\n备份位置：\(folder.path)\n\(reason)")
        }
    }
}

fileprivate struct DirectoryIgnoreAttributes: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let permissions: UInt16
    let owner: UInt32
    let group: UInt32
}
fileprivate struct DirectoryIgnoreIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let permissions: UInt16
    let owner: UInt32
    let group: UInt32
    let root: String
    let url: String
    let repository: String
    let revision: String
    let item: String
}
fileprivate struct DirectoryInheritedIgnore: Equatable, Sendable {
    let source: String
    let name: String
    let value: String
    init(_ value: SVNIgnorePropertyValue) { source = value.source; name = value.name; self.value = value.value }
}
fileprivate struct DirectoryIgnoreSnapshot: Equatable, Sendable {
    let identity: DirectoryIgnoreIdentity
    let statusProperties: String
    let properties: [String: Data]
    let inherited: [DirectoryInheritedIgnore]
}

private func normalIgnoreDirectory(_ url: URL) throws -> URL {
    guard url.isFileURL, url.query == nil, url.fragment == nil,
          !url.pathComponents.contains(where: { [".svn", ".", ".."].contains($0) }) else {
        throw SVNError.invalid("请选择本地 SVN 工作副本中的正常目录。")
    }
    let directory = URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
    guard directory.path == directory.resolvingSymlinksInPath().path else {
        throw SVNError.invalid("不支持通过符号链接路径编辑目录忽略属性，请选择真实目录。")
    }
    return directory
}
private func directoryIgnoreAttributes(_ directory: URL) throws -> DirectoryIgnoreAttributes {
    let values: [FileAttributeKey: Any]
    do { values = try FileManager.default.attributesOfItem(atPath: directory.path) }
    catch { throw SVNError.invalid("无法读取目录状态，请确认目录存在且有访问权限。") }
    guard values[.type] as? FileAttributeType == .typeDirectory,
          let device = values[.systemNumber] as? NSNumber, let inode = values[.systemFileNumber] as? NSNumber,
          let mode = values[.posixPermissions] as? NSNumber, let owner = values[.ownerAccountID] as? NSNumber,
          let group = values[.groupOwnerAccountID] as? NSNumber else {
        throw SVNError.invalid("目标不是可安全编辑的普通本地目录。")
    }
    return DirectoryIgnoreAttributes(device: device.uint64Value, inode: inode.uint64Value, permissions: mode.uint16Value,
                                     owner: owner.uint32Value, group: group.uint32Value)
}
private func ignoreDirectoryContains(_ parent: URL, _ child: URL) -> Bool {
    parent.path == child.path || child.path.hasPrefix(parent.path + "/")
}
private func normalizeIgnoreSource(_ text: String, relativeTo directory: URL, root: URL, inherited: Bool) throws -> String {
    if !text.hasPrefix("/"), let scheme = URL(string: text)?.scheme,
       ["http", "https", "svn", "svn+ssh", "file"].contains(scheme.lowercased()) {
        guard inherited else { throw SVNError.invalid("本地目录属性来源异常，已停止读取。") }
        _ = try SVNLocation.validated(text)
        return text
    }
    let source = (text.hasPrefix("/") ? URL(fileURLWithPath: text, isDirectory: true) :
        directory.appendingPathComponent(text, isDirectory: true)).standardizedFileURL.resolvingSymlinksInPath()
    guard ignoreDirectoryContains(root, source),
          inherited ? (source.path != directory.path && ignoreDirectoryContains(source, directory)) : source.path == directory.path else {
        throw SVNError.invalid("忽略属性来源超出当前工作副本或不是该目录的祖先。")
    }
    return source.path
}
private func directoryIgnoreText(_ data: Data) throws -> String {
    guard String(data: data, encoding: .utf8) != nil else { throw SVNError.invalid("目录忽略属性不是有效 UTF-8。") }
    let text = String(decoding: data, as: UTF8.self)
    guard !text.contains("\0") else { throw SVNError.invalid("目录忽略属性包含无效字符。") }
    return text
}
private func normalizedDirectoryIgnore(_ text: String) throws -> String? {
    guard text.utf8.count <= 1_024 * 1_024,
          !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" }) else {
        throw SVNError.invalid("目录忽略规则过大或包含不允许的控制字符。")
    }
    var value = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    guard value.contains(where: { $0 != "\n" }) else { return nil }
    if !value.hasSuffix("\n") { value += "\n" }
    return value
}
private func writeDirectoryIgnoreBackup(_ data: Data, to file: URL) throws {
    try writeSVNIgnoreFileExclusive(data, to: file, permissions: 0o600, ownership: nil)
    guard try Data(contentsOf: file) == data,
          (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
        throw SVNError.invalid("目录属性备份或更新文件校验失败，尚未写入该属性。")
    }
}

private struct DirectoryPropertyRecord {
    let source: String
    let name: String
    let value: Data
    let inherited: Bool
}
private final class DirectoryPropertyDocument: NSObject, XMLParserDelegate {
    private var stack: [String] = []
    private var source: String?
    private var property: (name: String, inherited: Bool, encoding: String?, text: String)?
    private var records: [DirectoryPropertyRecord] = []
    private var valid = true
    private var root: String?

    static func read(_ data: Data) throws -> [DirectoryPropertyRecord] {
        guard data.count <= 4 * 1_024 * 1_024 else { throw SVNError.invalid("目录属性数据过大，无法安全读取。") }
        let reader = DirectoryPropertyDocument()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), reader.valid, reader.root == "properties" else {
            throw SVNError.invalid("目录属性 XML 无法安全解析。")
        }
        return reader.records
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if root == nil { root = elementName }
        stack.append(elementName)
        if stack == ["properties", "target"] { source = attributes["path"] }
        if stack.count == 3, stack[0] == "properties", stack[1] == "target", ["property", "inherited_property"].contains(elementName) {
            guard let name = attributes["name"], source != nil else { valid = false; return }
            property = (name, elementName == "inherited_property", attributes["encoding"], "")
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if property != nil { property!.text += string }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if stack.count == 3, ["property", "inherited_property"].contains(elementName), let property, let source {
            let data: Data?
            if property.encoding == "base64" { data = Data(base64Encoded: property.text, options: .ignoreUnknownCharacters) }
            else if property.encoding == nil { data = Data(property.text.utf8) }
            else { data = nil }
            if let data { records.append(DirectoryPropertyRecord(source: source, name: property.name, value: data, inherited: property.inherited)) }
            else { valid = false }
            self.property = nil
        }
        if elementName == "target" { source = nil }
        if !stack.isEmpty { stack.removeLast() }
    }
}
