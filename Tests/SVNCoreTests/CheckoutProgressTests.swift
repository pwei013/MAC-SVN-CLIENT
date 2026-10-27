import Darwin
import Foundation
import SVNCore

struct CheckoutProgressTests {
    func testOverlayOverwritesSameNamesAndKeepsAllOtherFiles() async throws {
        let fixture = try CheckoutCheckFixture()
        defer { fixture.remove() }
        let tools = try fixture.localTools(), remote = try fixture.overlayRepository()
        let destination = fixture.destination
        try fixture.write("local different\n", to: destination.appendingPathComponent("same.txt"))
        try fixture.write("local unicode\n", to: destination.appendingPathComponent("目录 空格 @/文件 @.txt"))
        try fixture.write("remote nested\n", to: destination.appendingPathComponent("shared/base.txt"))
        let retained = ["keep.local": "root original\n", ".hidden-keep": "hidden original\n", "shared/extra.txt": "nested original\n"]
        for (path, value) in retained { try fixture.write(value, to: destination.appendingPathComponent(path)) }
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("empty-original"), withIntermediateDirectories: true)
        let events = CheckoutCheckBox<[CheckoutEvent]>([])
        let client = SVNClient(executablePath: tools.svn.path)
        try await client.checkoutWithProgress(url: remote, destination: destination, overwriteExisting: true) {
            event in events.modify { $0.append(event) }
        }
        try expect(try String(contentsOf: destination.appendingPathComponent("same.txt"), encoding: .utf8) == "remote same\n")
        try expect(try String(contentsOf: destination.appendingPathComponent("目录 空格 @/文件 @.txt"), encoding: .utf8) == "remote unicode\n")
        for (path, value) in retained { try expect(try String(contentsOf: destination.appendingPathComponent(path), encoding: .utf8) == value) }
        try expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("empty-original").path))
        let recorded = events.read { $0 }
        try expect(try checkoutStart(recorded) == (6, "1"))
        try expect(checkoutOutputs(recorded).last?.completed == 6 && checkoutCompletedCount(recorded) == 1)
        try expect(checkoutOutputs(recorded).flatMap(\.lines).contains { $0.hasPrefix("E    ") })
        let status = try await client.status(at: destination)
        try expect(status.allSatisfy { $0.item == "unversioned" }, "Overwritten files must match the pinned BASE")
        let second = fixture.root.appendingPathComponent("direct overlay")
        try fixture.write("keep\n", to: second.appendingPathComponent("other.txt"))
        _ = try await client.checkout(url: remote, destination: second, overwriteExisting: true)
        try expect(try String(contentsOf: second.appendingPathComponent("other.txt"), encoding: .utf8) == "keep\n")
    }

    func testOverlayRejectsTypeClashesAndSymlinksBeforeWriting() async throws {
        let fixture = try CheckoutCheckFixture()
        defer { fixture.remove() }
        let tools = try fixture.localTools(), remote = try fixture.overlayRepository()
        let outside = fixture.root.appendingPathComponent("outside")
        try fixture.write("outside must stay\n", to: outside.appendingPathComponent("base.txt"))
        for scenario in 0..<3 {
            let destination = fixture.destination.appendingPathComponent("case\(scenario)")
            try fixture.write("keep\n", to: destination.appendingPathComponent("keep.txt"))
            if scenario == 0 { try fixture.write("file blocks directory\n", to: destination.appendingPathComponent("shared")) }
            else if scenario == 1 { try fixture.write("directory blocks file\n", to: destination.appendingPathComponent("same.txt/keep.txt")) }
            else { try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("shared"), withDestinationURL: outside) }
            do {
                try await SVNClient(executablePath: tools.svn.path).checkoutWithProgress(url: remote, destination: destination, overwriteExisting: true) { _ in }
                throw CheckFailure.failed("An incompatible existing node must not be replaced")
            } catch let error as CheckFailure { throw error }
            catch { }
            try expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent(".svn").path))
            try expect(try String(contentsOf: destination.appendingPathComponent("keep.txt"), encoding: .utf8) == "keep\n")
        }
        try expect(try String(contentsOf: outside.appendingPathComponent("base.txt"), encoding: .utf8) == "outside must stay\n")
        try expect(try String(contentsOf: fixture.destination.appendingPathComponent("case0/shared"), encoding: .utf8) == "file blocks directory\n")
        try expect(try String(contentsOf: fixture.destination.appendingPathComponent("case1/same.txt/keep.txt"), encoding: .utf8) == "directory blocks file\n")
    }

    func testOverlayDoesNotUpdateExistingOrNestedWorkingCopies() async throws {
        let fixture = try CheckoutCheckFixture()
        defer { fixture.remove() }
        let tools = try fixture.localTools(), remote = try fixture.overlayRepository()
        let client = SVNClient(executablePath: tools.svn.path)
        _ = try await client.checkout(url: remote, destination: fixture.destination)
        try fixture.write("local working change\n", to: fixture.destination.appendingPathComponent("same.txt"))
        do {
            _ = try await client.checkout(url: remote, destination: fixture.destination, overwriteExisting: true)
            throw CheckFailure.failed("Existing working copies must not silently become an update")
        } catch let error as CheckFailure { throw error }
        catch { }
        try expect(try String(contentsOf: fixture.destination.appendingPathComponent("same.txt"), encoding: .utf8) == "local working change\n")
        let outer = fixture.root.appendingPathComponent("outer")
        _ = try await client.checkout(url: remote, destination: outer.appendingPathComponent("shared"))
        try fixture.write("nested working change\n", to: outer.appendingPathComponent("shared/same.txt"))
        do {
            _ = try await client.checkout(url: remote, destination: outer, overwriteExisting: true)
            throw CheckFailure.failed("Nested working copies must be retained")
        } catch let error as CheckFailure { throw error }
        catch { }
        try expect(!FileManager.default.fileExists(atPath: outer.appendingPathComponent(".svn").path))
        try expect(try String(contentsOf: outer.appendingPathComponent("shared/same.txt"), encoding: .utf8) == "nested working change\n")
    }

    func testOverlayRechecksFilesAndDoesNotReplayFailedWrites() async throws {
        for failure in [false, true] {
            let fixture = try CheckoutCheckFixture()
            defer { fixture.remove() }
            let script = """
            for task_argument in "$@"; do task_destination=$task_argument; done
            \(failure ? "printf 'new file\\n' > \"$task_destination/downloaded.txt\"; exit 1" : "printf 'concurrent local edit, keep this\\n' > \"$task_destination/file.txt\"")
            printf 'E    %s/file.txt\\n' "$task_destination"
            """
            let executable = try fixture.makeMock(checkout: script, entries: [("file.txt", "file")])
            let original = fixture.destination.appendingPathComponent("file.txt")
            try fixture.write("before\n", to: original)
            try fixture.write("extra preserved\n", to: fixture.destination.appendingPathComponent("extra.txt"))
            let events = CheckoutCheckBox<[CheckoutEvent]>([])
            do {
                try await SVNClient(executablePath: executable.path).checkoutWithProgress(url: fixture.remoteURL, destination: fixture.destination, overwriteExisting: true) {
                    event in events.modify { $0.append(event) }
                }
                throw CheckFailure.failed("Failed checkout or concurrent edits must not be overwritten/replayed")
            } catch let error as CheckFailure { throw error }
            catch { }
            try expect(try fixture.calls() == ["info", "list", "checkout"])
            try expect(checkoutCompletedCount(events.read { $0 }) == 0)
            try expect(try String(contentsOf: original, encoding: .utf8) == (failure ? "before\n" : "concurrent local edit, keep this\n"))
            try expect(try String(contentsOf: fixture.destination.appendingPathComponent("extra.txt"), encoding: .utf8) == "extra preserved\n")
        }
    }

    func testOverlayCancellationBeforeCheckoutLeavesDirectoryUntouched() async throws {
        let fixture = try CheckoutCheckFixture()
        defer { fixture.remove() }
        let executable = try fixture.makeMock(checkout: "exit 99", entries: [("file.txt", "file")])
        let original = fixture.destination.appendingPathComponent("file.txt")
        try fixture.write("keep\n", to: original)
        let worker = Task {
            try await SVNClient(executablePath: executable.path).checkoutWithProgress(url: fixture.remoteURL, destination: fixture.destination, overwriteExisting: true) {
                if case .started = $0 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { try await worker.value; throw CheckFailure.failed("Cancelled overlay must stop") }
        catch is CancellationError { }
        try expect(try fixture.calls() == ["info", "list"])
        try expect(try String(contentsOf: original, encoding: .utf8) == "keep\n")
        try expect(!FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent(".svn").path))
    }

    func testOverlayBatchesExplicitFilesWithoutTouchingExtras() async throws {
        let fixture = try CheckoutCheckFixture()
        defer { fixture.remove() }
        let tools = try fixture.localTools(), remote = try fixture.overlayRepository(bulk: 150)
        for index in 0..<150 { try fixture.write("local \(index)\n", to: fixture.destination.appendingPathComponent("bulk/文件-\(index).txt")) }
        try fixture.write("not in repository\n", to: fixture.destination.appendingPathComponent("bulk/extra.txt"))
        try await SVNClient(executablePath: tools.svn.path).checkoutWithProgress(url: remote, destination: fixture.destination, overwriteExisting: true) { _ in }
        for index in 0..<150 {
            try expect(try String(contentsOf: fixture.destination.appendingPathComponent("bulk/文件-\(index).txt"), encoding: .utf8) == "remote \(index)\n")
        }
        try expect(try String(contentsOf: fixture.destination.appendingPathComponent("bulk/extra.txt"), encoding: .utf8) == "not in repository\n")
    }

    func testCheckoutManifestRejectsUnsafeAndDuplicatePaths() throws {
        for name in ["../escape", "/absolute", ".svn/entries", "", "a//b", "a/./b"] {
            let xml = "<lists><list><entry kind=\"file\"><name>\(name)</name></entry></list></lists>"
            try expectThrows(SVNError.self) { _ = try SVNXML.parseCheckoutPaths(Data(xml.utf8)) }
        }
        let duplicate = "<lists><list><entry kind=\"file\"><name>a</name></entry><entry kind=\"dir\"><name>a</name></entry></list></lists>"
        try expectThrows(SVNError.self) { _ = try SVNXML.parseCheckoutPaths(Data(duplicate.utf8)) }
    }

    func testStdoutCallbackRunsBeforeExitAndRetainsOrderedBytes() async throws {
        let fixture = try CheckoutCheckFixture()
        defer { fixture.remove() }
        let acknowledgment = fixture.root.appendingPathComponent("callback.ack")
        let chunks = CheckoutCheckBox<[Data]>([])
        // The child cannot finish until the live callback acknowledges its first
        // write. Its write also ends inside a UTF-8 scalar, so byte order matters.
        let script = """
        printf 'ready\\n\\344\\270'
        task_attempt=0
        while [ ! -f "$1" ]; do
            task_attempt=$((task_attempt + 1))
            if [ "$task_attempt" -ge 500 ]; then exit 19; fi
            /bin/sleep 0.01
        done
        printf '\\255\\346\\226\\207 tail'
        printf 'diagnostic only' >&2
        """
        let output = try await withCheckTimeout(.seconds(10)) {
            try await ProcessRunner.run(
                executable: "/bin/sh", arguments: ["-c", script, "checkout-stream-check", acknowledgment.path],
                onStdout: { chunk in
                    chunks.modify { $0.append(chunk) }
                    try? Data().write(to: acknowledgment)
                }
            )
        }
        try expect(output.exitCode == 0, "The callback must release the child before it can exit")
        try expect(output.stdout == Data("ready\n中文 tail".utf8))
        try expect(output.stderr == Data("diagnostic only".utf8))
        let received = chunks.read { $0 }
        try expect(received.count >= 2, "The handshake must produce separate live chunks")
        try expect(received.reduce(into: Data(), { $0.append($1) }) == output.stdout)
    }

    func testCheckoutStreamsWholeUTF8LinesCountsUniqueItemsAndRedactsPassword() async throws {
        let fixture = try CheckoutCheckFixture()
        defer { fixture.remove() }
        let acknowledgment = fixture.root.appendingPathComponent("line.ack")
        let password = "synthetic-checkout-password"
        let script = """
        IFS= read -r task_password
        if [ "$task_password" != \(checkoutShellQuote(password)) ]; then exit 21; fi
        for task_argument in "$@"; do
            if [ "$task_argument" = \(checkoutShellQuote(password)) ]; then exit 22; fi
            task_destination=$task_argument
        done
        printf 'A    %s\\nA    %s/目录\\nA    %s/目录\\nNotice %s\\nA    %s/目录/\\344\\270' "$task_destination" "$task_destination" "$task_destination" "$task_password" "$task_destination"
        task_attempt=0
        while [ ! -f \(checkoutShellQuote(acknowledgment.path)) ]; do
            task_attempt=$((task_attempt + 1))
            if [ "$task_attempt" -ge 500 ]; then exit 23; fi
            /bin/sleep 0.01
        done
        printf '\\255\\346\\226\\207.txt'
        """
        let executable = try fixture.makeMock(checkout: script, entries: [("目录", "dir"), ("目录/中文.txt", "file")])
        let events = CheckoutCheckBox<[CheckoutEvent]>([])
        let client = SVNClient(executablePath: executable.path,
                               credentials: .init(username: "fixture-user", password: password))
        try await withCheckTimeout(.seconds(10)) {
            try await client.checkoutWithProgress(url: fixture.remoteURL, destination: fixture.destination) { event in
                events.modify { $0.append(event) }
                if case let .output(lines, _) = event, lines.contains(where: { $0.hasSuffix("/目录") }) {
                    try? Data().write(to: acknowledgment)
                }
            }
        }
        let recorded = events.read { $0 }
        try expect(try checkoutStart(recorded) == (2, "7"))
        try expect(checkoutCompletedCount(recorded) == 1)
        let outputs = checkoutOutputs(recorded)
        try expect(outputs.flatMap(\.lines).contains("A    \(fixture.destination.path)/目录/中文.txt"),
                   "An unterminated tail line and split multibyte filename must be published intact")
        try expect(!outputs.flatMap(\.lines).joined(separator: "\n").contains("\u{fffd}"))
        try expect(!outputs.flatMap(\.lines).joined(separator: "\n").contains(password))
        try expect(outputs.flatMap(\.lines).contains("Notice [已隐藏]"))
        try expect(outputs.first?.completed == 1, "Root and repeated notifications must not increase progress")
        try expect(outputs.last?.completed == 2)
        try expect(outputs.map(\.completed) == outputs.map(\.completed).sorted())
        try expect(try fixture.calls() == ["info", "list", "checkout"])
    }

    func testRealCheckoutUsesCountedRevisionDespiteNewRemoteCommit() async throws {
        let fixture = try CheckoutCheckFixture()
        defer { fixture.remove() }
        let tools = try fixture.localTools()
        let repository = fixture.root.appendingPathComponent("repository")
        let trunk = repository.appendingPathComponent("trunk")
        try fixture.run(tools.svnadmin, ["create", repository.path])
        let seed = fixture.root.appendingPathComponent("seed")
        try fixture.write("plain\n", to: seed.appendingPathComponent("plain.txt"))
        try fixture.write("unicode\n", to: seed.appendingPathComponent("空格 @目录/中文 @文件.txt"))
        try FileManager.default.createDirectory(at: seed.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try fixture.run(tools.svn, ["import", "-m", "initial revision", "--", seed.path, trunk.absoluteString])
        let events = CheckoutCheckBox<[CheckoutEvent]>([])
        let mutationError = CheckoutCheckBox<String?>(nil)
        let client = SVNClient(executablePath: tools.svn.path)
        try await client.checkoutWithProgress(url: trunk.absoluteString, destination: fixture.destination) { event in
            events.modify { $0.append(event) }
            if case .started = event {
                do {
                    try fixture.run(tools.svn, ["mkdir", "-m", "arrived after count", "--", trunk.appendingPathComponent("late").absoluteString + "@"])
                } catch {
                    mutationError.modify { $0 = error.localizedDescription }
                }
            }
        }
        try expect(mutationError.read { $0 } == nil, "The fixture must publish r2 during checkout preparation")
        let recorded = events.read { $0 }
        try expect(try checkoutStart(recorded) == (4, "1"))
        try expect(checkoutOutputs(recorded).last?.completed == 4)
        try expect(checkoutCompletedCount(recorded) == 1)
        try expect(!FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("late").path))
        try expect(try String(contentsOf: fixture.destination.appendingPathComponent("空格 @目录/中文 @文件.txt"), encoding: .utf8) == "unicode\n")
        let info = try await client.info(at: fixture.destination)
        try expect(info.revision == "1", "Checkout must pin the counted revision, even after HEAD advances")
        let headEntries = try await client.list(url: trunk.absoluteString)
        try expect(headEntries.contains(where: { $0.name == "late" }), "The HEAD change must really have occurred")
    }

    func testCheckoutFailureNeverCompletesOrReplays() async throws {
        let fixture = try CheckoutCheckFixture()
        defer { fixture.remove() }
        let password = "synthetic-failure-password"
        let executable = try fixture.makeMock(checkout: """
        for task_argument in "$@"; do task_destination=$task_argument; done
        IFS= read -r task_password
        printf 'A    %s/file.txt\\n' "$task_destination"
        printf 'svn: E170001: simulated failure %s\\n' "$task_password" >&2
        exit 1
        """, entries: [("file.txt", "file")])
        let events = CheckoutCheckBox<[CheckoutEvent]>([])
        let client = SVNClient(executablePath: executable.path,
                               credentials: .init(username: "fixture-user", password: password))
        do {
            try await client.checkoutWithProgress(url: fixture.remoteURL, destination: fixture.destination) {
                event in events.modify { $0.append(event) }
            }
            throw CheckFailure.failed("A failing checkout must throw")
        } catch let error as CheckFailure {
            throw error
        } catch {
            try expect(!error.localizedDescription.contains(password))
            try expect(error.localizedDescription.contains("[已隐藏]"))
        }
        try expect(checkoutCompletedCount(events.read { $0 }) == 0)
        try expect(try fixture.calls() == ["info", "list", "checkout"], "Failed checkout must be attempted once")
    }

    func testCheckoutRejectsNonemptyDestinationBeforeAnyCommand() async throws {
        let fixture = try CheckoutCheckFixture()
        defer { fixture.remove() }
        let executable = try fixture.makeMock(checkout: "exit 99", entries: [])
        let existing = fixture.destination.appendingPathComponent("keep.txt")
        try fixture.write("unchanged\n", to: existing)
        let events = CheckoutCheckBox<[CheckoutEvent]>([])
        do {
            try await SVNClient(executablePath: executable.path).checkoutWithProgress(
                url: fixture.remoteURL, destination: fixture.destination
            ) { event in events.modify { $0.append(event) } }
            throw CheckFailure.failed("A nonempty checkout destination must be rejected")
        } catch let error as CheckFailure {
            throw error
        } catch {
            try expect(!(error.localizedDescription.isEmpty))
        }
        try expect(try fixture.calls().isEmpty)
        try expect(events.read { $0.isEmpty })
        try expect(try String(contentsOf: existing, encoding: .utf8) == "unchanged\n")
    }

    func testCheckoutRechecksDestinationAfterCounting() async throws {
        let fixture = try CheckoutCheckFixture()
        defer { fixture.remove() }
        let executable = try fixture.makeMock(checkout: "exit 99", entries: [("file.txt", "file")])
        let existing = fixture.destination.appendingPathComponent("arrived.txt")
        let events = CheckoutCheckBox<[CheckoutEvent]>([])
        let writeError = CheckoutCheckBox<String?>(nil)
        do {
            try await SVNClient(executablePath: executable.path).checkoutWithProgress(
                url: fixture.remoteURL, destination: fixture.destination
            ) { event in
                events.modify { $0.append(event) }
                if case .started = event {
                    do { try fixture.write("preserve\n", to: existing) }
                    catch { writeError.modify { $0 = error.localizedDescription } }
                }
            }
            throw CheckFailure.failed("Files created during enumeration must not be overwritten")
        } catch let error as CheckFailure {
            throw error
        } catch {
            try expect(!(error.localizedDescription.isEmpty))
        }
        try expect(writeError.read { $0 } == nil)
        try expect(try fixture.calls() == ["info", "list"])
        try expect(checkoutCompletedCount(events.read { $0 }) == 0)
        try expect(try String(contentsOf: existing, encoding: .utf8) == "preserve\n")
    }

    func testCheckoutCancellationStopsProcessWithoutCompletionOrReplay() async throws {
        let fixture = try CheckoutCheckFixture()
        defer { fixture.remove() }
        let marker = fixture.root.appendingPathComponent("checkout.pid")
        let executable = try fixture.makeMock(checkout: """
        printf '%s\\n' "$$" > \(checkoutShellQuote(marker.path))
        exec /bin/sleep 30
        """, entries: [("file.txt", "file")])
        let events = CheckoutCheckBox<[CheckoutEvent]>([])
        let task = Task {
            try await SVNClient(executablePath: executable.path).checkoutWithProgress(
                url: fixture.remoteURL, destination: fixture.destination
            ) { event in events.modify { $0.append(event) } }
        }
        var cleanupPID: pid_t?
        defer {
            task.cancel()
            if let pid = cleanupPID { checkoutTerminateFixtureProcess(pid) }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while cleanupPID == nil, ContinuousClock.now < deadline {
            if let value = try? String(contentsOf: marker, encoding: .utf8),
               let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 {
                cleanupPID = pid
            } else {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let pid = try require(cleanupPID, "Checkout must have launched before cancellation")
        try expect(kill(pid, 0) == 0)
        let started = ContinuousClock.now
        task.cancel()
        do {
            try await task.value
            throw CheckFailure.failed("Cancelled checkout must throw CancellationError")
        } catch is CancellationError {
            // Expected: cancellation must not be reported as a server failure.
        } catch {
            throw CheckFailure.failed("Unexpected checkout cancellation error: \(String(describing: type(of: error)))")
        }
        try expect(started.duration(to: ContinuousClock.now) < .seconds(3))
        let stillRunning = kill(pid, 0) == 0
        try expect(!stillRunning, "The cancelled checkout process must be reaped before returning")
        if !stillRunning { cleanupPID = nil }
        try expect(checkoutCompletedCount(events.read { $0 }) == 0)
        try expect(try fixture.calls() == ["info", "list", "checkout"])
    }
}

private final class CheckoutCheckBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func modify(_ action: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        action(&value)
    }
    func read<Result>(_ action: (Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return action(value)
    }
}

private func checkoutStart(_ events: [CheckoutEvent]) throws -> (Int, String) {
    guard case let .started(total, revision)? = events.first else {
        throw CheckFailure.failed("Checkout must begin with its denominator and pinned revision")
    }
    return (total, revision)
}

private func checkoutCompletedCount(_ events: [CheckoutEvent]) -> Int {
    events.filter { if case .completed = $0 { return true }; return false }.count
}

private func checkoutOutputs(_ events: [CheckoutEvent]) -> [(lines: [String], completed: Int)] {
    events.compactMap { event in
        if case let .output(lines, completed) = event { return (lines, completed) }
        return nil
    }
}

private struct CheckoutCheckFixture: Sendable {
    let root: URL
    var destination: URL { root.appendingPathComponent("工作副本 @checkout") }
    var remoteURL: String { "https://checkout-fixture.invalid/repository/trunk" }
    var callFile: URL { root.appendingPathComponent("commands.txt") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SVNCheckoutChecks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try value.write(to: url, atomically: true, encoding: .utf8)
    }

    func calls() throws -> [String] {
        guard FileManager.default.fileExists(atPath: callFile.path) else { return [] }
        return try String(contentsOf: callFile, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func makeMock(checkout: String, entries: [(String, String)]) throws -> URL {
        let executable = root.appendingPathComponent("mock svn")
        let entryXML = entries.map { name, kind in "<entry kind=\"\(kind)\"><name>\(name)</name></entry>" }.joined()
        let script = """
        #!/bin/sh
        printf '%s\\n' "$1" >> \(checkoutShellQuote(callFile.path))
        case "$1" in
            info)
                printf '%s\\n' '<info><entry kind="dir" revision="7"><url>https://checkout-fixture.invalid/repository/trunk</url><repository><root>https://checkout-fixture.invalid/repository</root><uuid>fixture-uuid</uuid></repository></entry></info>'
                ;;
            list)
                printf '%s\\n' \(checkoutShellQuote("<lists><list path=\"fixture\">" + entryXML + "</list></lists>"))
                ;;
            checkout)
                \(checkout)
                ;;
            *) exit 27 ;;
        esac
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    func localTools() throws -> (svn: URL, svnadmin: URL) {
        for directory in [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/svn-cli/bin").path,
                          "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let svn = URL(fileURLWithPath: directory).appendingPathComponent("svn")
            let svnadmin = URL(fileURLWithPath: directory).appendingPathComponent("svnadmin")
            if FileManager.default.isExecutableFile(atPath: svn.path), FileManager.default.isExecutableFile(atPath: svnadmin.path) {
                return (svn, svnadmin)
            }
        }
        throw CheckFailure.failed("Checkout integration requires local svn and svnadmin")
    }

    func overlayRepository(bulk: Int = 0) throws -> String {
        let tools = try localTools(), repository = root.appendingPathComponent("overlay-repository")
        let seed = root.appendingPathComponent("seed")
        try run(tools.svnadmin, ["create", repository.path])
        try write("remote same\n", to: seed.appendingPathComponent("same.txt"))
        try write("remote new\n", to: seed.appendingPathComponent("new.txt"))
        try write("remote unicode\n", to: seed.appendingPathComponent("目录 空格 @/文件 @.txt"))
        try write("remote nested\n", to: seed.appendingPathComponent("shared/base.txt"))
        for index in 0..<bulk { try write("remote \(index)\n", to: seed.appendingPathComponent("bulk/文件-\(index).txt")) }
        let remote = repository.appendingPathComponent("trunk").absoluteString
        try run(tools.svn, ["import", "-m", "local overlay fixture", "--", seed.path, remote])
        return remote
    }

    @discardableResult
    func run(_ executable: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--non-interactive"] + arguments
        if executable.lastPathComponent == "svnadmin" { process.arguments = arguments }
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CheckFailure.failed("Local checkout fixture failed: \(String(decoding: errorData, as: UTF8.self))")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

private func checkoutShellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func checkoutTerminateFixtureProcess(_ pid: pid_t) {
    guard kill(pid, 0) == 0 else { return }
    _ = kill(pid, SIGTERM)
    for _ in 0..<100 {
        if kill(pid, 0) != 0 { return }
        usleep(10_000)
    }
    _ = kill(pid, SIGKILL)
}
