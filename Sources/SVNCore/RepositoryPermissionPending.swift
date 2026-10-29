import Foundation
import CryptoKit

public struct RepositoryPermissionPending: Codable, Sendable {
    public let operationId: UUID
    public let endpoint: String
    public let review: RepositoryPermissionReview
    public init(operationId: UUID, endpoint: URL, review: RepositoryPermissionReview) {
        self.operationId = operationId; self.endpoint = endpoint.absoluteString; self.review = review
    }
}

/// The small, non-secret receipt is written before any remote mutation.
public actor RepositoryPermissionPendingStore {
    public static let shared = RepositoryPermissionPendingStore()
    private let directory: URL
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SVNManager/PermissionOperations", isDirectory: true)
    }
    private func file(_ endpoint: URL) -> URL {
        let digest = SHA256.hash(data: Data(endpoint.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }
    private func checkDirectory() throws {
        if let attributes = try attributesIfPresent(directory) {
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw invalid() }
        }
    }
    private func attributesIfPresent(_ url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && [4, 260].contains(error.code) { return nil }
    }
    private func invalid() -> SVNError { .invalid("无法安全读取或保存待核对授权记录，请保留现有记录并由管理员核对；没有重发授权。") }

    public func load(endpoint: URL) throws -> RepositoryPermissionPending? {
        try checkDirectory()
        let url = file(endpoint)
        guard let attributes = try attributesIfPresent(url) else { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 32_768 else { throw invalid() }
        let data = try Data(contentsOf: url)
        guard data.count <= 32_768,
              let pending = try? JSONDecoder().decode(RepositoryPermissionPending.self, from: data),
              pending.endpoint == endpoint.absoluteString else { throw invalid() }
        return pending
    }
    public func save(_ pending: RepositoryPermissionPending, endpoint: URL) throws {
        guard pending.endpoint == endpoint.absoluteString else { throw invalid() }
        try checkDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try load(endpoint: endpoint) == nil else { throw invalid() }
        let data = try JSONEncoder().encode(pending)
        guard data.count <= 32_768 else { throw invalid() }
        // Exclusive creation prevents replacing an unresolved operation, including across processes.
        let url = file(endpoint)
        try data.write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
    public func remove(endpoint: URL, operationId: UUID) throws {
        guard let pending = try load(endpoint: endpoint), pending.operationId == operationId else { throw invalid() }
        try FileManager.default.removeItem(at: file(endpoint))
    }
}
