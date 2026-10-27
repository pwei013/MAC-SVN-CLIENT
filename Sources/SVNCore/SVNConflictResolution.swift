import Foundation
import CoreFoundation
import Darwin

public enum SVNConflictChoice: String, CaseIterable, Identifiable, Sendable {
    case mine, theirs, manual
    public var id: String { rawValue }
    public var title: String {
        switch self { case .mine: return "保留本地"; case .theirs: return "使用云端"; case .manual: return "手动合并" }
    }
}

public enum SVNMergeLineEnding: String, CaseIterable, Identifiable, Sendable {
    case lf, crlf, cr
    public var id: String { rawValue }
    public var title: String { rawValue.uppercased() }
    var characters: String { self == .crlf ? "\r\n" : self == .cr ? "\r" : "\n" }
}

public struct SVNConflictPlan: Identifiable, Sendable {
    public let id = UUID()
    public let directory: URL
    public let path: String
    public let operation: String
    public let incomingRevision: String
    public let comparison: SVNFileComparison?
    public let workingDocument: SVNTextFileDocument?
    public let blockingReason: String?
    public let notice: String?
    public let canMerge: Bool
    public let preferredLineEnding: SVNMergeLineEnding
    public var localByteCount: Int { snapshot.files["local"]?.bytes.count ?? 0 }
    public var incomingByteCount: Int { snapshot.files["incoming"]?.bytes.count ?? 0 }
    let snapshot: ConflictSnapshot
}

public struct SVNConflictResolution: Identifiable, Sendable {
    public let id = UUID()
    public let plan: SVNConflictPlan
    public let choice: SVNConflictChoice
    public let lineEnding: SVNMergeLineEnding
    public var byteCount: Int { bytes.count }
    let bytes: Data
}

public struct SVNConflictResolutionOutcome: Sendable {
    public let backupDirectory: URL
}

struct ConflictInfo: Sendable, Equatable {
    let kind, root, url, repository, uuid, revision, schedule: String
    let copied: Bool
    let types: [String]
    let tree: Bool
    let textCount: Int
    let operation, mine, base, incoming, incomingRevision: String
    let versions: [String]
}

struct ConflictFile: Sendable, Equatable {
    let path: String
    let bytes: Data
    let device: UInt64
    let inode: UInt64
    let mode: UInt16
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
}

struct ConflictSnapshot: Sendable, Equatable {
    let info: ConflictInfo
    let status: LocalActionStatus
    let files: [String: ConflictFile]
    let parentDevice: UInt64
    let parentInode: UInt64
}

extension SVNClient {
    /// Conflict sides are immutable incoming/mine artifacts recorded by SVN.
    /// Reading HEAD here would be wrong for later commits and branch merges.
    public func prepareConflict(at requestedDirectory: URL, path: String) async throws -> SVNConflictPlan {
        try Task.checkCancellation()
        let directory = try conflictPhysicalDirectory(requestedDirectory)
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), !path.contains("\0"), !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".svn" }) else {
            throw SVNError.invalid("请选择当前工作目录内的单个冲突项目。")
        }
        let target = directory.appendingPathComponent(path)
        let parent = target.deletingLastPathComponent()
        guard try conflictPhysicalDirectory(parent).path == parent.path else {
            throw SVNError.invalid("冲突路径经过符号链接目录，未读取或修改文件。")
        }
        let arguments = try paths([path], at: directory)
        let data = try await boundedRead("info", ["--xml", "--depth", "empty", "--"] + arguments, at: directory,
            authenticated: false, limit: 512 * 1_024, message: "冲突元数据过大，未开始处理。")
        let info = try SVNXML.conflictInfo(data)
        let baseData = try await boundedRead("info", ["--xml", "--", ".@"], at: directory,
            authenticated: false, limit: 512 * 1_024, message: "工作副本元数据过大，未开始处理。")
        let scope = try SVNXML.parseInfo(baseData), repository = try SVNXML.parseRepositoryInfo(baseData)
        guard scope.rootPath == info.root, scope.repositoryRootURL == info.repository, repository.uuid == info.uuid else {
            throw SVNError.invalid("冲突项目属于其他工作副本或仓库，未开始处理。请单独打开对应工作副本。")
        }
        let statusData = try await boundedRead("status", ["--xml", "--verbose", "--ignore-externals", "--depth", "empty", "--"] + arguments,
            at: directory, authenticated: false, limit: 512 * 1_024, message: "冲突状态过大，未开始处理。")
        let statuses = try SVNXML.localActionStatuses(statusData)
        guard statuses.count == 1, let status = statuses.first, status.path == path,
              !info.root.isEmpty, !info.uuid.isEmpty, !info.repository.isEmpty,
              status.item == "conflicted" || status.properties == "conflicted" || info.tree else {
            throw SVNError.invalid("该项目当前没有可处理的 SVN 冲突，请刷新列表。")
        }
        var blocking: String?
        if info.tree || info.types.contains("property") || status.properties == "conflicted" {
            blocking = "该项包含属性冲突或目录树冲突，需要先核对属性、移动或删除关系；文件内容选择不会清除这些冲突。请先处理这些关系后重新读取。"
        } else if info.kind != "file" || info.schedule != "normal" || info.copied || status.unsafe ||
                    info.textCount != 1 || info.types != ["text"] || info.incoming.isEmpty || !["update", "switch", "merge"].contains(info.operation) {
            blocking = "该项不是可单独处理的普通文件内容冲突；请先检查复制、移动、外部工作副本或异常元数据。未修改文件或清除冲突标记。"
        }
        var parentStat = stat()
        guard lstat(parent.path, &parentStat) == 0, parentStat.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw SVNError.invalid("冲突所在目录已变化，请刷新。")
        }
        var files: [String: ConflictFile] = [:]
        var comparison: SVNFileComparison?
        var working: SVNTextFileDocument?
        var notice: String?
        if blocking == nil {
            do {
                files["working"] = try conflictRead(target)
                func artifact(_ path: String) throws -> ConflictFile {
                    let url = path.hasPrefix("/") ? URL(fileURLWithPath: path).standardizedFileURL : parent.appendingPathComponent(path).standardizedFileURL
                    guard try conflictPhysicalDirectory(url.deletingLastPathComponent()).path == parent.path,
                          url.lastPathComponent != target.lastPathComponent,
                          url.lastPathComponent != ".svn" else { throw SVNError.invalid("SVN 冲突辅助文件超出当前文件所在目录。") }
                    // Read via our canonical parent after validating SVN's path;
                    // macOS may report /var aliases for a /private/var WC.
                    return try conflictRead(parent.appendingPathComponent(url.lastPathComponent))
                }
                files["local"] = info.mine.isEmpty ? files["working"] : try artifact(info.mine)
                files["incoming"] = try artifact(info.incoming)
                if !info.base.isEmpty { files["base"] = try artifact(info.base) }
                let local = try? comparisonTextDocument(files["local"]!.bytes)
                let incoming = try? comparisonTextDocument(files["incoming"]!.bytes)
                working = try? comparisonTextDocument(files["working"]!.bytes)
                if let local, let incoming {
                    comparison = SVNFileComparison(local: local, remote: incoming,
                        remoteLabel: "云端 r\(info.incomingRevision.isEmpty ? "?" : info.incomingRevision)（冲突入站版本）",
                        notice: nil, localLabel: "本地版本（冲突前）")
                    notice = "对比固定在发生冲突时的两侧版本，不读取最新 HEAD。保留本地或使用云端会选用该侧完整文件。"
                } else {
                    notice = "二进制或无法可靠解码的文件不进行文本编辑；可选择完整本地或云端文件。本地 \(files["local"]!.bytes.count) 字节，云端 \(files["incoming"]!.bytes.count) 字节。"
                }
            } catch is CancellationError { throw CancellationError() }
            catch { blocking = error.localizedDescription; files = [:] }
        }
        let ending: SVNMergeLineEnding = comparison?.local.lineEnding == "CRLF" ? .crlf : comparison?.local.lineEnding == "CR" ? .cr : .lf
        try Task.checkCancellation()
        return SVNConflictPlan(directory: directory, path: path, operation: info.operation, incomingRevision: info.incomingRevision,
            comparison: comparison, workingDocument: working, blockingReason: blocking, notice: notice,
            canMerge: blocking == nil && comparison != nil && working != nil && files.values.allSatisfy { $0.bytes.count <= 512 * 1_024 },
            preferredLineEnding: ending, snapshot: ConflictSnapshot(info: info, status: status, files: files,
                parentDevice: UInt64(parentStat.st_dev), parentInode: UInt64(parentStat.st_ino)))
    }

    /// Prepares a concrete result for user confirmation; never writes files.
    public func prepareConflictResolution(_ plan: SVNConflictPlan, choice: SVNConflictChoice, mergedText: String = "",
                                          lineEnding: SVNMergeLineEnding = .lf) async throws -> SVNConflictResolution {
        guard plan.blockingReason == nil else { throw SVNError.invalid(plan.blockingReason!) }
        let bytes: Data
        if choice == .manual {
            guard plan.canMerge, let original = plan.comparison?.local else { throw SVNError.invalid("该文件不支持应用内手动文本合并，请选择完整版本或在外部处理。") }
            guard mergedText.utf8.count <= 2 * 1_024 * 1_024 else { throw SVNError.invalid("合并结果过大，请缩小内容或在外部编辑。") }
            let normalized = mergedText.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            guard !normalized.split(separator: "\n", omittingEmptySubsequences: false).contains(where: {
                $0.hasPrefix("<<<<<<<") || $0.hasPrefix(">>>>>>>") || $0.hasPrefix("|||||||")
            }) else { throw SVNError.invalid("合并结果仍包含 SVN 冲突标记，请处理后再标记为已解决。") }
            bytes = try conflictEncode(normalized.replacingOccurrences(of: "\n", with: lineEnding.characters), encoding: original.encoding)
        } else {
            guard let selected = plan.snapshot.files[choice == .mine ? "local" : "incoming"] else { throw SVNError.invalid("冲突版本文件不完整，请重新读取。") }
            bytes = selected.bytes
        }
        try Task.checkCancellation()
        return SVNConflictResolution(plan: plan, choice: choice, lineEnding: lineEnding, bytes: bytes)
    }

    /// A single reviewed file, a durable backup, and one native resolve command.
    /// Unknown outcomes are surfaced with the backup path and never replayed.
    public func applyConflictResolution(_ resolution: SVNConflictResolution, backupRoot: URL) async throws -> SVNConflictResolutionOutcome {
        let plan = resolution.plan
        guard plan.blockingReason == nil else { throw SVNError.invalid(plan.blockingReason!) }
        let current = try await prepareConflict(at: plan.directory, path: plan.path)
        guard current.snapshot == plan.snapshot, current.blockingReason == nil else {
            throw SVNError.invalid("确认期间文件内容、冲突辅助文件或工作副本身份已变化，未执行处理。请关闭后重新读取。")
        }
        try Task.checkCancellation()
        let backup = try conflictBackup(plan, root: backupRoot, merged: resolution.choice == .manual ? resolution.bytes : nil)
        do {
            // Backups may take time. Recheck the complete local snapshot once more.
            let fresh = try await prepareConflict(at: plan.directory, path: plan.path)
            guard fresh.snapshot == plan.snapshot else { throw SVNError.invalid("备份期间冲突内容发生变化，未执行处理。") }
            try Task.checkCancellation()
            if resolution.choice == .manual {
                try conflictWrite(resolution.bytes, snapshot: plan.snapshot, target: plan.directory.appendingPathComponent(plan.path))
                let check = try await prepareConflict(at: plan.directory, path: plan.path)
                var expected = plan.snapshot.files
                guard let changed = check.snapshot.files["working"] else { throw SVNError.invalid("无法核对合并结果，尚未标记已解决。") }
                expected["working"] = changed
                // Binary-style text conflicts have no separate .mine artifact.
                if plan.snapshot.info.mine.isEmpty { expected["local"] = changed }
                guard check.snapshot.info == plan.snapshot.info, check.snapshot.status == plan.snapshot.status,
                      check.snapshot.files == expected, changed.bytes == resolution.bytes else {
                    throw SVNError.invalid("写入后冲突状态或辅助文件已变化，尚未标记已解决。")
                }
            }
            let accept = resolution.choice == .mine ? "mine-full" : resolution.choice == .theirs ? "theirs-full" : "working"
            _ = try await execute("resolve", ["--depth", "empty", "--accept", accept, "--"] + paths([plan.path], at: plan.directory), at: plan.directory)
            let status = try await execute("status", ["--xml", "--verbose", "--ignore-externals", "--depth", "empty", "--"] + paths([plan.path], at: plan.directory), at: plan.directory).stdout
            let after = try SVNXML.localActionStatuses(status)
            guard after.count == 1, let item = after.first, item.path == plan.path, !item.unsafe,
                  ["normal", "modified"].contains(item.item), item.properties != "conflicted",
                  try conflictRead(plan.directory.appendingPathComponent(plan.path)).bytes == resolution.bytes else {
                throw SVNError.invalid("处理命令已运行，但结果核对未完整通过。请刷新检查，不要重复执行。")
            }
            return SVNConflictResolutionOutcome(backupDirectory: backup)
        } catch {
            throw SVNError.invalid("冲突处理未完整确认，请刷新核对；未自动重试或提交。处理前备份：\(backup.path)\n\(error.localizedDescription)")
        }
    }
}

private func conflictPhysicalDirectory(_ url: URL) throws -> URL {
    guard url.isFileURL, let pointer = url.withUnsafeFileSystemRepresentation({ $0.flatMap { realpath($0, nil) } }) else {
        throw SVNError.invalid("本地工作目录不存在或无法访问。")
    }
    defer { free(pointer) }
    return URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
}

private func conflictRead(_ file: URL) throws -> ConflictFile {
    let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { throw SVNError.invalid("冲突文件或辅助文件不可读取、已丢失或变成符号链接：\(file.lastPathComponent)") }
    defer { close(descriptor) }
    var before = stat()
    guard fstat(descriptor, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_nlink == 1,
          before.st_size >= 0, before.st_size <= 4 * 1_024 * 1_024 else {
        throw SVNError.invalid("冲突处理仅支持不超过 4 MiB 的普通单链接文件；大文件、目录或链接请在外部处理。")
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    var data = Data()
    while let part = try handle.read(upToCount: 64 * 1_024), !part.isEmpty {
        try Task.checkCancellation()
        data.append(part)
        guard data.count <= 4 * 1_024 * 1_024 else { throw SVNError.invalid("读取期间文件变大，未开始冲突处理。") }
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0, before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
          before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec, data.count == Int(before.st_size) else {
        throw SVNError.invalid("读取期间冲突文件发生变化，请重新读取。")
    }
    return ConflictFile(path: file.path, bytes: data, device: UInt64(before.st_dev), inode: UInt64(before.st_ino),
        mode: UInt16(before.st_mode), modifiedSeconds: before.st_mtimespec.tv_sec, modifiedNanoseconds: before.st_mtimespec.tv_nsec)
}

private func conflictEncode(_ text: String, encoding: String) throws -> Data {
    let codec: String.Encoding
    let prefix: Data
    switch encoding {
    case "UTF-8": codec = .utf8; prefix = Data()
    case "UTF-8（BOM）": codec = .utf8; prefix = Data([0xEF, 0xBB, 0xBF])
    case "UTF-16 LE（BOM）": codec = .utf16LittleEndian; prefix = Data([0xFF, 0xFE])
    case "UTF-16 BE（BOM）": codec = .utf16BigEndian; prefix = Data([0xFE, 0xFF])
    case "UTF-16 LE（无 BOM）": codec = .utf16LittleEndian; prefix = Data()
    case "UTF-16 BE（无 BOM）": codec = .utf16BigEndian; prefix = Data()
    case "GB18030", "GBK":
        codec = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding == "GBK" ? 0x0631 : 0x0632)))
        prefix = Data()
    default: throw SVNError.invalid("无法安全写入原文件编码，请在外部合并。")
    }
    guard let bytes = text.data(using: codec, allowLossyConversion: false), String(data: bytes, encoding: codec) == text else {
        throw SVNError.invalid("合并内容含原文件编码无法表示的字符，未写入文件。请调整内容后重试。")
    }
    _ = try comparisonTextDocument(prefix + bytes)
    return prefix + bytes
}

private func conflictBackup(_ plan: SVNConflictPlan, root: URL, merged: Data?) throws -> URL {
    guard root.isFileURL else { throw SVNError.invalid("冲突备份必须保存到本地目录。") }
    let root = root.standardizedFileURL.resolvingSymlinksInPath()
    let wc = URL(fileURLWithPath: plan.snapshot.info.root).standardizedFileURL.resolvingSymlinksInPath().path
    guard root.path != wc, !root.path.hasPrefix(wc + "/") else { throw SVNError.invalid("冲突备份目录必须位于工作副本之外。") }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let physical = try conflictPhysicalDirectory(root)
    guard physical.path != wc, !physical.path.hasPrefix(wc + "/") else { throw SVNError.invalid("冲突备份目录不能指向工作副本内部。") }
    let directory = physical.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    for (name, file) in plan.snapshot.files { try conflictExclusiveWrite(file.bytes, file: directory.appendingPathComponent(name)) }
    if let merged { try conflictExclusiveWrite(merged, file: directory.appendingPathComponent("merged")) }
    let metadata = try JSONSerialization.data(withJSONObject: ["path": plan.path, "directory": plan.directory.path,
        "incomingRevision": plan.incomingRevision, "operation": plan.operation], options: [.sortedKeys])
    try conflictExclusiveWrite(metadata, file: directory.appendingPathComponent("metadata.json"))
    return directory
}

private func conflictExclusiveWrite(_ data: Data, file: URL) throws {
    let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw SVNError.invalid("无法创建处理前备份；未处理冲突。") }
    defer { close(descriptor) }
    try conflictWriteBytes(data, descriptor: descriptor)
    guard fsync(descriptor) == 0 else { throw SVNError.invalid("备份未完整保存，未处理冲突。") }
}

private func conflictWrite(_ data: Data, snapshot: ConflictSnapshot, target: URL) throws {
    let parent = open(target.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard parent >= 0 else { throw SVNError.invalid("文件所在目录已变化，未写入合并结果。") }
    defer { close(parent) }
    var directoryStat = stat()
    guard fstat(parent, &directoryStat) == 0, UInt64(directoryStat.st_dev) == snapshot.parentDevice,
          UInt64(directoryStat.st_ino) == snapshot.parentInode,
          let expected = snapshot.files["working"], try conflictRead(target) == expected else {
        throw SVNError.invalid("工作文件在确认后已变化，未覆盖新内容。")
    }
    let descriptor = openat(parent, target.lastPathComponent, O_WRONLY | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { throw SVNError.invalid("无法写入本地合并文件，请检查写入权限。") }
    defer { close(descriptor) }
    var fileStat = stat()
    guard fstat(descriptor, &fileStat) == 0, UInt64(fileStat.st_dev) == expected.device, UInt64(fileStat.st_ino) == expected.inode,
          UInt16(fileStat.st_mode) == expected.mode, fileStat.st_size == expected.bytes.count,
          fileStat.st_mtimespec.tv_sec == expected.modifiedSeconds, fileStat.st_mtimespec.tv_nsec == expected.modifiedNanoseconds else {
        throw SVNError.invalid("工作文件在写入前发生变化，尚未覆盖。")
    }
    try conflictWriteBytes(data, descriptor: descriptor)
    guard ftruncate(descriptor, off_t(data.count)) == 0, fsync(descriptor) == 0 else {
        throw SVNError.invalid("合并文件写入未完整完成，请使用备份核对；尚未标记已解决。")
    }
}

private func conflictWriteBytes(_ data: Data, descriptor: Int32) throws {
    try data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw SVNError.invalid("文件写入失败，请检查权限及磁盘空间。") }
            offset += count
        }
    }
}
