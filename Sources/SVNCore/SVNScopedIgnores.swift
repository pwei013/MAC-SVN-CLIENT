import Foundation

public enum SVNIgnoreScope: String, CaseIterable, Identifiable, Sendable {
    case userGlobal, currentDirectory, directoryTree

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .userGlobal: return "用户全局"
        case .currentDirectory: return "仅当前目录"
        case .directoryTree: return "当前目录及所有子目录"
        }
    }
    public var propertyName: String? {
        switch self {
        case .userGlobal: return nil
        case .currentDirectory: return "svn:ignore"
        case .directoryTree: return "svn:global-ignores"
        }
    }

    public func suggestions(forName name: String, isDirectory: Bool) -> [SVNIgnoreSuggestion] {
        if self == .userGlobal { return SVNGlobalIgnores.suggestions(forName: name, isDirectory: isDirectory) }
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return [] }
        func literal(_ value: String) -> String {
            value.unicodeScalars.map { "*?[]\\".unicodeScalars.contains($0) ? "\\" + String($0) : String($0) }.joined()
        }
        var values = [SVNIgnoreSuggestion(kind: isDirectory ? .directoryName : .fileName,
            pattern: literal(name), usesWhitespaceWildcard: false)]
        let suffix = (name as NSString).pathExtension
        if !isDirectory, !suffix.isEmpty {
            values.append(SVNIgnoreSuggestion(kind: .fileExtension, pattern: "*." + literal(suffix), usesWhitespaceWildcard: false))
        }
        return values
    }
}

extension SVNClient {
    public func addDirectoryIgnore(at directory: URL, path: String, suggestion: SVNIgnoreSuggestion,
                                   scope: SVNIgnoreScope, backupDirectory: URL? = nil) async throws -> SVNDirectoryIgnoreSaveResult {
        guard let property = scope.propertyName else {
            throw SVNError.invalid("用户全局范围请保存到 SVN 用户配置，不能写入目录属性。")
        }
        _ = try paths([path], at: directory)
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard directory.isFileURL, components.allSatisfy({ !$0.isEmpty && ![".", "..", ".svn"].contains($0) }) else {
            throw SVNError.invalid("无效的忽略项目路径。")
        }
        let target = directory.appendingPathComponent(path).standardizedFileURL
        let parent = target.deletingLastPathComponent()
        let baseline = try await directoryIgnoreSettings(at: parent)
        let openedInfo = try await info(at: directory)
        guard baseline.workingCopyRoot == URL(fileURLWithPath: openedInfo.rootPath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath() else {
            throw SVNError.invalid("所选项目不在当前 SVN 工作副本中，未修改忽略规则。")
        }
        let values: URLResourceValues
        do { values = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) }
        catch { throw SVNError.invalid("所选项目已不存在或无法读取，请刷新后重试。") }
        let isDirectory = values.isDirectory == true && values.isSymbolicLink != true
        guard scope.suggestions(forName: target.lastPathComponent, isDirectory: isDirectory).contains(suggestion) else {
            throw SVNError.invalid("忽略规则与所选项目不一致，请重新选择。")
        }
        let status = try SVNXML.parseStatus(await execute("status", ["--xml", "--ignore-externals", "--no-ignore", "--depth", "empty", "--", target.path + "@"]).stdout)
        guard status.count == 1, status.first?.item == "unversioned", status.first?.treeConflicted == false,
              status.first?.path == target.path else {
            throw SVNError.invalid("所选项目已不再是未跟踪状态，请刷新后重新选择忽略；本次未修改规则。")
        }
        let original = property == "svn:ignore" ? baseline.ignore : baseline.globalIgnores
        var text = original ?? ""
        let existing = text.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
        if !existing.contains(suggestion.pattern) {
            if !text.isEmpty, !text.hasSuffix("\n"), !text.hasSuffix("\r") { text += "\n" }
            text += suggestion.pattern + "\n"
        }
        return try await saveDirectoryIgnoreProperty(using: baseline, name: property, value: text, backupDirectory: backupDirectory)
    }
}
