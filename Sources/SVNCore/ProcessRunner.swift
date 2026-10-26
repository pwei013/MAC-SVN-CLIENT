import Foundation

public struct CommandOutput: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32
    public var text: String { String(decoding: stdout, as: UTF8.self) }
}

private final class ReadBuffer: @unchecked Sendable {
    var data = Data()
}

private final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func launch(_ value: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try value.run()
        process = value
    }
    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }
    func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        process = nil
        return cancelled
    }
}

public enum ProcessRunner {
    public static func run(executable: String, arguments: [String], directory: URL? = nil,
                           input: Data = Data(), onStdout: (@Sendable (Data) -> Void)? = nil,
                           captureStdout: Bool = true) async throws -> CommandOutput {
        let running = RunningProcess()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments
                    process.currentDirectoryURL = directory
                    var environment = ProcessInfo.processInfo.environment
                    // GUI launches inherit a smaller PATH; ssh and helpers still need normal locations.
                    environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
                    environment["LC_ALL"] = "en_US.UTF-8"
                    process.environment = environment
                    let output = Pipe(), errors = Pipe(), stdin = Pipe()
                    process.standardOutput = output
                    process.standardError = errors
                    process.standardInput = stdin
                    do {
                        try running.launch(process)
                        let group = DispatchGroup()
                        let outBuffer = ReadBuffer(), errBuffer = ReadBuffer()
                        for (pipe, buffer) in [(output, outBuffer), (errors, errBuffer)] {
                            group.enter()
                            DispatchQueue.global(qos: .userInitiated).async {
                                while true {
                                    let chunk = pipe.fileHandleForReading.availableData
                                    if chunk.isEmpty { break }
                                    if pipe !== output || captureStdout { buffer.data.append(chunk) }
                                    if pipe === output { onStdout?(chunk) }
                                }
                                group.leave()
                            }
                        }
                        // SVN reads passwords from stdin; they never appear in process arguments.
                        try? stdin.fileHandleForWriting.write(contentsOf: input)
                        try? stdin.fileHandleForWriting.close()
                        process.waitUntilExit()
                        group.wait()
                        if running.finish() { throw CancellationError() }
                        continuation.resume(returning: CommandOutput(stdout: outBuffer.data,
                            stderr: errBuffer.data, exitCode: process.terminationStatus))
                    } catch {
                        _ = running.finish()
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: { running.cancel() }
    }
}
