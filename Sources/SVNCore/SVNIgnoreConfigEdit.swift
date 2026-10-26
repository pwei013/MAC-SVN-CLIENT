import Foundation
import Darwin

/// Exposes only the effective ignore patterns, while retaining private snapshots
/// so an editor cannot overwrite settings changed after it was opened.
public struct SVNIgnoreConfigSettings: Sendable {
    public let file: URL
    public let patterns: [String]
    public let sourceDescription: String
    private let snapshots: [IgnoreConfigSnapshot]

    public static func load(configurationFiles: [URL]? = nil) throws -> SVNIgnoreConfigSettings {
        let files = configurationFiles ?? standardIgnoreConfigurationFiles()
        guard !files.isEmpty else {
            throw ignoreConfigError("未指定 SVN 用户配置文件，无法读取或保存用户全局过滤。")
        }
        let snapshots = try files.map { try IgnoreConfigSnapshot.read($0) }
        var configuration = ResolvedIgnoreConfiguration()
        for snapshot in snapshots {
            if let data = snapshot.data { try configuration.merge(IgnoreConfigDocument(data), source: snapshot.file) }
        }
        guard let user = snapshots.last else { throw ignoreConfigError("未指定 SVN 用户配置文件。") }
        let patterns = stableIgnorePatterns(try configuration.effectivePatterns())
        let description: String
        if let source = configuration.effectiveSource {
            description = source == user.file ? "当前生效：SVN 用户配置（\(source.path)）" :
                "当前生效：SVN 系统配置（\(source.path)）；保存后写入用户配置覆盖。"
        } else {
            description = "当前生效：SVN 内置默认规则；保存后写入用户配置覆盖。"
        }
        return Self(file: user.file, patterns: patterns, sourceDescription: description, snapshots: snapshots)
    }

    /// Native global-ignores uses ASCII whitespace separators. Existing literal
    /// Unicode whitespace and punctuation remain valid, but new config references
    /// cannot be injected through the rules editor.
    public func prepareSaving(_ text: String) throws -> SVNIgnoreConfigEdit {
        try validateIgnoreConfigSnapshots(snapshots)
        guard text.utf8.count <= 1_024 * 1_024,
              !text.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) && !configWhitespace.contains($0)
              }) else {
            throw ignoreConfigError("全局过滤规则过大或包含不允许的控制字符。")
        }
        let saved = stableIgnorePatterns(text.components(separatedBy: configWhitespace).filter { !$0.isEmpty })
        let existingLiterals = Set(patterns.filter { $0.contains("%(") })
        guard saved.allSatisfy({ !$0.contains("%(") || existingLiterals.contains($0) }) else {
            throw ignoreConfigError("全局过滤不能新增配置插值 %(...)s；若要匹配百分号，请使用 [%]。")
        }
        let kept = Set(saved)
        let removed = patterns.filter { !kept.contains($0) }
        return try SVNIgnoreConfigEdit.make(snapshots: snapshots, remainingPatterns: saved, removedPatterns: removed)
    }
}

/// A reviewable edit of the user's SVN runtime ignores. System configuration is read
/// for precedence, but only the final user configuration is ever written.
public struct SVNIgnoreConfigEdit: Sendable {
    public let file: URL
    public let originalData: Data?
    public let updatedData: Data
    public let removedPatterns: [String]
    public let remainingPatterns: [String]
    public let sourceDescription: String
    private let snapshots: [IgnoreConfigSnapshot]

    public static func prepare(forName name: String, configurationFiles: [URL]? = nil) throws -> SVNIgnoreConfigEdit? {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0") else { throw ignoreConfigError("无效的忽略项目名称。") }
        let files = configurationFiles ?? standardIgnoreConfigurationFiles()
        let snapshots = try files.map { try IgnoreConfigSnapshot.read($0) }
        var configuration = ResolvedIgnoreConfiguration()
        for snapshot in snapshots {
            if let data = snapshot.data { try configuration.merge(IgnoreConfigDocument(data), source: snapshot.file) }
        }
        let effective = try configuration.effectivePatterns()
        let matches = try SVNIgnorePatternMatcher.matching(name: name, patterns: effective)
        var seen = Set<String>()
        let removed = matches.filter { seen.insert($0).inserted }
        guard !removed.isEmpty else { return nil }
        guard !snapshots.isEmpty else {
            throw ignoreConfigError("未指定可写的 SVN 用户配置文件，无法取消默认忽略规则。")
        }
        let removedSet = Set(removed)
        let remaining = effective.filter { !removedSet.contains($0) }
        return try make(snapshots: snapshots, remainingPatterns: remaining, removedPatterns: removed)
    }

    fileprivate static func make(snapshots: [IgnoreConfigSnapshot], remainingPatterns: [String], removedPatterns: [String]) throws -> SVNIgnoreConfigEdit {
        guard let user = snapshots.last else { throw ignoreConfigError("未指定可写的 SVN 用户配置文件。") }
        let document = try IgnoreConfigDocument(user.data ?? Data())
        let updated = try document.replacingGlobalIgnores(with: remainingPatterns)
        var validation = ResolvedIgnoreConfiguration()
        for snapshot in snapshots {
            if let data = snapshot.file == user.file ? updated : snapshot.data {
                try validation.merge(IgnoreConfigDocument(data), source: snapshot.file)
            }
        }
        guard stableIgnorePatterns(try validation.effectivePatterns()) == stableIgnorePatterns(remainingPatterns) else {
            throw ignoreConfigError("这些规则会触发 SVN 配置插值，无法按字面安全保存；若要匹配百分号，请使用 [%]。")
        }
        return SVNIgnoreConfigEdit(file: user.file, originalData: user.data, updatedData: updated,
                                   removedPatterns: removedPatterns, remainingPatterns: remainingPatterns,
                                   sourceDescription: "SVN 用户配置（对当前用户的所有 SVN 工作副本生效）",
                                   snapshots: snapshots)
    }

    /// Includes inherited/system files, so an external config change invalidates the
    /// entire preview rather than applying a stale override.
    public func validateUnchanged() throws {
        try validateIgnoreConfigSnapshots(snapshots)
    }

    /// Writes once after confirmation. A backup is retained on success or failure;
    /// uncertain results are reported without replay or automatic rollback.
    public func apply() throws -> URL? {
        var backup: URL?
        var backupVerified = false
        do { return try applyRecordingBackup(&backup, verified: &backupVerified) }
        catch {
            let message: String
            if case SVNError.invalid(let detail) = error { message = detail }
            else { message = "SVN 用户配置修改未完整确认，请重新读取状态后检查。" }
            if let backup, FileManager.default.fileExists(atPath: backup.path) {
                let label = backupVerified ? "原配置备份" : "备份文件（完整性未确认）"
                throw ignoreConfigError(message + "\n\(label)：\(backup.path)")
            }
            throw ignoreConfigError(message)
        }
    }

    private func applyRecordingBackup(_ backup: inout URL?, verified backupVerified: inout Bool) throws -> URL? {
        try validateUnchanged()
        let manager = FileManager.default
        let parent = file.deletingLastPathComponent()
        if !manager.fileExists(atPath: parent.path) {
            do { try manager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            catch { throw ignoreConfigError("无法创建 SVN 用户配置目录，请检查目录权限。") }
        }
        guard manager.isWritableFile(atPath: parent.path), originalData == nil || manager.isWritableFile(atPath: file.path) else {
            throw ignoreConfigError("没有写入 SVN 用户配置的权限，请检查文件和目录权限。")
        }
        try validateUnchanged()
        let original = try requiredUserSnapshot()
        if let data = originalData {
            let url = parent.appendingPathComponent("config.svnmanager-backup-\(UUID().uuidString)")
            backup = url
            try writeSVNIgnoreFileExclusive(data, to: url, permissions: 0o600, ownership: nil)
            let readback = try IgnoreConfigSnapshot.read(url)
            guard readback.data == data, readback.metadata?.permissions == 0o600 else {
                throw ignoreConfigError("SVN 配置备份校验失败，未修改原配置。")
            }
            backupVerified = true
        }
        let temporary = parent.appendingPathComponent(".svnmanager-config-\(UUID().uuidString).tmp")
        var replaced = false
        defer { if !replaced { try? manager.removeItem(at: temporary) } }
        try writeSVNIgnoreFileExclusive(updatedData, to: temporary, permissions: original.metadata?.permissions ?? 0o600,
                           ownership: original.metadata.map { ($0.owner, $0.group) })
        if originalData != nil {
            // Keep existing macOS ACLs and extended metadata across the atomic rename.
            // This copies no old file contents and never changes the source config.
            guard copyfile(file.path, temporary.path, nil, copyfile_flags_t(COPYFILE_ACL | COPYFILE_XATTR)) == 0 else {
                throw ignoreConfigError("无法保留 SVN 配置的文件权限或扩展属性，未替换原配置。")
            }
        }
        try validateUnchanged()
        guard rename(temporary.path, file.path) == 0 else {
            throw ignoreConfigError("写入 SVN 用户配置失败；如有备份已保留，请检查文件权限后重新读取状态。")
        }
        replaced = true
        let current: IgnoreConfigSnapshot
        do { current = try IgnoreConfigSnapshot.read(file) }
        catch { throw ignoreConfigError("SVN 配置已替换，但读回失败；请检查配置和备份，勿直接重复操作。") }
        guard current.data == updatedData,
              current.metadata?.permissions == (original.metadata?.permissions ?? 0o600),
              original.metadata == nil || (current.metadata?.owner == original.metadata?.owner && current.metadata?.group == original.metadata?.group) else {
            throw ignoreConfigError("SVN 配置已替换，但内容或权限校验未通过；请检查配置和备份，勿直接重复操作。")
        }
        return backup
    }

    private func requiredUserSnapshot() throws -> IgnoreConfigSnapshot {
        guard let snapshot = snapshots.last, snapshot.file == file else { throw ignoreConfigError("SVN 配置修改计划无效，请重新检查。") }
        return snapshot
    }
}

fileprivate struct IgnoreConfigMetadata: Equatable, Sendable {
    let permissions: UInt16
    let owner: UInt32
    let group: UInt32
    let device: UInt64
    let inode: UInt64
    let modificationTime: TimeInterval
}

fileprivate struct IgnoreConfigSnapshot: Sendable {
    let file: URL
    let data: Data?
    let metadata: IgnoreConfigMetadata?

    static func read(_ file: URL) throws -> IgnoreConfigSnapshot {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: file.path) }
        catch let error as NSError where (error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)) ||
                                          (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)) {
            return IgnoreConfigSnapshot(file: file, data: nil, metadata: nil)
        } catch { throw ignoreConfigError("无法读取 SVN 配置文件状态，请检查权限。") }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ignoreConfigError("SVN 配置不是普通文件或为符号链接，已停止修改。")
        }
        guard let size = attributes[.size] as? NSNumber, size.uint64Value <= 4 * 1_024 * 1_024,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              let owner = attributes[.ownerAccountID] as? NSNumber,
              let group = attributes[.groupOwnerAccountID] as? NSNumber,
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let modificationTime = attributes[.modificationDate] as? Date else {
            throw ignoreConfigError("SVN 配置文件过大或元数据无法核对，已停止修改。")
        }
        let data: Data
        do { data = try Data(contentsOf: file) }
        catch { throw ignoreConfigError("无法读取 SVN 配置内容，请检查权限。") }
        return IgnoreConfigSnapshot(file: file, data: data,
                                    metadata: IgnoreConfigMetadata(permissions: permissions.uint16Value, owner: owner.uint32Value,
                                                                   group: group.uint32Value, device: device.uint64Value,
                                                                   inode: inode.uint64Value, modificationTime: modificationTime.timeIntervalSince1970))
    }
}

private struct IgnoreConfigEntry {
    let section: String
    let name: String
    var value: String
    var lines: Range<Int>
}

private struct IgnoreConfigLine {
    var content: String
    var ending: String
    var full: String { content + ending }
}

private struct IgnoreConfigDocument {
    let lines: [IgnoreConfigLine]
    let entries: [IgnoreConfigEntry]
    let sections: [(name: String, line: Int)]

    init(_ data: Data) throws {
        guard String(data: data, encoding: .utf8) != nil else {
            throw ignoreConfigError("现有 SVN 配置不是有效 UTF-8，无法安全修改。")
        }
        // Foundation's encoding initializer consumes a leading UTF-8 BOM. Decode
        // the already validated bytes without consuming it so edits preserve it.
        let text = String(decoding: data, as: UTF8.self)
        guard !text.contains("\0") else { throw invalidConfigSyntax() }
        let components = text.components(separatedBy: "\n")
        var lines = components.enumerated().map { index, part in
            IgnoreConfigLine(content: part.hasSuffix("\r") ? String(part.dropLast()) : part,
                             ending: index < components.count - 1 ? (part.hasSuffix("\r") ? "\r\n" : "\n") : "")
        }
        if text.isEmpty { lines.removeAll() }
        if lines.count > 1, lines.last?.full == "" { lines.removeLast() }
        var entries: [IgnoreConfigEntry] = []
        var sections: [(name: String, line: Int)] = []
        var section: String?
        var pending: IgnoreConfigEntry?
        for (index, line) in lines.enumerated() {
            var content = line.content
            if index == 0, content.hasPrefix("\u{FEFF}") { content.removeFirst() }
            let value = trimConfigWhitespace(content)
            let indented = content.unicodeScalars.first.map { configWhitespace.contains($0) } == true
            if indented && !value.isEmpty, var option = pending {
                option.value += " " + value
                option.lines = option.lines.lowerBound..<(index + 1)
                pending = option
                continue
            }
            if let pending { entries.append(pending) }
            pending = nil
            if value.isEmpty { continue }
            guard !indented else { throw invalidConfigSyntax() }
            if content.hasPrefix("#") { continue }
            if content.hasPrefix("[") {
                guard let end = content.firstIndex(of: "]") else { throw invalidConfigSyntax() }
                let name = String(content[content.index(after: content.startIndex)..<end]).lowercased()
                guard !name.isEmpty else { throw invalidConfigSyntax() }
                section = name
                sections.append((name, index))
                continue
            }
            guard let section, let separator = content.firstIndex(where: { $0 == ":" || $0 == "=" }) else {
                throw invalidConfigSyntax()
            }
            let name = trimConfigWhitespace(String(content[..<separator])).lowercased()
            guard !name.isEmpty else { throw invalidConfigSyntax() }
            pending = IgnoreConfigEntry(section: section, name: name,
                                        value: trimConfigWhitespace(String(content[content.index(after: separator)...])), lines: index..<(index + 1))
        }
        if let pending { entries.append(pending) }
        self.lines = lines
        self.entries = entries
        self.sections = sections
    }

    func replacingGlobalIgnores(with patterns: [String]) throws -> Data {
        var output = lines
        let value = patterns.joined(separator: " ")
        let ending = lines.first(where: { !$0.ending.isEmpty })?.ending ?? "\n"
        if let entry = entries.last(where: { $0.section == "miscellany" && $0.name == "global-ignores" }) {
            let first = output[entry.lines.lowerBound]
            guard let separator = first.content.firstIndex(where: { $0 == ":" || $0 == "=" }) else { throw invalidConfigSyntax() }
            let prefix = String(first.content[...separator]) + " "
            let lastEnding = output[entry.lines.upperBound - 1].ending
            output.replaceSubrange(entry.lines, with: [IgnoreConfigLine(content: prefix + value, ending: lastEnding)])
        } else if let section = sections.last(where: { $0.name == "miscellany" }) {
            if output[section.line].ending.isEmpty { output[section.line].ending = ending }
            output.insert(IgnoreConfigLine(content: "global-ignores = " + value, ending: ending), at: section.line + 1)
        } else {
            if let last = output.indices.last, output[last].ending.isEmpty { output[last].ending = ending }
            output.append(IgnoreConfigLine(content: "[miscellany]", ending: ending))
            output.append(IgnoreConfigLine(content: "global-ignores = " + value, ending: ending))
        }
        return Data(output.map(\.full).joined().utf8)
    }
}

private struct ResolvedIgnoreConfiguration {
    private var hasMiscellany = false
    private var values: [String: [String: String]] = [:]
    private var origins: [String: [String: URL]] = [:]

    mutating func merge(_ document: IgnoreConfigDocument, source: URL) throws {
        if document.sections.contains(where: { $0.name == "miscellany" }) { hasMiscellany = true }
        for entry in document.entries {
            values[entry.section, default: [:]][entry.name] = entry.value
            origins[entry.section, default: [:]][entry.name] = source
        }
    }

    var effectiveSource: URL? {
        guard hasMiscellany else { return nil }
        if values["miscellany"]?["global-ignores"] != nil { return origins["miscellany"]?["global-ignores"] }
        return origins["default"]?["global-ignores"]
    }

    func effectivePatterns() throws -> [String] {
        guard hasMiscellany, let raw = values["miscellany"]?["global-ignores"] ?? values["default"]?["global-ignores"] else {
            return SVNGlobalIgnores.defaultPatterns
        }
        let resolved = try expand(raw, section: "miscellany", stack: ["global-ignores"])
        return resolved.components(separatedBy: configWhitespace).filter { !$0.isEmpty }
    }

    private func expand(_ raw: String, section: String, stack: Set<String>) throws -> String {
        guard stack.count < 32 else { throw ignoreConfigError("SVN 忽略配置插值过深，无法安全修改。") }
        var result = ""
        var remainder = raw[...]
        while let start = remainder.range(of: "%("), let end = remainder[start.upperBound...].range(of: ")s") {
            result += remainder[..<start.lowerBound]
            let key = String(remainder[start.upperBound..<end.lowerBound]).lowercased()
            if let value = values[section]?[key] ?? values["default"]?[key] {
                guard !stack.contains(key) else { throw ignoreConfigError("SVN 忽略配置包含循环插值，无法安全修改。") }
                result += try expand(value, section: section, stack: stack.union([key]))
            } else {
                // SVN keeps undefined references (and unfinished '%(' tails) as
                // literal text. Retain them so unrelated patterns keep working.
                result += remainder[start.lowerBound..<end.upperBound]
            }
            guard result.utf8.count <= 1_024 * 1_024 else { throw ignoreConfigError("SVN 忽略配置插值过大，无法安全修改。") }
            remainder = remainder[end.upperBound...]
        }
        result += remainder
        return result
    }
}

private let configWhitespace = CharacterSet(charactersIn: " \t\r\n\u{0B}\u{0C}")
private func standardIgnoreConfigurationFiles() -> [URL] {
    [URL(fileURLWithPath: "/etc/subversion/config"),
     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".subversion/config")]
}
private func stableIgnorePatterns(_ patterns: [String]) -> [String] {
    var seen = Set<String>()
    return patterns.filter { seen.insert($0).inserted }
}
private func validateIgnoreConfigSnapshots(_ snapshots: [IgnoreConfigSnapshot]) throws {
    for original in snapshots {
        let current = try IgnoreConfigSnapshot.read(original.file)
        guard current.data == original.data, current.metadata == original.metadata else {
            throw ignoreConfigError("SVN 配置在读取后已变化，请重新读取配置后再操作。")
        }
    }
}
private func trimConfigWhitespace(_ value: String) -> String { value.trimmingCharacters(in: configWhitespace) }
private func invalidConfigSyntax() -> SVNError { ignoreConfigError("现有 SVN 配置格式无法安全解析，已停止修改。") }
private func ignoreConfigError(_ message: String) -> SVNError { .invalid(message) }

func writeSVNIgnoreFileExclusive(_ data: Data, to file: URL, permissions: UInt16, ownership: (UInt32, UInt32)?) throws {
    let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw ignoreConfigError("无法安全创建 SVN 配置临时文件或备份，请检查目录权限。") }
    defer { close(descriptor) }
    // An inherited macOS ACL can grant access despite POSIX 0600. Backups and
    // fresh temporary files start with an empty ACL; an existing config's ACL is
    // copied back onto its replacement only after the new contents are written.
    guard let emptyACL = acl_init(0) else {
        throw ignoreConfigError("无法建立受限的 SVN 配置备份权限，未写入内容。")
    }
    let restricted = acl_set_fd(descriptor, emptyACL) == 0
    acl_free(UnsafeMutableRawPointer(emptyACL))
    guard restricted else { throw ignoreConfigError("无法移除 SVN 配置备份的继承权限，未写入内容。") }
    var success = true
    data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { success = false; break }
            offset += count
        }
    }
    if let ownership, fchown(descriptor, ownership.0, ownership.1) != 0 { success = false }
    if fchmod(descriptor, mode_t(permissions)) != 0 || fsync(descriptor) != 0 { success = false }
    guard success else { throw ignoreConfigError("SVN 配置临时文件或备份写入未完整确认；原配置尚未替换，请检查磁盘和权限。") }
}
