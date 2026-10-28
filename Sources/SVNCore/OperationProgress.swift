import Foundation

public enum SVNOperationKind: String, Sendable { case update, commit }

public struct SVNOperationRecord: Identifiable, Sendable {
    public let id: Int
    public let action: String
    public let path: String
    public let message: String
    public let deleted: Bool
}

public struct SVNOperationMetadata: Sendable {
    public let path: String
    public let author: String
    public let date: String
    public let revision: String
}

public enum SVNOperationEvent: Sendable {
    case preparing(String)
    case started(total: Int?)
    case output(records: [SVNOperationRecord], processed: Int)
    case commandCompleted(revision: String?)
    case metadata([SVNOperationMetadata])
    case notice(String)
}

public struct SVNOperationResult: Sendable {
    public let text: String
    public let revision: String?
    public let paths: [String]
}

extension SVNClient {
    /// Stream the normal update directly. No recursive inventory or per-file
    /// server request is needed before downloading. Metadata comes from the WC
    /// after SVN has finished its write transaction.
    public func updateWithProgress(at directory: URL,
        onProgress: @escaping @Sendable (SVNOperationEvent) -> Void) async throws -> SVNOperationResult {
        let tracker = SVNOperationTracker(kind: .update, directory: directory, targets: [],
                                          password: credentials.password, onProgress: onProgress)
        onProgress(.started(total: nil))
        do {
            _ = try await execute("update", ["--ignore-externals", "--accept", "postpone", "--", ".@"],
                at: directory, authenticated: true, onStdout: { tracker.append($0) }, captureStdout: false)
        } catch { tracker.finish(); throw error }
        tracker.finish()
        let result = tracker.result
        onProgress(.commandCompleted(revision: result.revision))
        do { try await completeOperationMetadata(tracker.metadataPaths, at: directory, onProgress: onProgress) }
        catch is CancellationError { onProgress(.notice("更新命令已完成，提交信息补全已取消；本地可能还需刷新状态。")) }
        catch { onProgress(.notice("更新命令已完成，部分提交信息无法读取；不会因此重新更新。")) }
        return result
    }

    public func commitWithProgress(at directory: URL, paths targets: [String], message: String,
        onProgress: @escaping @Sendable (SVNOperationEvent) -> Void) async throws -> SVNOperationResult {
        try await commitValidatedWithProgress(at: directory, paths: targets, message: message,
                                              firstRecordID: 0, onProgress: onProgress)
    }

    func commitValidatedWithProgress(at directory: URL, paths targets: [String], message: String, firstRecordID: Int,
        onProgress: @escaping @Sendable (SVNOperationEvent) -> Void) async throws -> SVNOperationResult {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !targets.isEmpty else {
            throw SVNError.invalid("请勾选文件并填写提交说明。")
        }
        let checked = try paths(targets, at: directory)
        let current = try await status(at: directory)
        let invalid = targets.filter { path in !current.contains { $0.path == path && $0.canCommit } }
        if !invalid.isEmpty {
            let reasons = invalid.prefix(30).map { path in
                let label = current.first { $0.path == path }?.commitBlockReason ?? "没有可提交变更或路径不存在"
                return safeCommitDiagnostic("\(path)：\(label)", password: credentials.password)
            }
            throw SVNCommitSelectionFailure(issue: .invalidFiles, paths: invalid, reasons: reasons)
        }
        let selected = Set(targets)
        let missingParents = current.filter { change in
            change.item == "added" && !selected.contains(change.path) && targets.contains { $0.hasPrefix(change.path + "/") }
        }.map(\.path)
        if !missingParents.isEmpty {
            throw SVNCommitSelectionFailure(issue: .missingParents, paths: missingParents,
                reasons: missingParents.map { safeCommitDiagnostic($0, password: credentials.password) })
        }
        let tracker = SVNOperationTracker(kind: .commit, directory: directory, targets: Set(targets),
                                          password: credentials.password, firstRecordID: firstRecordID, onProgress: onProgress)
        onProgress(.started(total: Set(targets).count))
        do {
            _ = try await execute("commit", ["--depth", "empty", "--message", message, "--"] + checked,
                at: directory, authenticated: true, onStdout: { tracker.append($0) }, captureStdout: false)
        } catch {
            tracker.finish()
            if let revision = tracker.result.revision {
                onProgress(.commandCompleted(revision: revision))
                onProgress(.notice("服务器已确认提交版本 r\(revision)，但后续处理有异常；不要重复提交。\n\(error.localizedDescription)"))
                return tracker.result
            }
            if error is CancellationError { throw error }
            throw SVNCommitFailure.diagnose(error)
        }
        tracker.finish()
        let result = tracker.result
        guard result.revision != nil else {
            throw SVNError.invalid("提交命令已结束，但未返回已提交版本号。请先核对工作副本和仓库历史，勿重复提交。")
        }
        onProgress(.commandCompleted(revision: result.revision))
        return result
    }

    private func completeOperationMetadata(_ requested: [String], at directory: URL,
        onProgress: @escaping @Sendable (SVNOperationEvent) -> Void) async throws {
        var batches: [[String]] = [], batch: [String] = [], size = 0
        for path in requested {
            try Task.checkCancellation()
            // Deleted/missing nodes have no post-update commit metadata. Avoid
            // letting one missing node invalidate a whole info batch.
            guard (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(path).path)) != nil else { continue }
            if batch.count >= 128 || size + path.utf8.count > 32 * 1_024 {
                batches.append(batch); batch = []; size = 0
            }
            batch.append(path); size += path.utf8.count + 2
        }
        if !batch.isEmpty { batches.append(batch) }
        var failed = false
        for paths in batches {
            try Task.checkCancellation()
            do {
                let data = try await boundedRead("info", ["--xml", "--depth", "empty", "--"] + self.paths(paths, at: directory),
                    at: directory, authenticated: false, limit: 4 * 1_024 * 1_024,
                    message: "本批提交信息超过显示上限。")
                let values = try OperationMetadataXML.parse(data, directory: directory, allowed: Set(paths))
                onProgress(.metadata(values.map { value in
                    SVNOperationMetadata(path: operationSafe(value.path, password: credentials.password),
                        author: operationSafe(value.author, password: credentials.password), date: value.date, revision: value.revision)
                }))
            } catch is CancellationError { throw CancellationError() }
            catch { failed = true }
        }
        if failed { onProgress(.notice("更新已完成，部分文件的提交信息无法从本地元数据读取。")) }
    }
}

private func operationSafe(_ value: String, password: String) -> String {
    let safe = password.isEmpty ? value : value.replacingOccurrences(of: password, with: "[已隐藏]")
    return String(safe.prefix(4_096))
}

private func operationRelativePath(_ value: String, directory: URL) -> String? {
    let root = directory.standardizedFileURL.path
    let full = value.hasPrefix("/") ? URL(fileURLWithPath: value).standardizedFileURL.path :
        directory.appendingPathComponent(value).standardizedFileURL.path
    guard full == root || full.hasPrefix(root + "/") else { return nil }
    let relative = full == root ? "." : String(full.dropFirst(root.count + 1))
    guard !relative.contains("\0"), relative.utf8.count <= 4_096,
          !relative.split(separator: "/").contains(".svn") else { return nil }
    return relative
}

/// The pipe reader never enters the main actor. Complete UTF-8 lines, bounded
/// partial lines and a bounded notification history keep output memory stable.
final class SVNOperationTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let kind: SVNOperationKind
    private let directory: URL
    private let targets: Set<String>
    private let password: String
    private let onProgress: @Sendable (SVNOperationEvent) -> Void
    private var pending = Data()
    private var truncated = false
    private var nextID = 0
    private var processed = 0
    private var recentSeen = Set<String>()
    private var recentPaths: [String] = []
    private var pathOffset = 0
    private var deleted = Set<String>()
    private var tail: [String] = []
    private var revision: String?

    init(kind: SVNOperationKind, directory: URL, targets: Set<String>, password: String, firstRecordID: Int = 0,
         onProgress: @escaping @Sendable (SVNOperationEvent) -> Void) {
        self.kind = kind; self.directory = directory; self.targets = targets
        self.password = password; self.onProgress = onProgress
        self.nextID = firstRecordID
    }

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        var start = chunk.startIndex
        var records: [SVNOperationRecord] = []
        while start < chunk.endIndex {
            let end = chunk[start...].firstIndex(of: 10) ?? chunk.endIndex
            let piece = chunk[start..<end]
            let remaining = max(0, 65_536 - pending.count)
            pending.append(contentsOf: piece.prefix(remaining))
            if piece.count > remaining { truncated = true }
            if end == chunk.endIndex { break }
            records.append(record(String(decoding: pending, as: UTF8.self), truncated: truncated))
            pending.removeAll(keepingCapacity: true); truncated = false
            start = chunk.index(after: end)
        }
        if !records.isEmpty { onProgress(.output(records: records, processed: processed)) }
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        if !pending.isEmpty || truncated {
            let value = record(String(decoding: pending, as: UTF8.self), truncated: truncated)
            onProgress(.output(records: [value], processed: processed))
            pending.removeAll(); truncated = false
        }
    }

    var result: SVNOperationResult {
        lock.lock(); defer { lock.unlock() }
        return SVNOperationResult(text: tail.joined(separator: "\n"), revision: revision, paths: targets.sorted())
    }

    var nextRecordID: Int { lock.lock(); defer { lock.unlock() }; return nextID }

    var metadataPaths: [String] {
        lock.lock(); defer { lock.unlock() }
        return recentPaths.dropFirst(pathOffset).filter { !deleted.contains($0) }
    }

    private func record(_ original: String, truncated: Bool) -> SVNOperationRecord {
        var text = original
        if text.hasSuffix("\r") { text.removeLast() }
        // A cut line might end inside an echoed password. Omit it completely
        // rather than exposing a prefix that cannot match the full secret.
        let safe = truncated ? "SVN 输出行过长，已省略。" : operationSafe(text, password: password)
        tail.append(safe)
        if tail.count > 32 { tail.removeFirst(tail.count - 32) }
        for prefix in ["Committed revision ", "Updated to revision ", "At revision "] where !truncated && text.hasPrefix(prefix) {
            let remainder = text.dropFirst(prefix.count)
            let number = String(remainder.prefix(while: { $0.isASCII && $0.isNumber }))
            if !number.isEmpty, remainder.dropFirst(number.count) == ".", Int64(number) != nil { revision = number }
        }
        var action = "信息", path = "", isDeleted = false
        if !truncated, kind == .update {
            let bytes = Array(text.utf8)
            if bytes.count > 5, bytes[4] == 32,
               bytes[0...3].allSatisfy({ Array(" ADUCGEBR".utf8).contains($0) }),
               bytes[0...3].contains(where: { $0 != 32 }),
               let value = operationRelativePath(String(decoding: bytes.dropFirst(5), as: UTF8.self), directory: directory) {
                path = value
                isDeleted = bytes[0] == 68
                if bytes[0...3].contains(67) { action = "冲突" }
                else if isDeleted { action = "删除" }
                else if bytes[0] == 65 { action = "新增" }
                else if bytes[0...1].contains(71) { action = "合并" }
                else if bytes[0] == 32 && bytes[1] != 32 { action = "属性更新" }
                else { action = "更新" }
            }
        } else if !truncated, kind == .commit {
            let addHeader = String(text.prefix(10))
            if addHeader.count == 10, addHeader.hasPrefix("A "),
               addHeader.dropFirst().replacingOccurrences(of: "(bin)", with: "").allSatisfy({ $0 == " " }),
               let value = operationRelativePath(String(text.dropFirst(10)), directory: directory) {
                path = value; action = "Add"
            }
            for (prefix, label) in [("Sending", "发送"), ("Adding", "新增"), ("Deleting", "删除"), ("Replacing", "替换")] {
                guard text.hasPrefix(prefix + " ") else { continue }
                var rest = text.dropFirst(prefix.count).drop(while: { $0 == " " })
                if rest.hasPrefix("(bin)") { rest = rest.dropFirst(5).drop(while: { $0 == " " }) }
                let header = String(text.prefix(15))
                let padding = header.dropFirst(prefix.count).replacingOccurrences(of: "(bin)", with: "")
                if header.count == 15, padding.allSatisfy({ $0 == " " }) { rest = text.dropFirst(15) }
                if let value = operationRelativePath(String(rest), directory: directory) {
                    path = value; action = label; isDeleted = label == "删除"
                }
                break
            }
        }
        if !path.isEmpty {
            if !recentSeen.contains(path) {
                if kind == .update || targets.contains(path) { processed += 1 }
                recentSeen.insert(path); recentPaths.append(path)
                if recentPaths.count - pathOffset > 10_000 {
                    let old = recentPaths[pathOffset]; pathOffset += 1
                    recentSeen.remove(old); deleted.remove(old)
                    if pathOffset >= 10_000 {
                        recentPaths = Array(recentPaths.dropFirst(pathOffset)); pathOffset = 0
                    }
                }
            }
            if isDeleted { deleted.insert(path) } else { deleted.remove(path) }
        }
        defer { nextID += 1 }
        return SVNOperationRecord(id: nextID, action: action, path: operationSafe(path, password: password), message: safe, deleted: isDeleted)
    }
}

private final class OperationMetadataXML: NSObject, XMLParserDelegate {
    let directory: URL
    let allowed: Set<String>
    var stack: [String] = []
    var values: [SVNOperationMetadata] = []
    var currentPath: String?
    var author = "", date = "", revision = ""
    var root: String?
    var failed = false
    var calls = 0
    let formatter: DateFormatter

    init(directory: URL, allowed: Set<String>) {
        self.directory = directory; self.allowed = allowed
        formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    }

    static func parse(_ data: Data, directory: URL, allowed: Set<String>) throws -> [SVNOperationMetadata] {
        guard !String(decoding: data.prefix(2_048), as: UTF8.self).contains("<!") else { throw SVNError.invalid("提交信息 XML 包含不支持的声明。") }
        let delegate = OperationMetadataXML(directory: directory, allowed: allowed)
        let parser = XMLParser(data: data); parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        let success = parser.parse()
        try Task.checkCancellation()
        guard success, !delegate.failed, delegate.root == "info", delegate.stack.isEmpty else { throw SVNError.invalid("无法读取文件提交信息。") }
        return delegate.values
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        calls += 1
        if calls.isMultiple(of: 128), Task.isCancelled { parser.abortParsing(); return }
        if root == nil { root = name }
        stack.append(name)
        if stack.count > 16 { failed = true; parser.abortParsing(); return }
        if name == "entry" {
            currentPath = attributes["path"].flatMap { operationRelativePath($0, directory: directory) }
            if currentPath.map({ !allowed.contains($0) }) ?? true { failed = true; parser.abortParsing(); return }
            author = ""; date = ""; revision = ""
        }
        if name == "commit" { revision = String((attributes["revision"] ?? "").prefix(32)) }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if stack.last == "author", author.utf8.count < 1_024 { author += string }
        if stack.last == "date", date.utf8.count < 128 { date += string }
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        failed = true; parser.abortParsing()
    }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        failed = true; parser.abortParsing()
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        if name == "entry", let path = currentPath {
            let parsed = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(date)) ?? (try? Date.ISO8601FormatStyle().parse(date))
            values.append(SVNOperationMetadata(path: path,
                author: String(author.replacingOccurrences(of: "\n", with: " ").prefix(256)),
                date: parsed.map { formatter.string(from: $0) } ?? "", revision: revision))
            currentPath = nil
        }
        if !stack.isEmpty { stack.removeLast() }
    }
}
