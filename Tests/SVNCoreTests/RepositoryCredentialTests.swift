import Foundation
import SVNCore

struct RepositoryCredentialTests {
    func testScopeCanonicalizesOriginAndRepositoryRoot() throws {
        try expect(try RepositoryCredentialScope.canonicalURL("HTTPS://SVN.Example.invalid:443/repos/alpha/") ==
                   "https://svn.example.invalid/repos/alpha")
        try expect(try RepositoryCredentialScope.canonicalURL("http://SVN.Example.invalid:80/repos/alpha") ==
                   "http://svn.example.invalid/repos/alpha")
        try expect(try RepositoryCredentialScope.canonicalURL("svn://SVN.Example.invalid:3690/repos/alpha/") ==
                   "svn://svn.example.invalid/repos/alpha")
        try expect(try RepositoryCredentialScope.canonicalURL("https://svn.example.invalid:8443/repos/alpha") ==
                   "https://svn.example.invalid:8443/repos/alpha")
        try expect(RepositoryCredentialScope.contains(
            root: "HTTPS://SVN.Example.invalid:443/repos/alpha/",
            url: "https://svn.example.invalid/repos/alpha/trunk/目录"))
    }

    func testScopeRejectsDotPathSegmentsAndMatchesSegmentBoundaries() throws {
        for path in ["/repos/./alpha", "/repos/../alpha", "/repos/%2e/alpha",
                     "/repos/%2E%2e/alpha", "/repos/.%2e/alpha", "/repos/%2e./alpha",
                     "/repos/alpha%2f..%2fbeta", "/repos/alpha%2F../beta"] {
            try expectThrows(SVNError.self) {
                try RepositoryCredentialScope.canonicalURL("https://svn.example.invalid" + path)
            }
        }
        try expect(RepositoryCredentialScope.contains(
            root: "https://svn.example.invalid/repos/alpha", url: "https://svn.example.invalid/repos/alpha"))
        try expect(!RepositoryCredentialScope.contains(
            root: "https://svn.example.invalid/repos/alpha", url: "https://svn.example.invalid/repos/alphabet/trunk"))
        try expect(!RepositoryCredentialScope.contains(
            root: "https://svn.example.invalid/repos/alpha", url: "https://svn.example.invalid/repos/alpha/../beta"))
        try expect(!RepositoryCredentialScope.contains(
            root: "https://svn.example.invalid/repos/alpha", url: "https://svn.example.invalid/repos/Alpha/trunk"))
    }

    func testCredentialsStayWithinTheRepositoryOriginAndPath() throws {
        let storage = MemoryRepositoryCredentialStorage()
        let cache = RepositoryCredentialCache(storage: storage)
        let credentials = SVNCredentials(username: "alpha-user", password: "fixture-alpha-password")
        try cache.remember(credentials, repositoryRoot: "HTTPS://SVN.Example.invalid:443/repos/alpha/")

        try expectCredentials(try cache.credentials(for: "https://svn.example.invalid/repos/alpha/trunk/src"), credentials)
        try expectCredentials(try cache.credentials(for: "https://svn.example.invalid:443/repos/alpha/branches/test"), credentials)
        for url in ["https://other.example.invalid/repos/alpha/trunk",
                    "http://svn.example.invalid/repos/alpha/trunk",
                    "svn://svn.example.invalid/repos/alpha/trunk",
                    "https://svn.example.invalid:8443/repos/alpha/trunk",
                    "https://svn.example.invalid/repos/beta/trunk",
                    "https://svn.example.invalid/repos/alphabet/trunk"] {
            try expect(try cache.credentials(for: url) == nil, "Credentials must remain inside their repository scope")
        }
        try expect(storage.repositoryRoots == ["https://svn.example.invalid/repos/alpha"])
    }

    func testNewCacheLoadsSavedCredentialsForRepositoryChildren() throws {
        let storage = MemoryRepositoryCredentialStorage()
        let credentials = SVNCredentials(username: "saved-user", password: "fixture-saved-password")
        let firstSession = RepositoryCredentialCache(storage: storage)
        try firstSession.remember(credentials, repositoryRoot: "https://svn.example.invalid/repos/alpha")

        let newSession = RepositoryCredentialCache(storage: storage)
        try expectCredentials(try newSession.credentials(for: "https://svn.example.invalid/repos/alpha/trunk"), credentials)
        try expect(storage.loadedRoots.contains("https://svn.example.invalid/repos/alpha"))
        try expect(try newSession.credentials(for: "https://svn.example.invalid/repos/beta") == nil)
    }

    func testFailedPersistenceKeepsOnlySessionCredentials() throws {
        let storage = MemoryRepositoryCredentialStorage()
        storage.shouldFailSave = true
        let cache = RepositoryCredentialCache(storage: storage)
        let credentials = SVNCredentials(username: "session-user", password: "fixture-session-password")
        try expectThrows(CredentialStorageFixtureError.self) {
            try cache.remember(credentials, repositoryRoot: "https://svn.example.invalid/repos/alpha")
        }
        try expect(storage.repositoryRoots.isEmpty, "A failed save must not advertise a persistent repository root")
        try expectCredentials(try cache.credentials(for: "https://svn.example.invalid/repos/alpha/trunk"), credentials)
        try expect(try cache.credentials(for: "https://svn.example.invalid/repos/beta") == nil)
        let newSession = RepositoryCredentialCache(storage: storage)
        try expect(try newSession.credentials(for: "https://svn.example.invalid/repos/alpha/trunk") == nil)
    }

    func testMostSpecificRepositoryRootWinsInBothSessionAndStorage() throws {
        let storage = MemoryRepositoryCredentialStorage()
        let broad = SVNCredentials(username: "broad-user", password: "fixture-broad-password")
        let specific = SVNCredentials(username: "specific-user", password: "fixture-specific-password")
        let cache = RepositoryCredentialCache(storage: storage)
        try cache.remember(specific, repositoryRoot: "https://svn.example.invalid/repos/alpha/nested")
        try cache.remember(broad, repositoryRoot: "https://svn.example.invalid/repos/alpha")
        for session in [cache, RepositoryCredentialCache(storage: storage)] {
            try expectCredentials(try session.credentials(for: "https://svn.example.invalid/repos/alpha/nested/trunk"), specific)
            try expectCredentials(try session.credentials(for: "https://svn.example.invalid/repos/alpha/trunk"), broad)
            try expectCredentials(try session.credentials(for: "https://svn.example.invalid/repos/alpha/nested-sibling"), broad)
        }
    }

    func testOnlyAuthenticationErrorsRequestCredentialsAgain() throws {
        for code in ["E170001", "E215004", "E215003"] {
            try expect(SVNError.command(1, "svn: \(code): Authentication failed").isAuthenticationFailure)
        }
        for message in ["svn: E170013: Unable to connect to a repository",
                        "svn: E230001: Server SSL certificate verification failed",
                        "svn: E175013: Access to the repository is forbidden",
                        "svn: E160013: File not found"] {
            try expect(!SVNError.command(1, message).isAuthenticationFailure)
        }
        try expect(!SVNError.invalid("Authentication failed").isAuthenticationFailure)
    }

    func testAuthenticationClassificationSurvivesPasswordRedaction() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SVNCredentialChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("authentication-failure")
        let receipt = directory.appendingPathComponent("authentication-failure.receipt")
        let script = """
        #!/bin/sh
        for argument in "$@"; do
            if [ "$argument" = svn ]; then
                printf '%s\\n' password-in-arguments >> "$0.receipt"
            fi
        done
        IFS= read -r entered_password
        if [ "$entered_password" = svn ]; then
            printf '%s\\n' password-from-stdin >> "$0.receipt"
        fi
        printf '%s\\n' "private-stdout-fixture $entered_password"
        printf '%s\\n' "private-stdin-fixture $entered_password" >&2
        printf '%s\\n' 'svn: E215004: Authentication failed svn' >&2
        exit 1
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = SVNClient(executablePath: executable.path,
                               credentials: SVNCredentials(username: "fixture-user", password: "svn"))
        do {
            _ = try await client.repositoryInfo(url: "https://svn.example.invalid/repos/alpha")
            throw CheckFailure.failed("A failed repository identity request must report its authentication error")
        } catch let error as SVNError {
            try expect(error.isAuthenticationFailure, "Redaction must preserve authentication classification")
            let description = error.localizedDescription
            try expect(!description.contains("svn"), "A dummy password must be redacted from the displayed error")
            try expect(description.contains("[已隐藏]"))
            try expect(!description.contains("private-stdout-fixture"))
            try expect(!description.contains("private-stdin-fixture"))
        }
        let calls = try String(contentsOf: receipt, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        try expect(calls == ["password-from-stdin"], "Passwords must be supplied through stdin without appearing in arguments")
    }

    func testRepositoryInfoUsesServerRootAndUUIDWithoutWorkingCopyFields() throws {
        let identity = try SVNXML.parseRepositoryInfo(Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <info><entry kind="dir" path="trunk" revision="17">
          <url>https://svn.example.invalid/repos/alpha/trunk</url>
          <repository>
            <root>https://svn.example.invalid/repos/alpha</root>
            <uuid>30e206d7-0935-4a2e-9b89-c123456789ab</uuid>
          </repository>
        </entry></info>
        """.utf8))
        try expect(identity.rootURL == "https://svn.example.invalid/repos/alpha")
        try expect(identity.uuid == "30e206d7-0935-4a2e-9b89-c123456789ab")

        for repository in ["", "<root>https://svn.example.invalid/repos/alpha</root>",
                           "<uuid>fixture-uuid</uuid>", "<root> </root><uuid>fixture-uuid</uuid>",
                           "<root>https://svn.example.invalid/repos/alpha</root><uuid> </uuid>"] {
            let data = Data("<info><entry><repository>\(repository)</repository></entry></info>".utf8)
            try expectThrows(SVNError.self) { try SVNXML.parseRepositoryInfo(data) }
        }
        try expectThrows(SVNError.self) { try SVNXML.parseRepositoryInfo(Data("<lists/>".utf8)) }
    }
}

private final class MemoryRepositoryCredentialStorage: RepositoryCredentialStorage {
    private var values: [String: SVNCredentials] = [:]
    private(set) var loadedRoots: [String] = []
    var shouldFailSave = false
    var repositoryRoots: [String] { values.keys.sorted() }

    func load(for root: String) throws -> SVNCredentials? {
        loadedRoots.append(root)
        return values[root]
    }

    func save(_ credentials: SVNCredentials, for root: String) throws {
        if shouldFailSave { throw CredentialStorageFixtureError.writeDenied }
        values[root] = credentials
    }
}

private enum CredentialStorageFixtureError: Error {
    case writeDenied
}

private func expectCredentials(_ actual: @autoclosure () throws -> SVNCredentials?,
                               _ expected: SVNCredentials,
                               file: StaticString = #filePath, line: UInt = #line) throws {
    let value = try require(actual(), "Expected scoped repository credentials", file: file, line: line)
    try expect(value.username == expected.username && value.password == expected.password,
               "The scoped credential identity must match", file: file, line: line)
}
