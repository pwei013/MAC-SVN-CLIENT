import Foundation

public struct SVNRemoteDiffTarget: Sendable {
    public let directory: URL
    public let path: String
    public let url: String
    fileprivate let identity: RemoteDiffIdentity
}

extension SVNClient {
    /// Local validation only. The returned file URL allows the model to select
    /// credentials for this exact repository before any HEAD request is made.
    public func prepareRemoteFileDiff(at requestedDirectory: URL, path: String) async throws -> SVNRemoteDiffTarget {
        try Task.checkCancellation()
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard requestedDirectory.isFileURL, requestedDirectory.query == nil, requestedDirectory.fragment == nil,
              !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0 != ".svn" }) else {
            throw SVNError.invalid("请选择工作副本内有效的文件相对路径。")
        }
        let directory = URL(fileURLWithPath: requestedDirectory.standardizedFileURL.path, isDirectory: true)
        let file = directory.appendingPathComponent(path).standardizedFileURL
        let parent = file.deletingLastPathComponent()
        guard directory.path == directory.resolvingSymlinksInPath().path,
              parent.path == parent.resolvingSymlinksInPath().path,
              file.path.hasPrefix(directory.path + "/") else {
            throw SVNError.invalid("不支持符号链接父目录或超出工作副本的文件路径。")
        }
        let metadata: [FileAttributeKey: Any]
        do { metadata = try FileManager.default.attributesOfItem(atPath: file.path) }
        catch { throw SVNError.invalid("本地文件不存在或无法读取，请刷新文件状态后重试。") }
        let type = metadata[.type] as? FileAttributeType
        guard type == .typeRegular || type == .typeSymbolicLink else {
            throw SVNError.invalid("与云端最新版本比较仅支持本地存在的文件或 SVN 符号链接。")
        }
        let targets = try paths([path], at: directory)
        let base = try await info(at: directory)
        let data = try await execute("info", ["--xml", "--depth", "empty", "--"] + targets, at: directory).stdout
        let fileInfo = try SVNXML.parseInfo(data)
        let kinds = try SVNXML.parseWorkingCopyNodeKinds(data)
        let root = URL(fileURLWithPath: base.rootPath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let fileRoot = URL(fileURLWithPath: fileInfo.rootPath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        guard kinds.count == 1, kinds.values.first == .file,
              root.path == fileRoot.path, base.repositoryRootURL == fileInfo.repositoryRootURL,
              (parent.path == root.path || parent.path.hasPrefix(root.path + "/")) else {
            throw SVNError.invalid("目标不是当前工作副本中的已跟踪文件，或位于外部工作副本中。")
        }
        let status = try SVNXML.parseStatus(await execute("status", ["--xml", "--verbose", "--ignore-externals", "--no-ignore", "--depth", "empty", "--"] + targets, at: directory).stdout)
        guard status.allSatisfy({ !$0.treeConflicted && ["normal", "none", "modified", "replaced", "conflicted"].contains($0.item) }) else {
            throw SVNError.invalid("该文件尚无可比较的云端版本，或本地处于新增、删除、缺失或阻塞状态。请先刷新检查。")
        }
        if type == .typeSymbolicLink {
            do { _ = try await execute("propget", ["--strict", "svn:special", "--"] + targets, at: directory) }
            catch is CancellationError { throw CancellationError() }
            catch { throw SVNError.invalid("该符号链接未被 SVN 记录为符号链接，无法安全比较。") }
        }
        let location = try SVNLocation.validated(fileInfo.url)
        let identity = RemoteDiffIdentity(root: root.path, directoryURL: base.url, repository: base.repositoryRootURL,
                                          fileURL: location.absoluteString, kind: type == .typeSymbolicLink ? "symlink" : "file")
        return SVNRemoteDiffTarget(directory: directory, path: path, url: location.absoluteString, identity: identity)
    }

    /// Compare HEAD directly to the working file. No BASE fallback, update or file
    /// replacement is performed. Drain stdout while retaining at most 512 KiB.
    public func diffAgainstHead(_ target: SVNRemoteDiffTarget) async throws -> String {
        _ = try await revalidatedRemoteFileDiffTarget(target)
        try Task.checkCancellation()
        let buffer = RemoteDiffBuffer(limit: 512 * 1_024)
        do {
            // The validated target is one file (including svn:special), never a
            // directory. SVN's depth=empty suppresses modified symlink content.
            _ = try await execute("diff", ["--internal-diff", "--revision", "HEAD", "--"] +
                paths([target.path], at: target.directory), at: target.directory, authenticated: true,
                onStdout: { buffer.append($0) }, captureStdout: false)
        } catch is CancellationError { throw CancellationError() }
        catch let error as SVNError {
            if error.isAuthenticationFailure { throw error }
            throw SVNError.invalid("与云端最新版本比较失败，请检查网络、权限，以及云端文件是否已被删除或改名。\n\(error.localizedDescription)")
        }
        try Task.checkCancellation()
        return buffer.text()
    }

    func revalidatedRemoteFileDiffTarget(_ target: SVNRemoteDiffTarget) async throws -> SVNRemoteDiffTarget {
        let current = try await prepareRemoteFileDiff(at: target.directory, path: target.path)
        guard current.identity == target.identity else {
            throw SVNError.invalid("文件地址、工作副本或节点类型在确认期间已变化，请重新选择后比较。")
        }
        return current
    }
}

fileprivate struct RemoteDiffIdentity: Equatable, Sendable {
    let root: String
    let directoryURL: String
    let repository: String
    let fileURL: String
    let kind: String
}

private final class RemoteDiffBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var truncated = false
    init(limit: Int) { self.limit = limit }
    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, limit - data.count)
        data.append(contentsOf: chunk.prefix(remaining))
        if chunk.count > remaining { truncated = true }
    }
    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        if truncated, !data.isEmpty {
            let tail = Array(data.suffix(4))
            var lead = tail.count - 1
            while lead > 0, tail[lead] & 0xC0 == 0x80 { lead -= 1 }
            let first = tail[lead]
            let length = first >= 0xC2 && first <= 0xDF ? 2 : first >= 0xE0 && first <= 0xEF ? 3 : first >= 0xF0 && first <= 0xF4 ? 4 : 1
            let present = tail.count - lead
            if length > present { data.removeLast(present) }
        }
        return String(decoding: data, as: UTF8.self) +
            (truncated ? "\n\n… 差异超过 512 KiB，已截断显示；本地文件未被修改。\n" : "")
    }
}
