import Foundation

public enum CheckoutEvent: Sendable {
    case started(totalItems: Int, revision: String)
    case output(lines: [String], completedItems: Int)
    case completed
}

public struct CheckoutPlan: Sendable {
    let target: String
    let revision: String
    let paths: Set<String>
    let directories: Set<String>
    let overwriteExisting: Bool
}

/// SVN uses line-buffered stdout on macOS. Decode only complete lines so a read
/// boundary inside a multibyte filename never damages the displayed path.
final class CheckoutOutputTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let destination: String
    private let paths: Set<String>
    private let password: String
    private let onProgress: @Sendable (CheckoutEvent) -> Void
    private var pending = Data()
    private var seen = Set<String>()

    init(destination: URL, paths: Set<String>, password: String,
         onProgress: @escaping @Sendable (CheckoutEvent) -> Void) {
        self.destination = destination.standardizedFileURL.path
        self.paths = paths
        self.password = password
        self.onProgress = onProgress
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        pending.append(chunk)
        var lines: [String] = []
        while let end = pending.firstIndex(of: 10) {
            lines.append(String(decoding: pending[..<end], as: UTF8.self))
            pending.removeSubrange(...end)
        }
        publish(lines)
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !pending.isEmpty else { return }
        publish([String(decoding: pending, as: UTF8.self)])
        pending.removeAll()
    }

    private func publish(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        for line in lines {
            // A = downloaded, E = adopted existing path in a forced checkout.
            // Count known entries only, excluding the WC root.
            let bytes = Array(line.utf8)
            guard bytes.count > 5, [65, 69].contains(bytes[0]), bytes[1...4].allSatisfy({ $0 == 32 }) else { continue }
            var path = String(decoding: bytes.dropFirst(5), as: UTF8.self)
            if path.hasSuffix("\r") { path.removeLast() }
            let absolute = URL(fileURLWithPath: path).standardizedFileURL.path
            let prefix = destination + "/"
            guard absolute.hasPrefix(prefix) else { continue }
            let relative = String(absolute.dropFirst(prefix.count))
            if paths.contains(relative) { seen.insert(relative) }
        }
        let safe = lines.map { line in
            password.isEmpty ? line : line.replacingOccurrences(of: password, with: "[已隐藏]")
        }
        onProgress(.output(lines: safe, completedItems: seen.count))
    }
}
