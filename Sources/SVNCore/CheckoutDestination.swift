import Foundation

public enum SVNCheckoutDestination {
    /// Inspect only the selected directory, never its entire existing tree.
    public static func isNonempty(_ destination: URL) throws -> Bool {
        try Task.checkCancellation()
        guard let attributes = try checkoutLocalAttributes(destination) else { return false }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw SVNError.invalid("签出目标必须是实际文件夹，不能是文件或符号链接。")
        }
        var failure: Error?
        guard let contents = FileManager.default.enumerator(at: destination, includingPropertiesForKeys: [],
            options: [.skipsSubdirectoryDescendants], errorHandler: { _, error in failure = error; return false }) else {
            throw failure ?? SVNError.invalid("无法读取签出目标目录。")
        }
        let first = contents.nextObject()
        if let failure { throw failure }
        try Task.checkCancellation()
        return first != nil
    }
}

struct CheckoutExistingFile {
    let path: String
    private let size: UInt64
    private let inode: UInt64
    private let modified: Date?

    init(path: String, attributes: [FileAttributeKey: Any]) {
        self.path = path
        size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        modified = attributes[.modificationDate] as? Date
    }

    func revalidate(at destination: URL) throws {
        try Task.checkCancellation()
        var parent = destination
        for part in [""] + path.split(separator: "/").dropLast().map(String.init) {
            if !part.isEmpty { parent.appendPathComponent(part) }
            guard try checkoutLocalAttributes(parent)?[.type] as? FileAttributeType == .typeDirectory else {
                throw SVNError.invalid("签出期间目录路径发生变化，未覆盖文件：\(path)")
            }
        }
        guard let value = try checkoutLocalAttributes(destination.appendingPathComponent(path)),
              value[.type] as? FileAttributeType == .typeRegular,
              (value[.size] as? NSNumber)?.uint64Value == size,
              (value[.systemFileNumber] as? NSNumber)?.uint64Value == inode,
              value[.modificationDate] as? Date == modified else {
            throw SVNError.invalid("签出期间本地文件发生变化，未覆盖该文件：\(path)。请检查工作副本后再处理。")
        }
    }
}

/// Only repository paths are inspected. Unrelated local files and directories
/// are neither traversed nor removed. Existing working copies are not updated.
func checkoutExistingFiles(at destination: URL, paths: Set<String>, directories: Set<String>) throws -> [CheckoutExistingFile] {
    _ = try SVNCheckoutDestination.isNonempty(destination)
    var ancestor = destination.standardizedFileURL
    while true {
        try Task.checkCancellation()
        if try checkoutLocalAttributes(ancestor.appendingPathComponent(".svn")) != nil {
            throw SVNError.invalid("签出目标位于已有 SVN 工作副本中。请打开该工作副本进行更新，或选择其他目录签出。")
        }
        let parent = ancestor.deletingLastPathComponent().standardizedFileURL
        if parent.path == ancestor.path { break }
        ancestor = parent
    }
    var directoryCache = Set<String>()
    var missingDirectories = Set<String>()
    var files: [CheckoutExistingFile] = []
    for path in paths.sorted() {
        try Task.checkCancellation()
        let components = path.split(separator: "/").map(String.init)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
              components.allSatisfy({ $0 != "." && $0 != ".." && $0 != ".svn" }) else {
            throw SVNError.invalid("签出清单包含无效路径，未开始签出。")
        }
        var relative = ""
        for (index, component) in components.enumerated() {
            relative = relative.isEmpty ? component : relative + "/" + component
            if missingDirectories.contains(relative) { break }
            let needsDirectory = index < components.count - 1 || directories.contains(path)
            if needsDirectory, directoryCache.contains(relative) { continue }
            let local = destination.appendingPathComponent(relative)
            guard let attributes = try checkoutLocalAttributes(local) else {
                if needsDirectory { missingDirectories.insert(relative) }
                break
            }
            let type = attributes[.type] as? FileAttributeType
            if needsDirectory {
                guard type == .typeDirectory else {
                    throw SVNError.invalid("本地路径与仓库目录类型冲突，原有项目未删除：\(relative)")
                }
                guard try checkoutLocalAttributes(local.appendingPathComponent(".svn")) == nil else {
                    throw SVNError.invalid("目标中包含已有 SVN 工作副本，未开始签出：\(relative)")
                }
                directoryCache.insert(relative)
            } else {
                guard type == .typeRegular else {
                    throw SVNError.invalid("本地路径与仓库文件类型冲突，原有项目未删除：\(relative)")
                }
                files.append(CheckoutExistingFile(path: path, attributes: attributes))
            }
        }
    }
    return files
}

private func checkoutLocalAttributes(_ url: URL) throws -> [FileAttributeKey: Any]? {
    do { return try FileManager.default.attributesOfItem(atPath: url.path) }
    catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return nil }
}
