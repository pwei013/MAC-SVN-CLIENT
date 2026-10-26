import CryptoKit
import Darwin
import Foundation

/// The selected local scope and its current SVN mapping form one workspace.
/// A switched directory or a second checkout must not inherit another draft.
public struct SVNProjectIdentity: Codable, Sendable, Equatable {
    public let directoryPath: String
    public let repositoryRootURL: String
    public let directoryURL: String

    public init(directory: URL, repositoryRootURL: String, directoryURL: String) throws {
        guard directory.isFileURL, directory.query == nil, directory.fragment == nil,
              !directory.path.contains("\0") else {
            throw SVNError.invalid("无法确认项目状态对应的本地目录。")
        }
        let root = try RepositoryCredentialScope.canonicalURL(repositoryRootURL)
        let location = try RepositoryCredentialScope.canonicalURL(directoryURL)
        guard RepositoryCredentialScope.contains(root: root, url: location) else {
            throw SVNError.invalid("项目目录地址不属于当前 SVN 仓库。")
        }
        directoryPath = directory.standardizedFileURL.resolvingSymlinksInPath().path
        self.repositoryRootURL = root
        self.directoryURL = location
    }

    fileprivate var fileName: String {
        let bytes = Data([directoryPath, repositoryRootURL, directoryURL].joined(separator: "\0").utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() + ".json"
    }
}

public struct SVNProjectState: Codable, Sendable, Equatable {
    public let commitMessage: String
    public let checkedPaths: Set<String>
    public let changeSearch: String
    public let changeSelection: String?
    public let statusFilter: WorkingCopyStatusFilter
    public let kindFilter: WorkingCopyKindFilter

    public init(commitMessage: String = "", checkedPaths: Set<String> = [],
                changeSearch: String = "", changeSelection: String? = nil,
                statusFilter: WorkingCopyStatusFilter = .all, kindFilter: WorkingCopyKindFilter = .all) {
        self.commitMessage = commitMessage
        self.checkedPaths = checkedPaths
        self.changeSearch = changeSearch
        self.changeSelection = changeSelection
        self.statusFilter = statusFilter
        self.kindFilter = kindFilter
    }

    private enum CodingKeys: String, CodingKey {
        case commitMessage, checkedPaths, changeSearch, changeSelection, statusFilter, kindFilter
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        commitMessage = try values.decode(String.self, forKey: .commitMessage)
        checkedPaths = try values.decode(Set<String>.self, forKey: .checkedPaths)
        changeSearch = try values.decode(String.self, forKey: .changeSearch)
        changeSelection = try values.decodeIfPresent(String.self, forKey: .changeSelection)
        statusFilter = WorkingCopyStatusFilter(rawValue: try values.decodeIfPresent(String.self, forKey: .statusFilter) ?? "") ?? .all
        kindFilter = WorkingCopyKindFilter(rawValue: try values.decodeIfPresent(String.self, forKey: .kindFilter) ?? "") ?? .all
    }

    fileprivate func validate() throws {
        guard commitMessage.utf8.count <= 128 * 1_024, changeSearch.utf8.count <= 8_192,
              checkedPaths.count <= 10_000 else {
            throw SVNError.invalid("项目工作状态过大，未覆盖已有草稿；请缩短提交说明或减少勾选。")
        }
        for (index, path) in checkedPaths.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard Self.validRelativePath(path) else { throw SVNError.invalid("项目工作状态包含无效文件路径。") }
        }
        if let changeSelection, !Self.validRelativePath(changeSelection) {
            throw SVNError.invalid("项目工作状态包含无效选中路径。")
        }
    }

    private static func validRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 4_096, !path.hasPrefix("/"), !path.contains("\0") else { return false }
        if path == "." { return true }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0 != ".svn" }
    }
}

/// All disk work is actor-isolated and runs away from the main actor. The caller
/// debounces edits and supplies a monotonically increasing sequence per session.
/// Late saves with an older sequence are ignored, including after a project switch.
public actor SVNProjectStateStore {
    public let directory: URL
    private let maximumProjects: Int
    private var latestSequences: [String: UInt64] = [:]
    private var knownRecordNames: Set<String>?
    private static let maximumRecordBytes = 512 * 1_024
    private static let format = "com.mky.svnmanager.project-state.v1"

    public init(directory: URL, maximumProjects: Int = 100) {
        self.directory = directory.standardizedFileURL
        self.maximumProjects = min(100, max(1, maximumProjects))
    }

    /// Missing, corrupt, oversized, or differently mapped records do not restore
    /// anything. Filesystem permission/path failures remain visible to the caller.
    public func load(identity: SVNProjectIdentity) throws -> SVNProjectState? {
        try Task.checkCancellation()
        guard let descriptor = try openDirectory(create: false) else { return nil }
        defer { close(descriptor) }
        guard let data = try readRecord(identity.fileName, descriptor: descriptor),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.format == Self.format, record.identity == identity else { return nil }
        do { try record.state.validate() }
        catch is CancellationError { throw CancellationError() }
        catch { return nil }
        try Task.checkCancellation()
        return record.state
    }

    /// Returns false when a newer edit has already been saved in this session.
    /// No draft text is silently truncated. A successful save is atomically visible.
    @discardableResult
    public func save(_ state: SVNProjectState, identity: SVNProjectIdentity,
                     sequence: UInt64? = nil) throws -> Bool {
        try Task.checkCancellation()
        let name = identity.fileName
        if let sequence, let latest = latestSequences[name], sequence <= latest { return false }
        try state.validate()
        let data = try JSONEncoder().encode(Record(format: Self.format, identity: identity, state: state))
        guard data.count <= Self.maximumRecordBytes else {
            throw SVNError.invalid("项目工作状态超过 512 KiB，未覆盖已有草稿；请减少勾选或缩短提交说明。")
        }
        guard let descriptor = try openDirectory(create: true) else { throw storageError() }
        defer { close(descriptor) }
        let temporary = ".pending-" + UUID().uuidString + ".tmp"
        let file = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard file >= 0 else { throw storageError() }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        var renamed = false
        defer {
            try? handle.close()
            if !renamed { _ = unlinkat(descriptor, temporary, 0) }
        }
        do {
            guard fchmod(file, mode_t(0o600)) == 0 else { throw storageError() }
            try handle.write(contentsOf: data)
            guard fsync(file) == 0 else { throw storageError() }
            try Task.checkCancellation()
            guard renameat(descriptor, temporary, descriptor, name) == 0 else { throw storageError() }
            renamed = true
            _ = fsync(descriptor)
        } catch is CancellationError { throw CancellationError() }
        catch { throw storageError() }
        if let sequence { latestSequences[name] = sequence }
        try pruneRecords(keeping: name, descriptor: descriptor)
        return true
    }

    private struct Record: Codable {
        let format: String
        let identity: SVNProjectIdentity
        let state: SVNProjectState
    }

    private func openDirectory(create: Bool) throws -> Int32? {
        guard directory.isFileURL, directory.query == nil, directory.fragment == nil,
              directory.path != "/", !directory.path.contains("\0") else { throw storageError() }
        var before = stat()
        if lstat(directory.path, &before) != 0 {
            guard errno == ENOENT else { throw storageError() }
            guard create else { return nil }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: 0o700)])
            } catch { throw storageError() }
        } else {
            guard before.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), before.st_uid == getuid() else { throw storageError() }
        }
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw storageError() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == getuid(),
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              (!create || fchmod(descriptor, mode_t(0o700)) == 0) else {
            close(descriptor)
            throw storageError()
        }
        return descriptor
    }

    private func readRecord(_ name: String, descriptor: Int32) throws -> Data? {
        let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else {
            if errno == ENOENT || errno == ELOOP { return nil }
            throw storageError()
        }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(file, &metadata) == 0 else { throw storageError() }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), metadata.st_uid == getuid(),
              metadata.st_size >= 0, metadata.st_size <= Self.maximumRecordBytes else { return nil }
        do {
            let data = try handle.read(upToCount: Self.maximumRecordBytes + 1) ?? Data()
            return data.count <= Self.maximumRecordBytes ? data : nil
        } catch { throw storageError() }
    }

    private func pruneRecords(keeping current: String, descriptor: Int32) throws {
        // Parse the existing private records once, not on every debounced edit.
        // Later saves only stat the bounded set and revalidate actual evictions.
        if knownRecordNames == nil {
            let names: [String]
            do { names = try FileManager.default.contentsOfDirectory(atPath: directory.path) }
            catch { throw SVNError.invalid("项目工作状态已保存，但无法清理旧项目记录。") }
            var known = Set<String>()
            for (index, name) in names.enumerated() {
                if index.isMultiple(of: 64) { try Task.checkCancellation() }
                guard name.count == 69, name.hasSuffix(".json"),
                      name.prefix(64).allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
                      let data = try readRecord(name, descriptor: descriptor),
                      let record = try? JSONDecoder().decode(Record.self, from: data),
                      record.format == Self.format, record.identity.fileName == name else { continue }
                known.insert(name)
            }
            knownRecordNames = known
        }
        knownRecordNames?.insert(current)
        var records: [(name: String, seconds: Int, nanos: Int)] = []
        for name in knownRecordNames ?? [] {
            var metadata = stat()
            guard fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            records.append((name, metadata.st_mtimespec.tv_sec, metadata.st_mtimespec.tv_nsec))
        }
        guard records.count > maximumProjects else { return }
        records.sort {
            if $0.name == current { return false }
            if $1.name == current { return true }
            if $0.seconds != $1.seconds { return $0.seconds < $1.seconds }
            if $0.nanos != $1.nanos { return $0.nanos < $1.nanos }
            return $0.name < $1.name
        }
        for record in records.prefix(records.count - maximumProjects) {
            guard let data = try readRecord(record.name, descriptor: descriptor),
                  let content = try? JSONDecoder().decode(Record.self, from: data),
                  content.format == Self.format, content.identity.fileName == record.name else {
                knownRecordNames?.remove(record.name)
                continue
            }
            guard unlinkat(descriptor, record.name, 0) == 0 || errno == ENOENT else {
                throw SVNError.invalid("项目工作状态已保存，但旧项目记录清理失败。")
            }
            knownRecordNames?.remove(record.name)
        }
    }

    private func storageError() -> SVNError {
        .invalid("无法读取或保存项目工作状态，请检查应用支持目录的权限；已有草稿未被覆盖。")
    }
}
