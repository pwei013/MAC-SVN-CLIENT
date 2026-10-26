import Foundation
import Darwin

public struct SVNIgnoreSuggestion: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case fileName, directoryName, fileExtension }
    public var id: String { pattern }
    public let kind: Kind
    public let pattern: String
    public let usesWhitespaceWildcard: Bool

    public var title: String {
        switch kind {
        case .fileName: return "按文件名：\(pattern)"
        case .directoryName: return "按文件夹名：\(pattern)"
        case .fileExtension: return "按扩展名：\(pattern)"
        }
    }
}

/// Application rules extend Subversion's runtime ignore list; no config or properties are written.
public enum SVNGlobalIgnores {
    // Subversion 1.14's Unix defaults (svn_config.h).
    public static let defaultPatterns = [
        "*.o", "*.lo", "*.la", "*.al", ".libs", "*.so", "*.so.[0-9]*", "*.a", "*.pyc", "*.pyo", "__pycache__",
        "*.rej", "*~", "#*#", ".#*", ".*.swp", ".DS_Store", "[Tt]humbs.db"
    ]

    /// SVN global-ignores is a whitespace-delimited list of basename globs.
    public static func parse(_ text: String) throws -> [String] {
        guard !text.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) && ![9, 10, 13].contains($0.value)
        }) else { throw SVNError.invalid("忽略规则不能包含控制字符。") }
        return try validated(text.split(whereSeparator: \.isWhitespace).map(String.init))
    }

    /// Escape literal glob syntax so choosing a filename cannot accidentally ignore its peers.
    /// SVN splits rules on whitespace without quoting; show '?' explicitly for such names.
    public static func suggestions(forName name: String, isDirectory: Bool) -> [SVNIgnoreSuggestion] {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return [] }
        func literalPattern(_ value: String) -> String {
            value.unicodeScalars.map { scalar in
                if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    // APR's glob matcher consumes UTF-8 bytes, including Unicode whitespace.
                    return String(repeating: "?", count: String(scalar).utf8.count)
                }
                if "*?[]\\".unicodeScalars.contains(scalar) { return "\\" + String(scalar) }
                // Prevent SVN config interpolation even for a literal name like '%(name)s'.
                if scalar == "%" { return "[%]" }
                return String(scalar)
            }.joined()
        }
        func usesWhitespace(_ value: String) -> Bool {
            value.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) }
        }
        var result = [SVNIgnoreSuggestion(kind: isDirectory ? .directoryName : .fileName,
                                          pattern: literalPattern(name), usesWhitespaceWildcard: usesWhitespace(name))]
        let suffix = (name as NSString).pathExtension
        if !isDirectory, !suffix.isEmpty {
            result.append(SVNIgnoreSuggestion(kind: .fileExtension, pattern: "*." + literalPattern(suffix),
                                              usesWhitespaceWildcard: usesWhitespace(suffix)))
        }
        return result
    }

    /// Like APR's SVN glob matcher, match case-sensitive basename bytes, independent
    /// of the GUI's locale. The temporary locale is confined to this synchronous thread.
    public static func matchingPatterns(forName name: String, in patterns: [String]) throws -> [String] {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0") else {
            throw SVNError.invalid("无效的忽略项目名称。")
        }
        let patterns = try validated(patterns)
        guard let locale = newlocale(LC_CTYPE_MASK, "C", nil) else {
            throw SVNError.invalid("无法检查忽略规则，请稍后重试。")
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

    /// A nil file list reads the standard Unix sources; supplying URLs isolates tests.
    /// An empty app rule list returns nil without reading or overriding SVN configuration.
    public static func configurationOption(additional patterns: [String], configurationFiles: [URL]? = nil) throws -> String? {
        let additional = try validated(patterns)
        guard !additional.isEmpty else { return nil }
        let files = configurationFiles ?? [
            URL(fileURLWithPath: "/etc/subversion/config"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".subversion/config")
        ]
        var configuration = IgnoreConfiguration()
        for file in files {
            let data: Data
            do { data = try Data(contentsOf: file) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                continue
            } catch { throw SVNError.invalid("无法读取现有 SVN 忽略配置，已停止操作以保留原规则。") }
            guard let text = String(data: data, encoding: .utf8) else {
                throw SVNError.invalid("现有 SVN 配置不是有效 UTF-8，无法安全合并忽略规则。")
            }
            try configuration.merge(text)
        }
        // Keep interpolation intact: SVN expands it against its original config sections.
        // An explicitly empty value overrides both system values and compiled-in defaults.
        let original = configuration.effectiveValue ?? defaultPatterns.joined(separator: " ")
        return "config:miscellany:global-ignores=" + original + (original.isEmpty ? "" : " ") + additional.joined(separator: " ")
    }

    private static func validated(_ patterns: [String]) throws -> [String] {
        var seen = Set<String>()
        return try patterns.filter { pattern in
            guard !pattern.isEmpty,
                  !pattern.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }),
                  !pattern.contains("/"), !pattern.contains("%("),
                  pattern != ".", pattern != ".." else {
                throw SVNError.invalid("忽略规则请填写文件夹名或文件名通配符（例如 bin、obj、*.log），以换行或空白分隔；不支持路径和配置插值。")
            }
            return seen.insert(pattern).inserted
        }
    }
}

private struct IgnoreConfiguration {
    private var hasMiscellany = false
    private var values: [String: String] = [:]
    var effectiveValue: String? { hasMiscellany ? values["miscellany"] ?? values["default"] : nil }

    mutating func merge(_ rawText: String) throws {
        guard !rawText.contains("\0") else { throw invalidConfiguration() }
        var text = rawText.replacingOccurrences(of: "\r", with: "")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var section: String?
        var pendingSection: String?
        var pendingValue: String?
        var canContinue = false

        let whitespace = CharacterSet(charactersIn: " \t\n\r\u{0B}\u{0C}")
        func trimmed(_ value: String) -> String { value.trimmingCharacters(in: whitespace) }
        func commitPending() {
            if let pendingSection, let pendingValue { values[pendingSection] = pendingValue }
        }

        for line in text.components(separatedBy: "\n") {
            let value = trimmed(line)
            let indented = line.unicodeScalars.first.map { whitespace.contains($0) } == true
            // In SVN, every indented nonempty line immediately after an option is
            // a continuation, including a line beginning with '#'. Blank lines end it.
            if indented && !value.isEmpty && canContinue {
                if pendingValue != nil { pendingValue! += " " + value }
                continue
            }
            commitPending()
            pendingSection = nil
            pendingValue = nil
            canContinue = false
            if value.isEmpty { continue }
            guard !indented else { throw invalidConfiguration() }
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                guard let end = line.firstIndex(of: "]") else { throw invalidConfiguration() }
                let name = String(line[line.index(after: line.startIndex)..<end]).lowercased()
                guard !name.isEmpty else { throw invalidConfiguration() }
                section = name
                if name == "miscellany" { hasMiscellany = true }
                continue
            }
            guard let section,
                  let separator = line.firstIndex(where: { $0 == ":" || $0 == "=" }) else { throw invalidConfiguration() }
            let name = trimmed(String(line[..<separator])).lowercased()
            guard !name.isEmpty else { throw invalidConfiguration() }
            canContinue = true
            if name == "global-ignores", section == "miscellany" || section == "default" {
                pendingSection = section
                pendingValue = trimmed(String(line[line.index(after: separator)...]))
            }
        }
        commitPending()
    }

    private func invalidConfiguration() -> SVNError {
        SVNError.invalid("现有 SVN 配置格式无法安全解析，已停止操作以保留原忽略规则。")
    }
}
