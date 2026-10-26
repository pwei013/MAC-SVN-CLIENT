import Foundation

public struct SVNInlineChanges: Sendable, Equatable {
    public let local: [NSRange]
    public let remote: [NSRange]
}

/// UTF-16 ranges can be applied directly to attributed text without splitting
/// composed characters. The shared cell budget keeps all-changed files bounded.
public struct SVNComparisonDecorations: Sendable {
    public let inlineChanges: [Int: SVNInlineChanges]

    public static func prepare(rows: [SVNComparisonRow]) throws -> Self {
        try Task.checkCancellation()
        var result: [Int: SVNInlineChanges] = [:]
        var remainingCells = 2_000_000
        for (index, row) in rows.enumerated() {
            if index.isMultiple(of: 64) { try Task.checkCancellation() }
            guard row.change == .modified, let local = row.localText, let remote = row.remoteText else { continue }
            result[index] = try changes(local: local, remote: remote, remainingCells: &remainingCells)
        }
        return Self(inlineChanges: result)
    }

    private struct Token {
        let bytes: Data
        let range: NSRange
    }

    private static func tokens(_ text: String) -> [Token] {
        var offset = 0
        return text.map { character in
            let value = String(character)
            let length = value.utf16.count
            defer { offset += length }
            return Token(bytes: Data(value.utf8), range: NSRange(location: offset, length: length))
        }
    }

    private static func changes(local: String, remote: String, remainingCells: inout Int) throws -> SVNInlineChanges {
        let localLength = local.utf16.count, remoteLength = remote.utf16.count
        // Very long lines keep their accurate line tint. Avoid tokenizing a
        // potentially enormous grapheme or building a large character matrix.
        guard localLength <= 8_192, remoteLength <= 8_192 else {
            return SVNInlineChanges(local: localLength == 0 ? [] : [NSRange(location: 0, length: localLength)],
                                    remote: remoteLength == 0 ? [] : [NSRange(location: 0, length: remoteLength)])
        }
        let a = tokens(local), b = tokens(remote)
        var start = 0
        while start < min(a.count, b.count), a[start].bytes == b[start].bytes { start += 1 }
        var endA = a.count, endB = b.count
        while endA > start, endB > start, a[endA - 1].bytes == b[endB - 1].bytes { endA -= 1; endB -= 1 }
        let m = endA - start, n = endB - start
        guard m > 0 || n > 0 else { return SVNInlineChanges(local: [], remote: []) }
        func range(_ values: [Token], _ from: Int, _ to: Int) -> [NSRange] {
            guard from < to else { return [] }
            let first = values[from].range, last = values[to - 1].range
            return [NSRange(location: first.location, length: NSMaxRange(last) - first.location)]
        }
        let cells = (m + 1) * (n + 1)
        guard m <= 512, n <= 512, cells <= 65_536, cells <= remainingCells else {
            return SVNInlineChanges(local: range(a, start, endA), remote: range(b, start, endB))
        }
        remainingCells -= cells
        let width = n + 1
        var matrix = [UInt16](repeating: 0, count: cells)
        if m > 0, n > 0 {
            for i in stride(from: m - 1, through: 0, by: -1) {
                if i.isMultiple(of: 32) { try Task.checkCancellation() }
                for j in stride(from: n - 1, through: 0, by: -1) {
                    matrix[i * width + j] = a[start + i].bytes == b[start + j].bytes ?
                        matrix[(i + 1) * width + j + 1] + 1 : max(matrix[(i + 1) * width + j], matrix[i * width + j + 1])
                }
            }
        }
        var changedA: [Int] = [], changedB: [Int] = []
        var i = 0, j = 0
        while i < m || j < n {
            if i < m, j < n, a[start + i].bytes == b[start + j].bytes { i += 1; j += 1 }
            else if i < m, j == n || matrix[(i + 1) * width + j] >= matrix[i * width + j + 1] {
                changedA.append(start + i); i += 1
            } else { changedB.append(start + j); j += 1 }
        }
        func merged(_ indexes: [Int], _ values: [Token]) -> [NSRange] {
            var ranges: [NSRange] = []
            for index in indexes {
                let next = values[index].range
                if let previous = ranges.last, NSMaxRange(previous) == next.location {
                    ranges[ranges.count - 1].length += next.length
                } else { ranges.append(next) }
            }
            return ranges
        }
        return SVNInlineChanges(local: merged(changedA, a), remote: merged(changedB, b))
    }
}

/// A compact table-to-source mapping. The table still draws only visible rows;
/// source line numbers and copied contents always come from the original rows.
public struct SVNDiffRowMap: Sendable {
    public let sourceIndexes: [Int]
    public let hiddenCount: Int
    public let gapBefore: Set<Int>

    public func displayIndex(forSource source: Int) -> Int? {
        var low = 0, high = sourceIndexes.count
        while low < high {
            let mid = low + (high - low) / 2
            if sourceIndexes[mid] < source { low = mid + 1 } else { high = mid }
        }
        return sourceIndexes.indices.contains(low) && sourceIndexes[low] == source ? low : nil
    }

    public static func make(rows: [SVNComparisonRow], changesOnly: Bool, context: Int = 3) throws -> Self {
        try Task.checkCancellation()
        if !changesOnly { return Self(sourceIndexes: Array(rows.indices), hiddenCount: 0, gapBefore: []) }
        let radius = max(0, min(context, 20))
        var indexes: [Int] = []
        var gaps = Set<Int>()
        var last = -1
        var visibleThrough = -1
        for (index, row) in rows.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard row.change != .unchanged else { continue }
            let start = max(max(index - radius, visibleThrough + 1), 0)
            let end = min(rows.count - 1, index + radius)
            guard start <= end else { continue }
            if start > last + 1 { gaps.insert(indexes.count) }
            for source in start...end { indexes.append(source) }
            last = end
            visibleThrough = end
        }
        return Self(sourceIndexes: indexes, hiddenCount: rows.count - indexes.count, gapBefore: gaps)
    }
}

public enum SVNCodeTokenKind: String, Sendable { case keyword, string, number, comment, directive, tag }
public struct SVNCodeToken: Sendable, Equatable {
    public let range: NSRange
    public let kind: SVNCodeTokenKind
}

/// A deliberately small, per-line lexer, used only for visible rows. No global
/// regex/backtracking, filesystem access, or full-document scan occurs on scroll.
public enum SVNCodeStyling {
    private static let keywords: Set<String> = Set(("abstract as async await base bool break case catch class const continue " +
        "default delegate do double else enum event explicit export extends false final finally float for foreach from func function " +
        "get if implements import in int interface internal is let lock long namespace new nil null object of operator out override " +
        "package partial private protected public readonly ref return sealed select set short static string struct super switch " +
        "this throw throws true try type typeof uint ulong using var virtual void volatile when where while yield " +
        "def elif except None True False lambda pass raise with and or not self").split(separator: " ").map(String.init))

    public static func tokens(in text: String, language: String = "", limit: Int = 8_192) throws -> [SVNCodeToken] {
        try Task.checkCancellation()
        let units = Array(text.utf16.prefix(max(0, min(limit, 8_192))))
        var result: [SVNCodeToken] = []
        var i = 0
        func word(_ value: UInt16) -> Bool { (65...90).contains(value) || (97...122).contains(value) || value == 95 || value > 127 }
        while i < units.count {
            if i.isMultiple(of: 128) { try Task.checkCancellation() }
            if result.count >= 256 { break }
            let start = i, value = units[i]
            if ["xml", "html", "htm", "xaml", "csproj", "vbproj", "props", "targets", "config", "plist", "svg"].contains(language), value == 60 {
                i += 1
                if i < units.count, [47, 63, 33].contains(units[i]) { i += 1 }
                while i < units.count, word(units[i]) || [45, 58, 46].contains(units[i]) { i += 1 }
                result.append(SVNCodeToken(range: NSRange(location: start, length: i - start), kind: .tag)); continue
            }
            if value == 47, i + 1 < units.count, units[i + 1] == 47 {
                result.append(SVNCodeToken(range: NSRange(location: i, length: units.count - i), kind: .comment)); break
            }
            if value == 35 {
                result.append(SVNCodeToken(range: NSRange(location: i, length: units.count - i), kind: .directive)); break
            }
            if value == 34 || value == 39 || value == 96 {
                i += 1
                while i < units.count {
                    if units[i] == 92 { i = min(units.count, i + 2) }
                    else if units[i] == value { i += 1; break }
                    else { i += 1 }
                }
                result.append(SVNCodeToken(range: NSRange(location: start, length: i - start), kind: .string))
            } else if (48...57).contains(value) {
                i += 1
                while i < units.count, (48...57).contains(units[i]) || units[i] == 46 { i += 1 }
                result.append(SVNCodeToken(range: NSRange(location: start, length: i - start), kind: .number))
            } else if word(value) {
                i += 1
                while i < units.count, word(units[i]) || (48...57).contains(units[i]) { i += 1 }
                if keywords.contains(String(decoding: units[start..<i], as: UTF16.self)) {
                    result.append(SVNCodeToken(range: NSRange(location: start, length: i - start), kind: .keyword))
                }
            } else { i += 1 }
        }
        return result
    }
}
