import Foundation
import Security

public enum RepositoryCredentialScope {
    public static func canonicalURL(_ text: String) throws -> String {
        let url = try SVNLocation.validated(text)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            throw SVNError.invalid("仓库地址无法解析。")
        }
        let segments = components.percentEncodedPath.split(separator: "/")
        guard segments.allSatisfy({ segment in
            let decoded = String(segment).removingPercentEncoding ?? String(segment)
            return decoded != "." && decoded != ".." && !decoded.contains("\\") && !decoded.contains("/")
        }) else { throw SVNError.invalid("仓库地址不能包含相对路径段，请输入完整规范地址。") }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        let defaultPort = ["https": 443, "http": 80, "svn": 3690, "svn+ssh": 22][components.scheme ?? ""]
        if components.port == defaultPort { components.port = nil }
        var path = components.percentEncodedPath
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))
        path = path.split(separator: "/", omittingEmptySubsequences: false).map {
            let decoded = String($0).removingPercentEncoding ?? String($0)
            return decoded.addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0)
        }.joined(separator: "/")
        while path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path
        guard let result = components.string else { throw SVNError.invalid("仓库地址无法解析。") }
        return result
    }

    public static func contains(root: String, url: String) -> Bool {
        guard let root = try? canonicalURL(root), let target = try? canonicalURL(url) else { return false }
        return root == target || target.hasPrefix(root + "/")
    }

    public static func requiresPassword(_ url: String) -> Bool {
        ["http", "https", "svn"].contains(URL(string: url)?.scheme?.lowercased() ?? "")
    }
}

public protocol RepositoryCredentialStorage: AnyObject {
    var repositoryRoots: [String] { get }
    func load(for root: String) throws -> SVNCredentials?
    func save(_ credentials: SVNCredentials, for root: String) throws
}

/// Stores only repository scopes in preferences; credentials remain in Keychain.
public final class KeychainRepositoryCredentialStorage: RepositoryCredentialStorage {
    private let service: String
    private let defaults: UserDefaults
    private let rootsKey: String

    public init(service: String = "com.mky.svnmanager.repository-credentials.v1",
                defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        rootsKey = service + ".roots"
    }

    public var repositoryRoots: [String] { defaults.stringArray(forKey: rootsKey) ?? [] }

    private func query(_ root: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: root,
         kSecAttrSynchronizable as String: false]
    }

    public func load(for root: String) throws -> SVNCredentials? {
        var request = query(root)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SVNError.invalid("无法读取 macOS 钥匙串中的仓库账号（状态码 \(status)）。请确认登录钥匙串已解锁并允许应用访问。")
        }
        guard let values = try? JSONDecoder().decode(StoredCredentials.self, from: data),
              !values.username.isEmpty, !values.password.isEmpty else {
            throw SVNError.invalid("钥匙串中的仓库账号记录无效，请重新输入账号密码。")
        }
        return SVNCredentials(username: values.username, password: values.password)
    }

    public func save(_ credentials: SVNCredentials, for root: String) throws {
        let root = try RepositoryCredentialScope.canonicalURL(root)
        let data = try JSONEncoder().encode(StoredCredentials(username: credentials.username, password: credentials.password))
        let request = query(root)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrLabel as String: "SVN 管理 · " + root]
        var status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(request.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw SVNError.invalid("无法将仓库账号保存到 macOS 钥匙串（状态码 \(status)）。本次运行仍可使用，重启后可能需要重新输入。")
        }
        var roots = repositoryRoots.filter { $0 != root }
        roots.append(root)
        defaults.set(roots, forKey: rootsKey)
    }

    private struct StoredCredentials: Codable {
        let username: String
        let password: String
    }
}

public final class RepositoryCredentialCache {
    private let storage: any RepositoryCredentialStorage
    private var session: [String: SVNCredentials] = [:]
    public init(storage: any RepositoryCredentialStorage) { self.storage = storage }

    public func credentials(for url: String) throws -> SVNCredentials? {
        let target = try RepositoryCredentialScope.canonicalURL(url)
        let roots = Set(storage.repositoryRoots + Array(session.keys))
            .filter { RepositoryCredentialScope.contains(root: $0, url: target) }
            .sorted { $0.count > $1.count }
        // Do not fall back to a broader scope when a specific scope lost its Keychain item.
        guard let root = roots.first else { return nil }
        if let value = session[root] { return value }
        if let value = try storage.load(for: root) { session[root] = value; return value }
        return nil
    }

    public func remember(_ credentials: SVNCredentials, repositoryRoot: String) throws {
        let root = try RepositoryCredentialScope.canonicalURL(repositoryRoot)
        session[root] = credentials
        try storage.save(credentials, for: root)
    }
}
