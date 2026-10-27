import Foundation

public struct SVNCheckoutWorkingCopy: Sendable {
    public let info: WorkingCopyInfo
    let uuid: String
}

extension SVNClient {
    /// Local metadata only: identify the selected scope before asking to overwrite
    /// an ordinary folder. A different branch/path is never silently switched.
    public func checkoutWorkingCopy(at destination: URL, matching url: String) async throws -> SVNCheckoutWorkingCopy? {
        _ = try SVNCheckoutDestination.isNonempty(destination)
        guard let metadataRoot = try checkoutWorkingCopyRoot(at: destination) else { return nil }
        let data = try await execute("info", ["--xml", "--", ".@"], at: destination).stdout
        let info = try SVNXML.parseInfo(data), identity = try SVNXML.parseRepositoryInfo(data)
        let requested = try RepositoryCredentialScope.canonicalURL(url)
        guard try RepositoryCredentialScope.canonicalURL(info.url) == requested else {
            throw SVNError.invalid("目标工作副本对应其他仓库目录。请选择与当前仓库地址对应的工作副本；不会切换地址或覆盖本地修改。")
        }
        guard let revision = Int64(info.revision), revision >= 0,
              URL(fileURLWithPath: info.rootPath).standardizedFileURL.resolvingSymlinksInPath() == metadataRoot.resolvingSymlinksInPath(),
              RepositoryCredentialScope.contains(root: identity.rootURL, url: requested) else {
            throw SVNError.invalid("无法确认目标工作副本的仓库身份及目录范围，未执行更新。")
        }
        return SVNCheckoutWorkingCopy(info: info, uuid: identity.uuid)
    }

    /// Reuse normal update semantics: merge local edits, postpone conflicts, retain
    /// unversioned files. Never force checkout, revert, switch or retry a write.
    public func updateCheckout(_ target: SVNCheckoutWorkingCopy, at destination: URL,
        onProgress: @escaping @Sendable (SVNOperationEvent) -> Void) async throws -> SVNOperationResult {
        let remote = try await execute("info", ["--xml", "--", target.info.url + "@"], authenticated: true)
        _ = try SVNXML.parseCheckoutRevision(remote.stdout)
        let identity = try SVNXML.parseRepositoryInfo(remote.stdout)
        guard identity.uuid == target.uuid,
              try RepositoryCredentialScope.canonicalURL(identity.rootURL) == RepositoryCredentialScope.canonicalURL(target.info.repositoryRootURL),
              let current = try await checkoutWorkingCopy(at: destination, matching: target.info.url),
              current.uuid == target.uuid, current.info.rootPath == target.info.rootPath,
              current.info.repositoryRootURL == target.info.repositoryRootURL else {
            throw SVNError.invalid("工作副本或服务器仓库身份已变化，未执行更新。请重新选择目录并检查。")
        }
        try Task.checkCancellation()
        return try await updateWithProgress(at: destination, onProgress: onProgress)
    }
}
