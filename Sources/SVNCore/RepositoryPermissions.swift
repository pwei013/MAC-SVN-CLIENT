import Foundation
import Security

public enum RepositoryPermissionAccess: String, Codable, CaseIterable, Sendable {
    case none, read, write, removeExplicit
    public var label: String {
        switch self { case .none: return "无访问"; case .read: return "只读"; case .write: return "读写"; case .removeExplicit: return "移除此处显式规则" }
    }
}

public struct RepositoryPermissionAccount: Codable, Hashable, Identifiable, Sendable {
    public let kind: String
    public let name: String
    public var id: String { kind + ":" + name }
    public var label: String { (kind == "group" ? "组 · " : "用户 · ") + name }
}

public struct RepositoryPermissionRule: Codable, Hashable, Identifiable, Sendable {
    public let accountKind: String
    public let accountName: String
    public let access: RepositoryPermissionAccess
    public let sourcePath: String
    public let isInherited: Bool
    public var id: String { sourcePath + ":" + accountKind + ":" + accountName }
}

public struct RepositoryPermissionInspection: Codable, Sendable {
    public let schemaVersion: Int
    public let repositoryURL: String
    public let repositoryName: String
    public let path: String
    public let version: String
    public let writesEnabled: Bool
    public let writeDisabledReason: String?
    public let accounts: [RepositoryPermissionAccount]
    public let rules: [RepositoryPermissionRule]
    public let scopeDescription: String
}

public struct RepositoryPermissionReview: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let reviewId: String
    public let expiresAt: String
    public let repositoryURL: String
    public let repositoryName: String
    public let path: String
    public let accountKind: String
    public let accountName: String
    public let oldAccess: RepositoryPermissionAccess?
    public let newAccess: RepositoryPermissionAccess
    public let scopeDescription: String
    public let version: String

    public var expiry: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: expiresAt) ?? ISO8601DateFormatter().date(from: expiresAt)
    }
}

public struct RepositoryPermissionReceipt: Codable, Sendable {
    public let schemaVersion: Int
    public let operationId: String
    public let status: String
    public let code: String
}

public enum RepositoryPermissionError: LocalizedError {
    case invalidEndpoint, invalidToken, invalidResponse, server(String), transport, uncertain(String)
    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "管理接口须为完整 HTTPS 地址，不能包含账号、密码、查询参数或相对路径段。"
        case .invalidToken: return "请输入管理员为管理接口配置的独立访问令牌。"
        case .invalidResponse: return "管理接口返回的数据不完整或与当前审阅范围不符，请重新读取。"
        case .transport: return "无法连接权限管理接口。请检查内网连接、HTTPS 地址和证书信任。"
        case .uncertain(let id): return "授权结果尚未确认，操作编号：\(id)。请查询结果并重新读取权限，勿重复授权。"
        case .server(let code):
            let descriptions = [
                "UNAUTHORIZED": "管理令牌无效，请核对管理接口配置。", "FORBIDDEN": "当前来源或仓库未获管理接口授权。",
                "AUTHENTICATION_REQUIRED": "管理令牌无效，请核对管理接口配置。",
                "CLIENT_NOT_ALLOWED": "当前客户端地址不在管理接口允许的来源中。",
                "STATE_CHANGED": "权限或账号列表已发生变化，请重新读取后审阅。",
                "AUTHENTICATION_MODE_UNSUPPORTED": "管理接口仅适用于已确认的 Subversion 本地认证模式。",
                "VERSION_UNSUPPORTED": "服务器版本与已确认的 VisualSVN 4.0.1 适配不一致。",
                "NO_EXPLICIT_RULE": "此账号在当前路径没有显式规则，无需移除。",
                "WRITES_DISABLED": "服务器当前只允许查看权限，须先完成隔离仓库验证并由管理员启用写入。",
                "SCOPE_NOT_ALLOWED": "当前仓库或目录不在服务器允许管理的范围中。",
                "REPOSITORY_NOT_ALLOWED": "当前仓库不在服务器允许管理的范围中。",
                "SNAPSHOT_CHANGED": "权限或账号列表已发生变化，请重新读取后审阅。",
                "REVIEW_EXPIRED": "本次授权确认已过期，请重新生成审阅。",
                "ACCOUNT_NOT_FOUND": "该用户或组已不存在，请重新读取账号列表。",
                "OPERATION_NOT_FOUND": "服务器未找到该操作回执。仍不能据此认定授权未发生，请刷新并由管理员核对。",
                "UNSUPPORTED_SCHEMA": "服务器管理接口版本不兼容。", "REVIEW_NOT_FOUND": "未找到授权审阅，请重新读取并审阅。"
            ]
            return descriptions[code] ?? "权限管理接口未完成操作（\(Self.safeCode(code))）。请由管理员核对服务端状态。"
        }
    }
    private static func safeCode(_ code: String) -> String {
        code.count <= 64 && code.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "_") } ? code : "SERVICE_ERROR"
    }
}

public enum RepositoryPermissionEndpoint {
    public static func validated(_ text: String) throws -> URL {
        guard var c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme?.lowercased() == "https", let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.port == nil || (1...65535).contains(c.port!),
              !c.percentEncodedPath.contains("\\") else { throw RepositoryPermissionError.invalidEndpoint }
        for part in c.percentEncodedPath.split(separator: "/") {
            guard let value = String(part).removingPercentEncoding, value != ".", value != "..",
                  !value.contains("/"), !value.contains("\\"), !value.contains("%") else { throw RepositoryPermissionError.invalidEndpoint }
        }
        c.scheme = "https"; c.host = host.lowercased()
        if c.port == 443 { c.port = nil }
        if !c.percentEncodedPath.hasSuffix("/") { c.percentEncodedPath += "/" }
        guard let url = c.url else { throw RepositoryPermissionError.invalidEndpoint }
        return url
    }
}

public struct RepositoryPermissionHTTPResponse: Sendable {
    public let status: Int
    public let data: Data
    public init(status: Int, data: Data) { self.status = status; self.data = data }
}

public protocol RepositoryPermissionTransport: Sendable {
    func send(_ request: URLRequest) async throws -> RepositoryPermissionHTTPResponse
}

private final class PermissionRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public final class RepositoryPermissionNetwork: RepositoryPermissionTransport, @unchecked Sendable {
    private let session: URLSession
    private let policy = PermissionRedirectPolicy()
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 45
        configuration.httpMaximumConnectionsPerHost = 1
        session = URLSession(configuration: configuration)
    }
    deinit { session.invalidateAndCancel() }
    public func send(_ request: URLRequest) async throws -> RepositoryPermissionHTTPResponse {
        let (bytes, response) = try await session.bytes(for: request, delegate: policy)
        guard let response = response as? HTTPURLResponse, response.url == request.url,
              response.expectedContentLength <= 2_097_152 else { throw RepositoryPermissionError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            if data.count & 4095 == 0 { try Task.checkCancellation() }
            guard data.count < 2_097_152 else { throw RepositoryPermissionError.invalidResponse }
            data.append(byte)
        }
        return .init(status: response.statusCode, data: data)
    }
}

/// All network work is asynchronous; a failed apply is never replayed.
public actor RepositoryPermissionClient {
    private struct ServiceError: Decodable { let code: String }
    public nonisolated let endpoint: URL
    private let token: String
    private let transport: any RepositoryPermissionTransport
    private var reviews: [String: RepositoryPermissionReview] = [:]
    private var usedOperations = Set<UUID>()
    public init(endpoint: String, token: String, transport: any RepositoryPermissionTransport = RepositoryPermissionNetwork()) throws {
        self.endpoint = try RepositoryPermissionEndpoint.validated(endpoint)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=_-")
        guard (43...256).contains(token.count), token.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw RepositoryPermissionError.invalidToken
        }
        self.token = token; self.transport = transport
    }

    public func inspect(repositoryURL: String) async throws -> RepositoryPermissionInspection {
        let target = try RepositoryCredentialScope.canonicalURL(repositoryURL)
        let result: RepositoryPermissionInspection = try await request("inspect", body: ["repositoryURL": target])
        guard result.schemaVersion == 1, try RepositoryCredentialScope.canonicalURL(result.repositoryURL) == target,
              !result.repositoryName.isEmpty, Self.validPath(result.path), !result.version.isEmpty, result.version.count <= 128,
              result.accounts.count <= 20_000, result.rules.count <= 20_000,
              Set(result.accounts.map(\.id)).count == result.accounts.count,
              result.accounts.allSatisfy({ ["user", "group"].contains($0.kind) && !$0.name.isEmpty }),
              Set(result.rules.map(\.id)).count == result.rules.count,
              result.rules.allSatisfy({
                  ["user", "group", "everyone"].contains($0.accountKind) && !$0.accountName.isEmpty &&
                  $0.access != .removeExplicit && Self.validPath($0.sourcePath) &&
                  ($0.sourcePath == "/" || result.path == $0.sourcePath || result.path.hasPrefix($0.sourcePath + "/")) &&
                  $0.isInherited == ($0.sourcePath != result.path)
              }) else {
            throw RepositoryPermissionError.invalidResponse
        }
        return result
    }

    public func prepare(inspection: RepositoryPermissionInspection, account: RepositoryPermissionAccount,
                        access: RepositoryPermissionAccess, now: Date = Date()) async throws -> RepositoryPermissionReview {
        guard inspection.writesEnabled, inspection.accounts.contains(account) else { throw RepositoryPermissionError.server("WRITES_DISABLED") }
        let result: RepositoryPermissionReview = try await request("prepare", body: [
            "repositoryURL": inspection.repositoryURL, "accountKind": account.kind, "accountName": account.name,
            "access": access.rawValue, "expectedVersion": inspection.version
        ])
        let previous = inspection.rules.first { !$0.isInherited && $0.accountKind == account.kind && $0.accountName == account.name }?.access
        guard result.schemaVersion == 1, !result.reviewId.isEmpty, result.reviewId.count <= 128,
              result.repositoryURL == inspection.repositoryURL, result.repositoryName == inspection.repositoryName,
              result.path == inspection.path, result.accountKind == account.kind, result.accountName == account.name,
              result.newAccess == access, result.oldAccess == previous, result.version == inspection.version,
              let expiry = result.expiry, expiry > now, expiry.timeIntervalSince(now) <= 900 else {
            throw RepositoryPermissionError.invalidResponse
        }
        reviews = reviews.filter { ($0.value.expiry ?? .distantPast) > now }
        reviews[result.reviewId] = result
        return result
    }

    public func apply(_ review: RepositoryPermissionReview, operationId: UUID) async throws -> RepositoryPermissionReceipt {
        guard let expiry = review.expiry, expiry > Date() else { throw RepositoryPermissionError.server("REVIEW_EXPIRED") }
        guard reviews[review.reviewId] == review, !usedOperations.contains(operationId) else { throw RepositoryPermissionError.invalidResponse }
        reviews.removeValue(forKey: review.reviewId); usedOperations.insert(operationId)
        do {
            let result: RepositoryPermissionReceipt = try await request("apply", body: ["reviewId": review.reviewId, "operationId": operationId.uuidString])
            try validate(result, operationId: operationId)
            return result
        } catch { throw RepositoryPermissionError.uncertain(operationId.uuidString) }
    }

    public func status(operationId: UUID) async throws -> RepositoryPermissionReceipt {
        let result: RepositoryPermissionReceipt = try await request("status", body: ["operationId": operationId.uuidString])
        try validate(result, operationId: operationId)
        return result
    }

    private func validate(_ receipt: RepositoryPermissionReceipt, operationId: UUID) throws {
        guard receipt.schemaVersion == 1, UUID(uuidString: receipt.operationId) == operationId,
              ["confirmed", "unknown", "pending", "rejected"].contains(receipt.status),
              !receipt.code.isEmpty, receipt.code.count <= 64,
              receipt.code.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "_") }) else { throw RepositoryPermissionError.invalidResponse }
    }

    private static func validPath(_ path: String) -> Bool {
        path == "/" || (path.hasPrefix("/") && !path.hasSuffix("/") && !path.contains("\\") &&
            !path.contains("//") && !path.contains(where: { $0.isASCIIControl }) &&
            path.split(separator: "/").allSatisfy { $0 != "." && $0 != ".." })
    }

    private func request<T: Decodable>(_ action: String, body: [String: String]) async throws -> T {
        try Task.checkCancellation()
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/" + action))
        request.httpMethod = "POST"; request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        let response: RepositoryPermissionHTTPResponse
        do { response = try await transport.send(request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw RepositoryPermissionError.transport }
        try Task.checkCancellation()
        guard response.data.count <= 2_097_152 else { throw RepositoryPermissionError.invalidResponse }
        guard response.status == 200 else {
            let code = (try? JSONDecoder().decode(ServiceError.self, from: response.data).code) ?? "HTTP_\(response.status)"
            throw RepositoryPermissionError.server(code)
        }
        guard let value = try? JSONDecoder().decode(T.self, from: response.data) else { throw RepositoryPermissionError.invalidResponse }
        return value
    }
}

private extension Character {
    var isASCIIControl: Bool { unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }
}

public enum RepositoryPermissionTokenStore {
    private static func query(_ endpoint: URL) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.mky.svnmanager.permissions.v1",
         kSecAttrAccount as String: endpoint.absoluteString, kSecAttrSynchronizable as String: false]
    }
    public static func load(endpoint: URL) throws -> String? {
        var request = query(endpoint); request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw SVNError.invalid("无法读取管理接口钥匙串令牌（状态码 \(status)）。")
        }
        return value
    }
    public static func save(_ token: String, endpoint: URL) throws {
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrLabel as String: "SVN 管理 · 权限管理接口"]
        var status = SecItemUpdate(query(endpoint) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query(endpoint).merging(attributes) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw SVNError.invalid("无法保存管理接口令牌到钥匙串（状态码 \(status)）。") }
    }
}
