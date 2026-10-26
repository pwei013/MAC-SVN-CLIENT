import Darwin
import Foundation
import SVNCore

struct ProcessRunnerTests {
    func testCapturesLargeStdoutAndStderrWithoutBlocking() async throws {
        let script = """
        task_index=0
        while [ "$task_index" -lt 4096 ]; do
            printf '0123456789abcdef0123456789abcdef'
            printf 'fedcba9876543210fedcba9876543210' >&2
            task_index=$((task_index + 1))
        done
        """
        let output = try await withCheckTimeout(.seconds(15)) {
            try await ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", script])
        }

        try expect(output.exitCode == 0)
        try expect(output.stdout.count == 128 * 1024)
        try expect(output.stderr.count == 128 * 1024)
        try expect(output.stdout == Data(String(repeating: "0123456789abcdef0123456789abcdef", count: 4096).utf8))
        try expect(output.stderr == Data(String(repeating: "fedcba9876543210fedcba9876543210", count: 4096).utf8))
    }

    func testCancellationTerminatesStartedSleepAndThrowsCancellationError() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SVNProcessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("started.pid")
        // exec preserves the marked PID and leaves no shell child to clean up.
        let script = """
        printf '%s\\n' "$$" > "$1"
        exec /bin/sleep 30
        """
        let task = Task {
            try await ProcessRunner.run(
                executable: "/bin/sh",
                arguments: ["-c", script, "svnmanager-process-test", marker.path]
            )
        }
        var cleanupPID: pid_t?
        defer {
            task.cancel()
            if let pid = cleanupPID { terminateFixtureProcess(pid) }
        }

        let launchDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while cleanupPID == nil, ContinuousClock.now < launchDeadline {
            if let content = try? String(contentsOf: marker, encoding: .utf8),
               let value = Int32(content.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 {
                cleanupPID = value
            } else {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let pid = try require(cleanupPID, "The test process must start before cancellation")
        try expect(kill(pid, 0) == 0)
        try await Task.sleep(for: .milliseconds(50))

        let cancellationStarted = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            throw CheckFailure.failed("Cancelling a running process must throw CancellationError")
        } catch is CancellationError {
            // Expected: cancellation is distinct from a failing command exit code.
        } catch {
            throw CheckFailure.failed("Unexpected cancellation error type: \(String(describing: type(of: error)))")
        }
        try expect(cancellationStarted.duration(to: ContinuousClock.now) < .seconds(3))

        let processExists = kill(pid, 0) == 0
        try expect(!processExists, "The cancelled sleep process must be reaped before returning")
        if !processExists { cleanupPID = nil }
    }
}

private func terminateFixtureProcess(_ pid: pid_t) {
    guard kill(pid, 0) == 0 else { return }
    _ = kill(pid, SIGTERM)
    for _ in 0..<100 {
        if kill(pid, 0) != 0 { return }
        usleep(10_000)
    }
    _ = kill(pid, SIGKILL)
}
