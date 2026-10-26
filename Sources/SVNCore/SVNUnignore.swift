import Foundation
import Darwin

enum SVNIgnorePatternMatcher {
    static func matching(name: String, patterns: [String]) throws -> [String] {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0"),
              !patterns.contains(where: { $0.contains("\0") }),
              let locale = newlocale(LC_CTYPE_MASK, "C", nil) else {
            throw SVNError.invalid("无法安全匹配忽略规则。")
        }
        guard let previous = uselocale(locale) else {
            freelocale(locale)
            throw SVNError.invalid("无法检查忽略规则，请稍后重试。")
        }
        defer { uselocale(previous); freelocale(locale) }
        return patterns.filter { pattern in
            pattern.withCString { glob in name.withCString { fnmatch(glob, $0, 0) == 0 } }
        }
    }
}

public struct SVNIgnorePropertyValue: Sendable {
    public let source: String
    public let name: String
    public let value: String
    public let inherited: Bool
}

public struct SVNIgnorePropertyEdit: Sendable, Identifiable {
    public var id: String { directory.path + "#" + name }
    public let directory: URL
    public let name: String
    public let removedPatterns: [String]
    let originalValue: String
    let updatedValue: String?

    static func prepare(directory: URL, name: String, value: String, basename: String) throws -> Self? {
        // Property rules are newline-delimited, and spaces inside a line are literal.
        // Preserve every unmatched line and its original CR/LF terminator byte-for-byte.
        let bytes = Array(value.utf8)
        var lines: [(pattern: String, raw: String)] = []
        var start = 0
        var index = 0
        while index < bytes.count {
            if bytes[index] == 10 || bytes[index] == 13 {
                let end = index
                if bytes[index] == 13, index + 1 < bytes.count, bytes[index + 1] == 10 { index += 1 }
                index += 1
                lines.append((String(decoding: bytes[start..<end], as: UTF8.self),
                              String(decoding: bytes[start..<index], as: UTF8.self)))
                start = index
            } else { index += 1 }
        }
        if start < bytes.count {
            let tail = String(decoding: bytes[start...], as: UTF8.self)
            lines.append((tail, tail))
        }
        let matches = try SVNIgnorePatternMatcher.matching(name: basename, patterns: lines.map(\.pattern))
        guard !matches.isEmpty else { return nil }
        let removed = Set(matches)
        let kept = lines.filter { !removed.contains($0.pattern) }
        return Self(directory: directory, name: name, removedPatterns: Array(Set(matches)).sorted(),
                    originalValue: value, updatedValue: kept.contains(where: { !$0.pattern.isEmpty }) ? kept.map(\.raw).joined() : nil)
    }
}

public struct SVNUnignorePlan: Sendable {
    public let directory: URL
    public let path: String
    public let workingCopyRoot: URL
    public let originalAppPatterns: [String]
    public let appPatterns: [String]
    public let configuration: SVNIgnoreConfigEdit?
    public let properties: [SVNIgnorePropertyEdit]
    public var remainingAppPatterns: [String] {
        let removed = Set(appPatterns)
        return originalAppPatterns.filter { !removed.contains($0) }
    }
}

public struct SVNUnignoreResult: Sendable {
    public let backups: [URL]
    public let propertyDirectories: [URL]
}

extension SVNClient {
    public func prepareUnignore(at directory: URL, path: String) async throws -> SVNUnignorePlan {
        _ = try paths([path], at: directory)
        try await requireIgnored(at: directory, path: path)
        let info = try await info(at: directory)
        let root = URL(fileURLWithPath: info.rootPath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let parent = directory.appendingPathComponent(path).standardizedFileURL.deletingLastPathComponent()
        let values = try await readIgnoreProperties([parent], inherited: true)
        let basename = (path as NSString).lastPathComponent
        let appPatterns = try SVNGlobalIgnores.matchingPatterns(forName: basename, in: additionalGlobalIgnores)
        let configuration = try SVNIgnoreConfigEdit.prepare(forName: basename, configurationFiles: globalIgnoreConfigurationFiles)
        var properties: [SVNIgnorePropertyEdit] = []
        for value in values where value.name == "svn:global-ignores" || !value.inherited {
            let matches = try SVNIgnorePatternMatcher.matching(name: basename,
                patterns: value.value.components(separatedBy: CharacterSet(charactersIn: "\r\n")))
            guard !matches.isEmpty else { continue }
            guard !value.source.contains("://") else {
                throw SVNError.invalid("匹配的继承忽略规则位于尚未签出的仓库上级目录。请先签出规则所在目录，再在工具中取消忽略；本次未修改任何规则。")
            }
            let source = value.source.hasPrefix("/") ? URL(fileURLWithPath: value.source, isDirectory: true) :
                directory.appendingPathComponent(value.source, isDirectory: true)
            let local = source.standardizedFileURL.resolvingSymlinksInPath()
            guard local == root || local.path.hasPrefix(root.path + "/"),
                  parent.resolvingSymlinksInPath() == local || parent.resolvingSymlinksInPath().path.hasPrefix(local.path + "/") else {
                throw SVNError.invalid("忽略属性来源超出当前工作副本，已停止操作。")
            }
            if let edit = try SVNIgnorePropertyEdit.prepare(directory: local, name: value.name, value: value.value, basename: basename) {
                properties.append(edit)
            }
        }
        guard !appPatterns.isEmpty || configuration != nil || !properties.isEmpty else {
            throw SVNError.invalid("未能定位匹配的忽略规则，请刷新工作副本及 SVN 配置后重试。")
        }
        let plan = SVNUnignorePlan(directory: directory, path: path, workingCopyRoot: root,
                                  originalAppPatterns: additionalGlobalIgnores, appPatterns: appPatterns,
                                  configuration: configuration, properties: properties.sorted { $0.id < $1.id })
        try await validatePropertyNodes(plan)
        return plan
    }

    public func applyUnignore(_ plan: SVNUnignorePlan, backupDirectory: URL? = nil) async throws -> SVNUnignoreResult {
        try await validateUnignore(plan)
        try Task.checkCancellation()
        var backups: [URL] = []
        var journal: URL?
        if !plan.properties.isEmpty {
            let base = backupDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "SVNManager", isDirectory: true)
                .appendingPathComponent("IgnoreBackups", isDirectory: true)
            let folder = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for (index, edit) in plan.properties.enumerated() {
                let file = folder.appendingPathComponent("\(index)-original-property.txt")
                try writeSVNIgnoreFileExclusive(Data(edit.originalValue.utf8), to: file, permissions: 0o600, ownership: nil)
                guard try Data(contentsOf: file) == Data(edit.originalValue.utf8) else {
                    throw SVNError.invalid("属性备份验证失败，未修改忽略规则。")
                }
                backups.append(file)
            }
            let entries = plan.properties.enumerated().map { index, edit in
                ["directory": edit.directory.path, "property": edit.name, "originalFile": "\(index)-original-property.txt"]
            }
            let manifest = folder.appendingPathComponent("sources.json")
            try writeSVNIgnoreFileExclusive(try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys]),
                                           to: manifest, permissions: 0o600, ownership: nil)
            journal = folder
        }
        do {
            if let backup = try plan.configuration?.apply() { backups.append(backup) }
            for (index, edit) in plan.properties.enumerated() {
                // Check again immediately before each write; other properties are never changed.
                let current = try await readIgnoreProperties([edit.directory], inherited: false)
                guard current.first(where: { $0.name == edit.name })?.value == edit.originalValue else {
                    throw SVNError.invalid("目录属性已变化，已停止后续修改。")
                }
                if let value = edit.updatedValue, let journal {
                    let file = journal.appendingPathComponent("\(index)-updated-property.txt")
                    try writeSVNIgnoreFileExclusive(Data(value.utf8), to: file, permissions: 0o600, ownership: nil)
                    _ = try await execute("propset", [edit.name, "--file", file.path, "--", edit.directory.path + "@"])
                } else {
                    _ = try await execute("propdel", [edit.name, "--", edit.directory.path + "@"])
                }
                let confirmed = try await readIgnoreProperties([edit.directory], inherited: false)
                guard confirmed.first(where: { $0.name == edit.name })?.value == edit.updatedValue else {
                    throw SVNError.invalid("属性写入后读回不一致，已停止后续修改。")
                }
            }
            let candidate = SVNClient(executablePath: executablePath, credentials: credentials,
                                      additionalGlobalIgnores: plan.remainingAppPatterns,
                                      globalIgnoreConfigurationFiles: globalIgnoreConfigurationFiles)
            let status = try await candidate.targetStatus(at: plan.directory, path: plan.path)
            guard status.contains(where: { $0.item == "unversioned" }) else {
                throw SVNError.invalid("修改后的 SVN 状态未确认恢复为未跟踪，请刷新检查。")
            }
        } catch {
            let locations = ([journal].compactMap { $0 } + backups).map(\.path).joined(separator: "\n")
            throw SVNError.invalid("取消忽略未完整确认，部分本地配置或属性可能已修改。请刷新并检查后再操作，未自动重试或提交。\n备份位置：\n\(locations)\n\(error.localizedDescription)")
        }
        return SVNUnignoreResult(backups: backups,
                                 propertyDirectories: Array(Set(plan.properties.map(\.directory))).sorted { $0.path < $1.path })
    }

    private func targetStatus(at directory: URL, path: String) async throws -> [WorkingCopyChange] {
        let arguments = ["--xml", "--ignore-externals", "--no-ignore", "--depth", "empty", "--"] + (try paths([path], at: directory))
        return try SVNXML.parseStatus(await execute("status", arguments, at: directory).stdout)
    }

    private func requireIgnored(at directory: URL, path: String) async throws {
        guard try await targetStatus(at: directory, path: path).contains(where: { $0.item == "ignored" }) else {
            throw SVNError.invalid("该项目的忽略状态已变化，请刷新列表后重试。")
        }
    }

    private func readIgnoreProperties(_ directories: [URL], inherited: Bool) async throws -> [SVNIgnorePropertyValue] {
        var arguments = ["--xml", "--verbose", "--depth", "empty"]
        if inherited { arguments.append("--show-inherited-props") }
        return try SVNXML.ignoreProperties(await execute("proplist", arguments + ["--"] + directories.map { $0.path + "@" }).stdout)
    }

    private func validateUnignore(_ plan: SVNUnignorePlan) async throws {
        guard additionalGlobalIgnores == plan.originalAppPatterns else {
            throw SVNError.invalid("全局过滤规则已变化，请重新检查后确认。")
        }
        try plan.configuration?.validateUnchanged()
        let current = try await prepareUnignore(at: plan.directory, path: plan.path)
        guard current.workingCopyRoot == plan.workingCopyRoot,
              current.appPatterns == plan.appPatterns,
              current.configuration?.file == plan.configuration?.file,
              current.configuration?.originalData == plan.configuration?.originalData,
              current.configuration?.updatedData == plan.configuration?.updatedData,
              current.properties.map(\.id) == plan.properties.map(\.id),
              zip(current.properties, plan.properties).allSatisfy({ $0.originalValue == $1.originalValue }) else {
            throw SVNError.invalid("忽略规则或来源在确认期间已变化，请重新检查后确认；本次未修改规则。")
        }
    }

    private func validatePropertyNodes(_ plan: SVNUnignorePlan) async throws {
        if !plan.properties.isEmpty {
            let nodes = Array(Set(plan.properties.map(\.directory)))
            let values = try await readIgnoreProperties(nodes, inherited: false)
            for edit in plan.properties {
                guard values.contains(where: { URL(fileURLWithPath: $0.source).standardizedFileURL.resolvingSymlinksInPath() == edit.directory && $0.name == edit.name && $0.value == edit.originalValue }) else {
                    throw SVNError.invalid("目录属性已变化，请重新检查后确认。")
                }
            }
            let statuses = try SVNXML.parseStatus(await execute("status", ["--xml", "--depth", "empty", "--"] + nodes.map { $0.path + "@" }).stdout)
            guard !statuses.contains(where: { $0.treeConflicted || $0.properties == "conflicted" || ["conflicted", "deleted", "missing", "obstructed"].contains($0.item) }) else {
                throw SVNError.invalid("忽略属性所在目录存在冲突或异常，请先处理后再取消忽略。")
            }
        }
    }
}
