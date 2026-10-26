import Foundation
import CoreFoundation
import Darwin

public struct SVNTextFileDocument: Sendable {
    public let text: String
    public let encoding: String
    public let byteCount: Int
    public let lineEnding: String
}
public enum SVNFileComparisonRevision: Sendable { case head, base, revision(Int64) }
public struct SVNFileComparison: Sendable {
    public let local: SVNTextFileDocument
    public let remote: SVNTextFileDocument
    public let localLabel: String
    public let remoteLabel: String
    public let notice: String?

    public init(local: SVNTextFileDocument, remote: SVNTextFileDocument, remoteLabel: String,
                notice: String?, localLabel: String = "本地文件") {
        self.local = local; self.remote = remote; self.remoteLabel = remoteLabel
        self.notice = notice; self.localLabel = localLabel
    }
}

extension SVNClient {
    public func fileComparison(_ target: SVNRemoteDiffTarget, revision: SVNFileComparisonRevision = .head,
                               snapshotPath: Bool = false) async throws -> SVNFileComparison {
        _ = try await revalidatedRemoteFileDiffTarget(target)
        let localData = try readLocalComparisonFile(target.directory.appendingPathComponent(target.path), limit: comparisonFileLimit)
        let local = try comparisonTextDocument(localData)
        let remoteData: Data
        let label: String
        do {
            switch revision {
            case .head:
                let info = try await comparisonCommandOutput("info", ["--show-item", "revision", "--revision", "HEAD", "--", target.url + "@HEAD"],
                    at: target.directory, authenticated: true, limit: 256, limitMessage: "云端版本信息过大，无法确认文件快照。")
                let number = String(decoding: info, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !number.isEmpty, number.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), Int64(number) != nil else {
                    throw SVNError.invalid("无法确认云端最新文件的版本，请重新读取。")
                }
                remoteData = try await comparisonCommandOutput("cat", ["--revision", number, "--", target.url + "@" + number],
                    at: target.directory, authenticated: true, limit: comparisonFileLimit,
                    limitMessage: "云端文件超过 4 MiB，暂不支持全文比较。")
                label = "云端 r\(number)（读取时最新版本）"
            case .base:
                remoteData = try await comparisonCommandOutput("cat", ["--revision", "BASE", "--"] + paths([target.path], at: target.directory),
                    at: target.directory, authenticated: false, limit: comparisonFileLimit,
                    limitMessage: "BASE 文件超过 4 MiB，暂不支持全文比较。")
                label = "BASE（工作副本基线）"
            case .revision(let number):
                guard number >= 0 else { throw SVNError.invalid("请输入有效的数字版本。") }
                // Historical browsing follows this working node's BASE identity.
                // An incoming report instead names the path as it exists at its
                // checked snapshot, which may be a newly replaced node.
                let remoteTarget: [String]
                if snapshotPath { remoteTarget = [target.url + "@" + String(number)] }
                else { remoteTarget = try paths([target.path], at: target.directory) }
                remoteData = try await comparisonCommandOutput("cat", ["--revision", String(number), "--"] + remoteTarget,
                    at: target.directory, authenticated: true, limit: comparisonFileLimit,
                    limitMessage: "指定版本文件超过 4 MiB，暂不支持全文比较。")
                label = "云端 r\(number)（指定版本）"
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as SVNError {
            if error.isAuthenticationFailure { throw error }
            if case .invalid = error { throw error }
            throw SVNError.invalid("读取比较文件失败，请检查网络、权限，以及对应版本中的文件是否已被删除或改名。\n\(error.localizedDescription)")
        }
        try Task.checkCancellation()
        let remote = try comparisonTextDocument(remoteData)
        return SVNFileComparison(local: local, remote: remote, remoteLabel: label,
            notice: local.encoding == remote.encoding ? nil : "左右文件编码不同，已分别解码进行文本比较。")
    }

    /// Reads exactly two immutable repository snapshots. The numeric peg follows
    /// this path's node history; an absent version is an error, never an empty file.
    public func historyComparison(url: String, pegRevision: Int64, leftRevision: Int64,
                                  rightRevision: Int64) async throws -> SVNFileComparison {
        let location = try SVNLocation.validated(url).absoluteString
        guard pegRevision >= 0, leftRevision >= 0, rightRevision >= 0 else { throw SVNError.invalid("请输入有效的数字版本。") }
        let target = location + "@\(pegRevision)"
        let local: SVNTextFileDocument
        let remote: SVNTextFileDocument
        do {
            local = try comparisonTextDocument(await comparisonCommandOutput("cat", ["--revision", String(leftRevision), "--", target],
                at: nil, authenticated: true, limit: comparisonFileLimit, limitMessage: "左侧历史文件超过 4 MiB，暂不支持全文比较。"))
            remote = try comparisonTextDocument(await comparisonCommandOutput("cat", ["--revision", String(rightRevision), "--", target],
                at: nil, authenticated: true, limit: comparisonFileLimit, limitMessage: "右侧历史文件超过 4 MiB，暂不支持全文比较。"))
        } catch is CancellationError { throw CancellationError() }
        catch let error as SVNError {
            if error.isAuthenticationFailure { throw error }
            if case .invalid = error { throw error }
            throw SVNError.invalid("指定历史版本中的文件不存在、已删除或不可读取；未使用其他版本替代。\n\(error.localizedDescription)")
        }
        try Task.checkCancellation()
        return SVNFileComparison(local: local, remote: remote, remoteLabel: "历史 r\(rightRevision)",
            notice: local.encoding == remote.encoding ? nil : "左右文件编码不同，已分别解码进行文本比较。", localLabel: "历史 r\(leftRevision)")
    }

    private func comparisonCommandOutput(_ command: String, _ arguments: [String], at directory: URL?, authenticated: Bool,
                                         limit: Int, limitMessage: String) async throws -> Data {
        let buffer = ComparisonReadBuffer(limit: limit)
        let task = Task {
            try await execute(command, arguments, at: directory, authenticated: authenticated,
                              onStdout: { buffer.append($0) }, captureStdout: false)
        }
        buffer.setCancellation { task.cancel() }
        defer { buffer.clearCancellation() }
        do {
            _ = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if buffer.exceeded { throw SVNError.invalid(limitMessage) }
            throw error
        }
        try Task.checkCancellation()
        guard !buffer.exceeded else { throw SVNError.invalid(limitMessage) }
        return buffer.bytes
    }
}

private let comparisonFileLimit = 4 * 1_024 * 1_024

private func readLocalComparisonFile(_ file: URL, limit: Int) throws -> Data {
    try Task.checkCancellation()
    let type = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.type] as? FileAttributeType
    if type == .typeSymbolicLink {
        var bytes = [UInt8](repeating: 0, count: limit + 1)
        let capacity = bytes.count
        let count = file.path.withCString { Darwin.readlink($0, &bytes, capacity) }
        guard count >= 0 else { throw SVNError.invalid("无法读取本地 SVN 符号链接。") }
        guard count + 5 <= limit else { throw SVNError.invalid("本地链接内容超过 4 MiB，暂不支持全文比较。") }
        return Data("link ".utf8) + Data(bytes.prefix(count))
    }
    let descriptor = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { throw SVNError.invalid("本地文件无法读取或路径已变化，请刷新后重试。") }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
        throw SVNError.invalid("本地目标已不再是普通文件，请刷新后重试。")
    }
    guard metadata.st_size >= 0, metadata.st_size <= Int64(limit) else { throw SVNError.invalid("本地文件超过 4 MiB，暂不支持全文比较。") }
    var data = Data()
    do {
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: min(64 * 1_024, limit + 1 - data.count)), !chunk.isEmpty else { break }
            data.append(chunk)
            guard data.count <= limit else { throw SVNError.invalid("本地文件超过 4 MiB，暂不支持全文比较。") }
        }
    } catch is CancellationError { throw CancellationError() }
    catch let error as SVNError { throw error }
    catch { throw SVNError.invalid("本地文件读取未完成，请检查权限后重试。") }
    var after = stat()
    guard fstat(descriptor, &after) == 0, after.st_size == metadata.st_size,
          after.st_mtimespec.tv_sec == metadata.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == metadata.st_mtimespec.tv_nsec else {
        throw SVNError.invalid("本地文件在读取期间发生变化，请重新比较。")
    }
    return data
}

private func comparisonTextDocument(_ data: Data) throws -> SVNTextFileDocument {
    let bytes = Array(data)
    let signatures: [[UInt8]] = [[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], [0xFF, 0xD8, 0xFF],
        Array("GIF87a".utf8), Array("GIF89a".utf8), [0x50, 0x4B, 3, 4], [0x50, 0x4B, 5, 6], [0x50, 0x4B, 7, 8],
        Array("%PDF-".utf8), [0x1F, 0x8B], [0x7F, 0x45, 0x4C, 0x46], [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]]
    guard !signatures.contains(where: { bytes.starts(with: $0) }) else { throw comparisonBinaryError() }
    let text: String
    let encoding: String
    if bytes.starts(with: [0xFF, 0xFE]) {
        text = try comparisonUTF16(Array(bytes.dropFirst(2)), littleEndian: true)
        encoding = "UTF-16 LE（BOM）"
    } else if bytes.starts(with: [0xFE, 0xFF]) {
        text = try comparisonUTF16(Array(bytes.dropFirst(2)), littleEndian: false)
        encoding = "UTF-16 BE（BOM）"
    } else if let littleEndian = comparisonUTF16Hint(bytes) {
        text = try comparisonUTF16(bytes, littleEndian: littleEndian)
        encoding = littleEndian ? "UTF-16 LE（无 BOM）" : "UTF-16 BE（无 BOM）"
    } else {
        let bom = bytes.starts(with: [0xEF, 0xBB, 0xBF])
        let payload = bom ? Data(bytes.dropFirst(3)) : data
        if String(data: payload, encoding: .utf8) != nil {
            text = String(decoding: payload, as: UTF8.self)
            encoding = bom ? "UTF-8（BOM）" : "UTF-8"
        } else {
            guard !bytes.contains(where: { $0 == 0 || ($0 < 32 && ![9, 10, 13].contains($0)) || $0 == 127 }) else { throw comparisonBinaryError() }
            var decoded: (String, String)?
            // CoreFoundation's official GB18030 and GBK encoding identifiers.
            for (code, label) in [(0x0632, "GB18030"), (0x0631, "GBK")] {
                let candidate = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(code)))
                if let value = String(data: data, encoding: candidate), value.data(using: candidate, allowLossyConversion: false) == data {
                    decoded = (value, label); break
                }
            }
            guard let decoded else { throw SVNError.invalid("无法可靠识别文件文本编码，暂不支持比较该文件。") }
            text = decoded.0; encoding = decoded.1
        }
    }
    guard !text.unicodeScalars.contains(where: { $0.value == 0 || ($0.properties.generalCategory == .control && ![9, 10, 13].contains($0.value)) }) else {
        throw comparisonBinaryError()
    }
    var cr = 0, lf = 0, crlf = 0
    var previousCR = false
    for scalar in text.unicodeScalars {
        if scalar == "\r" { cr += 1 }
        if scalar == "\n" { if previousCR { cr -= 1; crlf += 1 } else { lf += 1 } }
        previousCR = scalar == "\r"
    }
    let endings = [(crlf, "CRLF"), (lf, "LF"), (cr, "CR")].filter { $0.0 > 0 }.map { $0.1 }
    let ending = endings.isEmpty ? "无换行" : endings.count == 1 ? endings[0] : "混合（" + endings.joined(separator: " / ") + "）"
    return SVNTextFileDocument(text: text, encoding: encoding, byteCount: data.count, lineEnding: ending)
}
private func comparisonUTF16(_ bytes: [UInt8], littleEndian: Bool) throws -> String {
    guard bytes.count % 2 == 0 else { throw SVNError.invalid("UTF-16 文件字节不完整，无法可靠解码。") }
    var units: [UInt16] = []
    units.reserveCapacity(bytes.count / 2)
    for index in stride(from: 0, to: bytes.count, by: 2) {
        units.append(littleEndian ? UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8 : UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))
    }
    var index = 0
    while index < units.count {
        let unit = units[index]
        if unit >= 0xD800 && unit <= 0xDBFF {
            guard index + 1 < units.count, units[index + 1] >= 0xDC00, units[index + 1] <= 0xDFFF else {
                throw SVNError.invalid("UTF-16 文件包含无效字符序列，无法可靠解码。")
            }
            index += 2
        } else {
            guard unit < 0xDC00 || unit > 0xDFFF else { throw SVNError.invalid("UTF-16 文件包含无效字符序列，无法可靠解码。") }
            index += 1
        }
    }
    return String(decoding: units, as: UTF16.self)
}
private func comparisonUTF16Hint(_ bytes: [UInt8]) -> Bool? {
    guard bytes.count >= 4, bytes.count % 2 == 0 else { return nil }
    let units = bytes.count / 2
    var even = 0, odd = 0
    for (index, byte) in bytes.enumerated() where byte == 0 { if index % 2 == 0 { even += 1 } else { odd += 1 } }
    if odd >= max(2, units / 3), odd > even * 4 { return true }
    if even >= max(2, units / 3), even > odd * 4 { return false }
    return nil
}
private func comparisonBinaryError() -> SVNError { .invalid("文件内容属于二进制或含有控制字符，暂不支持文本并排比较。") }

private final class ComparisonReadBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var overflow = false
    private var cancel: (@Sendable () -> Void)?
    init(limit: Int) { self.limit = limit }
    var exceeded: Bool { lock.lock(); defer { lock.unlock() }; return overflow }
    var bytes: Data { lock.lock(); defer { lock.unlock() }; return data }
    func append(_ chunk: Data) {
        lock.lock()
        let remaining = max(0, limit - data.count)
        data.append(contentsOf: chunk.prefix(remaining))
        if chunk.count > remaining { overflow = true }
        let cancellation = overflow ? cancel : nil
        lock.unlock()
        cancellation?()
    }
    func setCancellation(_ action: @escaping @Sendable () -> Void) {
        lock.lock(); cancel = action; let shouldCancel = overflow; lock.unlock()
        if shouldCancel { action() }
    }
    func clearCancellation() { lock.lock(); cancel = nil; lock.unlock() }
}
