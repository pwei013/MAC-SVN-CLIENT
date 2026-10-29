import Foundation
import SVNCore

struct RepositoryPermissionTests {
    private let endpoint = "https://management.example.invalid:8443/svn-management/"
    private let target = "https://svn.example.invalid/svn/Repo/trunk"
    private let fixtureToken = String(repeating: "fixture-token-", count: 4)

    func testEndpointAndTokenBoundaries() throws {
        try expect(try RepositoryPermissionEndpoint.validated(" HTTPS://Management.Example.invalid:443/svn-management ").absoluteString ==
                   "https://management.example.invalid/svn-management/")
        try expect(try RepositoryPermissionEndpoint.validated("https://management.example.invalid:8443/").port == 8443)
        for value in ["http://management.example.invalid/", "https://user@management.example.invalid/",
                      "https://user:fixture@management.example.invalid/", "https://management.example.invalid/?token=fixture",
                      "https://management.example.invalid/#fragment", "https://management.example.invalid/a/../b",
                      "https://management.example.invalid/%2e%2e/b", "https://management.example.invalid/a%2Fb",
                      "https://management.example.invalid/a%5Cb", "https://management.example.invalid/%252e%252e/",
                      "https://management.example.invalid:0/", "https://management.example.invalid:65536/"] {
            try expectThrows(RepositoryPermissionError.self) { try RepositoryPermissionEndpoint.validated(value) }
        }
        for token in ["", "short", String(repeating: "a", count: 42), String(repeating: "a", count: 257),
                      String(repeating: "a", count: 43) + "\r\nInjected: value", String(repeating: "a", count: 43) + ":",
                      String(repeating: "a", count: 43) + " ", String(repeating: "a", count: 43) + "中文"] {
            try expectThrows(RepositoryPermissionError.self) {
                try RepositoryPermissionClient(endpoint: endpoint, token: token, transport: PermissionFixtureTransport([]))
            }
        }
        for count in [43, 256] {
            _ = try RepositoryPermissionClient(endpoint: endpoint, token: String(repeating: "a", count: count), transport: PermissionFixtureTransport([]))
        }
    }

    func testInspectionScopeAndMalformedResponses() async throws {
        let transport = PermissionFixtureTransport([.response(200, try json(inspection()))])
        let client = try makeClient(transport)
        let result = try await client.inspect(repositoryURL: "HTTPS://SVN.Example.invalid:443/svn/Repo/trunk/")
        try expect(result.path == "/trunk")
        let calls = await transport.requests
        try expect(calls.count == 1)
        try expect(calls[0].url?.absoluteString == endpoint + "v1/inspect")
        try expect(calls[0].httpMethod == "POST")
        try expect(calls[0].value(forHTTPHeaderField: "Authorization") == "Bearer " + fixtureToken)
        let body = try require(calls[0].httpBody)
        let request = try JSONDecoder().decode([String: String].self, from: body)
        try expect(request == ["repositoryURL": target])
        for changes: [String: Any] in [
            ["schemaVersion": 2], ["repositoryURL": "https://elsewhere.example.invalid/svn/Repo/trunk"],
            ["repositoryURL": "https://svn.example.invalid/svn/Other/trunk"], ["path": "relative"],
            ["version": ""], ["repositoryName": ""],
            ["accounts": [["kind": "user", "name": "alice"], ["kind": "user", "name": "alice"]]],
            ["accounts": [["kind": "unknown", "name": "alice"]]],
            ["rules": [["accountKind": "user", "accountName": "alice", "access": "removeExplicit", "sourcePath": "/trunk", "isInherited": false]]]
        ] {
            var fixture = inspection(); fixture.merge(changes) { _, new in new }
            let malformed = PermissionFixtureTransport([.response(200, try json(fixture))])
            try await expectPermissionFailure { _ = try await makeClient(malformed).inspect(repositoryURL: target) }
        }
        for data in [Data("not json".utf8), Data("{\"schemaVersion\":1}".utf8)] {
            let malformed = PermissionFixtureTransport([.response(200, data)])
            try await expectPermissionFailure { _ = try await makeClient(malformed).inspect(repositoryURL: target) }
        }
    }

    func testInspectionRejectsForeignAndDuplicateRules() async throws {
        for rules: [[String: Any]] in [
            [["accountKind": "user", "accountName": "alice", "access": "read", "sourcePath": "/other", "isInherited": true]],
            [["accountKind": "user", "accountName": "alice", "access": "read", "sourcePath": "/trunk/child", "isInherited": true]],
            [["accountKind": "user", "accountName": "alice", "access": "read", "sourcePath": "/trunk", "isInherited": true]],
            [["accountKind": "user", "accountName": "alice", "access": "read", "sourcePath": "/", "isInherited": false]],
            [rule(), rule()]
        ] {
            var fixture = inspection(); fixture["rules"] = rules
            let transport = PermissionFixtureTransport([.response(200, try json(fixture))])
            try await expectPermissionFailure { _ = try await makeClient(transport).inspect(repositoryURL: target) }
        }
    }

    func testPreparePinsReviewedAccountScopeAndVersion() async throws {
        let transport = PermissionFixtureTransport([.response(200, try json(inspection())), .response(200, try json(review()))])
        let client = try makeClient(transport)
        let current = try await client.inspect(repositoryURL: target)
        let account = try require(current.accounts.first)
        let prepared = try await client.prepare(inspection: current, account: account, access: .write)
        try expect(prepared.newAccess == .write && prepared.oldAccess == .read)
        let calls = await transport.requests
        let sent = try JSONDecoder().decode([String: String].self, from: require(calls.last?.httpBody))
        try expect(sent["expectedVersion"] == current.version && sent["accountName"] == "alice" && sent["access"] == "write")
        for changes: [String: Any] in [
            ["repositoryURL": "https://svn.example.invalid/svn/Repo/other"], ["repositoryName": "Other"],
            ["path": "/other"], ["accountKind": "group"], ["accountName": "bob"], ["newAccess": "read"],
            ["oldAccess": "none"], ["version": "changed"], ["reviewId": ""],
            ["expiresAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-10))],
            ["expiresAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(3_600))]
        ] {
            var invalid = review(); invalid.merge(changes) { _, new in new }
            let bad = PermissionFixtureTransport([.response(200, try json(inspection())), .response(200, try json(invalid))])
            let badClient = try makeClient(bad)
            let snapshot = try await badClient.inspect(repositoryURL: target)
            try await expectPermissionFailure {
                _ = try await badClient.prepare(inspection: snapshot, account: require(snapshot.accounts.first), access: .write)
            }
        }
    }

    func testReadOnlyModeNeverPreparesOrApplies() async throws {
        var fixture = inspection(); fixture["writesEnabled"] = false
        let transport = PermissionFixtureTransport([.response(200, try json(fixture))])
        let client = try makeClient(transport)
        let current = try await client.inspect(repositoryURL: target)
        try await expectPermissionFailure {
            _ = try await client.prepare(inspection: current, account: require(current.accounts.first), access: .write)
        }
        let countAfterPrepare = await transport.requestCount
        try expect(countAfterPrepare == 1, "Read-only server must never receive prepare")
        var expired = review(); expired["expiresAt"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-1))
        let plan = try JSONDecoder().decode(RepositoryPermissionReview.self, from: json(expired))
        try await expectPermissionFailure { _ = try await client.apply(plan, operationId: UUID()) }
        let countAfterApply = await transport.requestCount
        try expect(countAfterApply == 1, "Expired review must never reach apply")
    }

    func testApplyFailureNeverReplaysAndStatusUsesSameOperation() async throws {
        let id = UUID()
        let transport = PermissionFixtureTransport([
            .response(200, try json(inspection())), .response(200, try json(review())),
            .failure, .response(200, try json(["schemaVersion": 1, "operationId": id.uuidString, "status": "confirmed", "code": "VERIFIED"]))
        ])
        let client = try makeClient(transport)
        let current = try await client.inspect(repositoryURL: target)
        let plan = try await client.prepare(inspection: current, account: require(current.accounts.first), access: .write)
        do {
            _ = try await client.apply(plan, operationId: id)
            throw CheckFailure.failed("A failed apply must require result verification")
        } catch let error as RepositoryPermissionError {
            guard case .uncertain(let operation) = error else { throw CheckFailure.failed("Apply failed without uncertain-operation classification") }
            try expect(operation == id.uuidString)
            try expect(!error.localizedDescription.contains("private-fixture-error"))
        }
        let afterApply = await transport.requestCount
        try expect(afterApply == 3, "Failed apply must be sent exactly once")
        try await expectPermissionFailure { _ = try await client.apply(plan, operationId: id) }
        let afterDuplicate = await transport.requestCount
        try expect(afterDuplicate == 3, "A consumed review and operation identifier must never send another apply")
        let receipt = try await client.status(operationId: id)
        try expect(receipt.status == "confirmed")
        let calls = await transport.requests
        try expect(calls.map { $0.url?.lastPathComponent } == ["inspect", "prepare", "apply", "status"])
        for call in calls.suffix(2) {
            let body = try JSONDecoder().decode([String: String].self, from: require(call.httpBody))
            try expect(body["operationId"] == id.uuidString)
        }
        for changes: [String: Any] in [
            ["operationId": UUID().uuidString], ["status": "success"], ["schemaVersion": 2],
            ["code": "private-fixture-error\n" + fixtureToken]
        ] {
            var receipt: [String: Any] = ["schemaVersion": 1, "operationId": id.uuidString, "status": "confirmed", "code": "VERIFIED"]
            receipt.merge(changes) { _, new in new }
            let mismatched = PermissionFixtureTransport([.response(200, try json(receipt))])
            try await expectPermissionFailure { _ = try await makeClient(mismatched).status(operationId: id) }
        }
    }

    func testServerFailuresNeverDisplayBodiesOrSecrets() async throws {
        for body in [try json(["code": "UNAUTHORIZED", "detail": fixtureToken]),
                     try json(["code": "private-fixture-error: " + fixtureToken]),
                     Data(("private-fixture-error " + fixtureToken).utf8)] {
            let transport = PermissionFixtureTransport([.response(403, body)])
            do {
                _ = try await makeClient(transport).inspect(repositoryURL: target)
                throw CheckFailure.failed("Server rejection must fail")
            } catch let error as RepositoryPermissionError {
                try expect(!error.localizedDescription.contains(fixtureToken))
                try expect(!error.localizedDescription.contains("private-fixture-error"))
            }
        }
        let transport = PermissionFixtureTransport([.failure])
        do { _ = try await makeClient(transport).inspect(repositoryURL: target); throw CheckFailure.failed("Transport must fail") }
        catch let error as RepositoryPermissionError { try expect(!error.localizedDescription.contains("private-fixture-error")) }
    }

    func testCancellationStaysReadOnlyAndDoesNotRetry() async throws {
        let transport = PermissionFixtureTransport([.suspend])
        let client = try makeClient(transport)
        let task = Task { try await client.inspect(repositoryURL: target) }
        for _ in 0..<100 {
            if await transport.requestCount > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        do { _ = try await task.value; throw CheckFailure.failed("Cancelled read must throw") }
        catch is CancellationError { }
        let count = await transport.requestCount
        try expect(count == 1)
    }

    func testResponseBudgetIsEnforced() async throws {
        let limit = 2_097_152
        var fixture = inspection(); fixture["padding"] = ""
        let overhead = try json(fixture).count
        fixture["padding"] = String(repeating: "x", count: limit - overhead)
        let exact = try json(fixture)
        try expect(exact.count == limit)
        let accepted = PermissionFixtureTransport([.response(200, exact)])
        _ = try await makeClient(accepted).inspect(repositoryURL: target)
        fixture["padding"] = String(repeating: "x", count: limit - overhead + 1)
        let rejected = PermissionFixtureTransport([.response(200, try json(fixture))])
        try await expectPermissionFailure { _ = try await makeClient(rejected).inspect(repositoryURL: target) }
    }

    func testPendingReceiptReopensAndRejectsOverwriteOrWrongRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PermissionPending-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("records", isDirectory: true)
        let url = try RepositoryPermissionEndpoint.validated(endpoint)
        let otherURL = try RepositoryPermissionEndpoint.validated("https://management.example.invalid:9443/svn-management/")
        let plan = try JSONDecoder().decode(RepositoryPermissionReview.self, from: json(review()))
        let id = UUID()
        let pending = RepositoryPermissionPending(operationId: id, endpoint: url, review: plan)
        let store = RepositoryPermissionPendingStore(directory: directory)
        let absent = try await store.load(endpoint: url)
        try expect(absent == nil && !FileManager.default.fileExists(atPath: directory.path), "Reading missing pending state must not create storage")
        try await store.save(pending, endpoint: url)
        let reopened = try await RepositoryPermissionPendingStore(directory: directory).load(endpoint: url)
        let restored = try require(reopened)
        try expect(restored.operationId == id && restored.endpoint == url.absoluteString)
        try expect(restored.review.repositoryURL == target && restored.review.path == "/trunk")
        try expect(restored.review.accountKind == "user" && restored.review.accountName == "alice" && restored.review.newAccess == .write)
        let otherAbsent = try await store.load(endpoint: otherURL)
        try expect(otherAbsent == nil, "An endpoint on another port must have separate pending state")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let record = try require(files.first)
        let original = try Data(contentsOf: record)
        try await expectPendingFailure { try await store.save(pending, endpoint: url) }
        try await expectPendingFailure { try await store.save(pending, endpoint: otherURL) }
        try await expectPendingFailure { try await store.remove(endpoint: url, operationId: UUID()) }
        try expect(try Data(contentsOf: record) == original, "Refused overwrite and removal must preserve the pending record")
        let other = RepositoryPermissionPending(operationId: UUID(), endpoint: otherURL, review: plan)
        try await store.save(other, endpoint: otherURL)
        try await store.remove(endpoint: url, operationId: id)
        let removed = try await store.load(endpoint: url)
        let otherRetained = try await store.load(endpoint: otherURL)
        try expect(removed == nil && otherRetained?.operationId == other.operationId)
    }

    func testPendingCorruptAndSymlinkRecordsNeverBecomeMissing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PermissionPendingUnsafe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("records", isDirectory: true)
        let url = try RepositoryPermissionEndpoint.validated(endpoint)
        let plan = try JSONDecoder().decode(RepositoryPermissionReview.self, from: json(review()))
        let pending = RepositoryPermissionPending(operationId: UUID(), endpoint: url, review: plan)
        let store = RepositoryPermissionPendingStore(directory: directory)
        try await store.save(pending, endpoint: url)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let record = try require(files.first)
        let original = try Data(contentsOf: record)
        for data in [Data("not a pending record".utf8), Data(repeating: 65, count: 32_769)] {
            try data.write(to: record)
            try await expectPendingFailure { _ = try await store.load(endpoint: url) }
            try await expectPendingFailure { try await store.save(pending, endpoint: url) }
            try expect(try Data(contentsOf: record) == data, "An invalid record must remain available for manual verification")
        }
        try original.write(to: record)
        let foreign = root.appendingPathComponent("foreign.json")
        try original.write(to: foreign)
        try FileManager.default.removeItem(at: record)
        try FileManager.default.createSymbolicLink(at: record, withDestinationURL: foreign)
        try await expectPendingFailure { _ = try await store.load(endpoint: url) }
        try await expectPendingFailure { try await store.save(pending, endpoint: url) }
        try expect(try Data(contentsOf: foreign) == original, "A symbolic-link target must remain unchanged")
        try FileManager.default.removeItem(at: foreign)
        try await expectPendingFailure { _ = try await store.load(endpoint: url) }
        try await expectPendingFailure { try await store.save(pending, endpoint: url) }
        let danglingFile = try FileManager.default.attributesOfItem(atPath: record.path)
        try expect(danglingFile[.type] as? FileAttributeType == .typeSymbolicLink,
                   "A dangling receipt link must be refused and preserved, never treated as an absent record")
        let linkedRoot = root.appendingPathComponent("linked-records")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: directory)
        let linkedStore = RepositoryPermissionPendingStore(directory: linkedRoot)
        try await expectPendingFailure { _ = try await linkedStore.load(endpoint: url) }
        try await expectPendingFailure { try await linkedStore.save(pending, endpoint: url) }
        let danglingRoot = root.appendingPathComponent("dangling-records")
        let absentDestination = root.appendingPathComponent("missing-directory")
        try FileManager.default.createSymbolicLink(at: danglingRoot, withDestinationURL: absentDestination)
        let danglingStore = RepositoryPermissionPendingStore(directory: danglingRoot)
        try await expectPendingFailure { _ = try await danglingStore.load(endpoint: url) }
        try await expectPendingFailure { try await danglingStore.save(pending, endpoint: url) }
        try expect(!FileManager.default.fileExists(atPath: absentDestination.path), "Refusing a dangling root must not create its target")
    }

    private func inspection() -> [String: Any] {
        ["schemaVersion": 1, "repositoryURL": target, "repositoryName": "Repo", "path": "/trunk", "version": "fixture-snapshot-v1",
         "writesEnabled": true, "accounts": [["kind": "user", "name": "alice"], ["kind": "group", "name": "developers"]],
         "rules": [rule()], "scopeDescription": "Current path and inherited children; child rules retained"]
    }
    private func rule() -> [String: Any] {
        ["accountKind": "user", "accountName": "alice", "access": "read", "sourcePath": "/trunk", "isInherited": false]
    }
    private func review() -> [String: Any] {
        ["schemaVersion": 1, "reviewId": UUID().uuidString, "expiresAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(300)),
         "repositoryURL": target, "repositoryName": "Repo", "path": "/trunk", "accountKind": "user", "accountName": "alice",
         "oldAccess": "read", "newAccess": "write", "scopeDescription": "Current path and inherited children; child rules retained", "version": "fixture-snapshot-v1"]
    }
    private func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    private func makeClient(_ transport: PermissionFixtureTransport) throws -> RepositoryPermissionClient {
        try RepositoryPermissionClient(endpoint: endpoint, token: fixtureToken, transport: transport)
    }
    private func expectPermissionFailure(_ operation: () async throws -> Void) async throws {
        do { try await operation() }
        catch is RepositoryPermissionError { return }
        throw CheckFailure.failed("Expected bounded permission-management failure")
    }
    private func expectPendingFailure(_ operation: () async throws -> Void) async throws {
        do { try await operation() }
        catch is SVNError { return }
        throw CheckFailure.failed("Expected pending-receipt storage to refuse an unsafe operation")
    }
}

private actor PermissionFixtureTransport: RepositoryPermissionTransport {
    enum Step: Sendable { case response(Int, Data), failure, suspend }
    private var steps: [Step]
    private(set) var requests: [URLRequest] = []
    var requestCount: Int { requests.count }
    init(_ steps: [Step]) { self.steps = steps }
    func send(_ request: URLRequest) async throws -> RepositoryPermissionHTTPResponse {
        requests.append(request)
        guard !steps.isEmpty else { throw CheckFailure.failed("Unexpected permission request") }
        switch steps.removeFirst() {
        case let .response(status, data): return .init(status: status, data: data)
        case .failure: throw CheckFailure.failed("private-fixture-error")
        case .suspend:
            try await Task.sleep(for: .seconds(30))
            throw CheckFailure.failed("Suspended read was not cancelled")
        }
    }
}
