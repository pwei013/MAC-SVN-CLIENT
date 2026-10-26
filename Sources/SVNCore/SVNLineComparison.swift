import Foundation

public enum SVNLineChange: String, Sendable {
    case unchanged, added, deleted, modified
}

public struct SVNComparisonRow: Identifiable, Sendable, Equatable {
    public let id: Int
    public let localNumber: Int?
    public let localText: String?
    public let remoteNumber: Int?
    public let remoteText: String?
    public let change: SVNLineChange

    public init(id: Int, localNumber: Int?, localText: String?, remoteNumber: Int?, remoteText: String?, change: SVNLineChange) {
        self.id = id
        self.localNumber = localNumber
        self.localText = localText
        self.remoteNumber = remoteNumber
        self.remoteText = remoteText
        self.change = change
    }
}

public struct SVNLineComparison: Sendable, Equatable {
    public let rows: [SVNComparisonRow]
    public let addedCount: Int
    public let deletedCount: Int
    public let modifiedCount: Int
    public let notice: String?

    public init(rows: [SVNComparisonRow], addedCount: Int, deletedCount: Int, modifiedCount: Int, notice: String?) {
        self.rows = rows
        self.addedCount = addedCount
        self.deletedCount = deletedCount
        self.modifiedCount = modifiedCount
        self.notice = notice
    }

    /// Align complete local (left) and repository (right) text. Changes are relative
    /// to remote -> local; a local-only row is an addition, a remote-only row a deletion.
    public static func compare(local: String, remote: String) throws -> SVNLineComparison {
        try Task.checkCancellation()
        let left = try ComparisonLines(local, side: "本地")
        let right = try ComparisonLines(remote, side: "对照")
        var builder = LineAlignment(local: left.lines, remote: right.lines)
        try builder.align(local: left.lines.indices, remote: right.lines.indices, depth: 0)
        try Task.checkCancellation()
        var notices: [String] = []
        if builder.usedCoarseAlignment {
            notices.append("部分较大差异块已按行配对显示，未逐行寻找最优对齐；完整内容仍全部保留。")
        }
        if left.endsWithNewline != right.endsWithNewline {
            notices.append(left.endsWithNewline ? "本地文件末尾有换行，对照文件末尾没有换行。" : "本地文件末尾没有换行，对照文件末尾有换行。")
        }
        return SVNLineComparison(rows: builder.rows, addedCount: builder.addedCount,
                                 deletedCount: builder.deletedCount, modifiedCount: builder.modifiedCount,
                                 notice: notices.isEmpty ? nil : notices.joined(separator: "\n"))
    }
}

private struct ComparisonLines {
    let lines: [String]
    let endsWithNewline: Bool

    init(_ original: String, side: String) throws {
        // EOL style is transport metadata in SVN; normalize CRLF/CR before diffing.
        let crlf = original.replacingOccurrences(of: "\r\n", with: "\n")
        try Task.checkCancellation()
        let text = crlf.replacingOccurrences(of: "\r", with: "\n")
        endsWithNewline = text.hasSuffix("\n")
        var result: [String] = []
        var start = text.startIndex
        while let end = text[start...].firstIndex(of: "\n") {
            try Task.checkCancellation()
            guard result.count < 50_000 else { throw Self.tooManyLines(side) }
            result.append(String(text[start..<end]))
            start = text.index(after: end)
        }
        if start != text.endIndex {
            guard result.count < 50_000 else { throw Self.tooManyLines(side) }
            result.append(String(text[start...]))
        }
        // Empty files contain zero lines; a single LF represents one empty line.
        lines = result
    }

    private static func tooManyLines(_ side: String) -> SVNError {
        .invalid("\(side)文件超过 50,000 行，暂不支持全文并排比较。")
    }
}

private struct LineAlignment {
    let local: [String]
    let remote: [String]
    // Swift String equality is canonically equivalent; source comparisons must
    // distinguish NFC/NFD and every other difference in the original UTF-8 bytes.
    private let localKeys: [Data]
    private let remoteKeys: [Data]
    var rows: [SVNComparisonRow] = []
    var addedCount = 0
    var deletedCount = 0
    var modifiedCount = 0
    var usedCoarseAlignment = false
    // These global budgets bound repeated-region work as well as any one block.
    private var anchorVisitBudget = 2_000_000
    private var lcsCellBudget = 2_000_000

    init(local: [String], remote: [String]) {
        self.local = local
        self.remote = remote
        localKeys = local.map { Data($0.utf8) }
        remoteKeys = remote.map { Data($0.utf8) }
        rows.reserveCapacity(max(local.count, remote.count))
    }

    mutating func align(local localRange: Range<Int>, remote remoteRange: Range<Int>, depth: Int) throws {
        try Task.checkCancellation()
        var leftStart = localRange.lowerBound
        var rightStart = remoteRange.lowerBound
        var leftEnd = localRange.upperBound
        var rightEnd = remoteRange.upperBound
        while leftStart < leftEnd, rightStart < rightEnd, localKeys[leftStart] == remoteKeys[rightStart] {
            try checkpoint()
            append(local: leftStart, remote: rightStart, change: .unchanged)
            leftStart += 1
            rightStart += 1
        }
        var suffix = 0
        while leftStart < leftEnd, rightStart < rightEnd, localKeys[leftEnd - 1] == remoteKeys[rightEnd - 1] {
            try checkpoint()
            leftEnd -= 1
            rightEnd -= 1
            suffix += 1
        }
        let left = leftStart..<leftEnd
        let right = rightStart..<rightEnd
        if left.isEmpty || right.isEmpty {
            try appendChangedBlock(local: left, remote: right)
        } else if depth >= 96 || anchorVisitBudget < left.count + right.count {
            usedCoarseAlignment = true
            try appendChangedBlock(local: left, remote: right)
        } else {
            anchorVisitBudget -= left.count + right.count
            let anchors = try uniqueAnchors(local: left, remote: right)
            if !anchors.isEmpty {
                var localCursor = left.lowerBound
                var remoteCursor = right.lowerBound
                for anchor in anchors {
                    try align(local: localCursor..<anchor.local, remote: remoteCursor..<anchor.remote, depth: depth + 1)
                    append(local: anchor.local, remote: anchor.remote, change: .unchanged)
                    localCursor = anchor.local + 1
                    remoteCursor = anchor.remote + 1
                }
                try align(local: localCursor..<left.upperBound, remote: remoteCursor..<right.upperBound, depth: depth + 1)
            } else {
                let cells = (left.count + 1) * (right.count + 1)
                if cells <= 300_000 && cells <= lcsCellBudget {
                    lcsCellBudget -= cells
                    try alignSmallBlock(local: left, remote: right)
                } else {
                    usedCoarseAlignment = true
                    try appendChangedBlock(local: left, remote: right)
                }
            }
        }
        for offset in 0..<suffix {
            try checkpoint()
            append(local: leftEnd + offset, remote: rightEnd + offset, change: .unchanged)
        }
    }

    private struct Anchor {
        let local: Int
        let remote: Int
    }

    private func uniqueAnchors(local left: Range<Int>, remote right: Range<Int>) throws -> [Anchor] {
        var leftOccurrences: [Data: (index: Int, unique: Bool)] = [:]
        var rightOccurrences: [Data: (index: Int, unique: Bool)] = [:]
        for index in left {
            try checkpoint()
            let line = localKeys[index]
            if let existing = leftOccurrences[line] { leftOccurrences[line] = (existing.index, false) }
            else { leftOccurrences[line] = (index, true) }
        }
        for index in right {
            try checkpoint()
            let line = remoteKeys[index]
            if let existing = rightOccurrences[line] { rightOccurrences[line] = (existing.index, false) }
            else { rightOccurrences[line] = (index, true) }
        }
        var pairs: [Anchor] = []
        for index in left {
            try checkpoint()
            let line = localKeys[index]
            if leftOccurrences[line]?.unique == true, let match = rightOccurrences[line], match.unique {
                pairs.append(Anchor(local: index, remote: match.index))
            }
        }
        // Longest increasing subsequence of remote positions. Iterate candidates
        // in local order, never dictionary order, for deterministic tie-breaking.
        var tails: [Int] = []
        var previous = Array(repeating: -1, count: pairs.count)
        for index in pairs.indices {
            try checkpoint()
            var lower = 0
            var upper = tails.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if pairs[tails[middle]].remote < pairs[index].remote { lower = middle + 1 }
                else { upper = middle }
            }
            if lower > 0 { previous[index] = tails[lower - 1] }
            if lower == tails.count { tails.append(index) } else { tails[lower] = index }
        }
        guard var cursor = tails.last else { return [] }
        var result: [Anchor] = []
        while cursor >= 0 {
            try checkpoint()
            result.append(pairs[cursor])
            cursor = previous[cursor]
        }
        return Array(result.reversed())
    }

    private mutating func alignSmallBlock(local left: Range<Int>, remote right: Range<Int>) throws {
        let width = right.count + 1
        var lengths = Array(repeating: Int32(0), count: (left.count + 1) * width)
        for i in stride(from: left.count - 1, through: 0, by: -1) {
            try checkpoint()
            for j in stride(from: right.count - 1, through: 0, by: -1) {
                if j & 255 == 0 { try checkpoint() }
                let position = i * width + j
                if localKeys[left.lowerBound + i] == remoteKeys[right.lowerBound + j] {
                    lengths[position] = lengths[(i + 1) * width + j + 1] + 1
                } else {
                    lengths[position] = max(lengths[(i + 1) * width + j], lengths[position + 1])
                }
            }
        }
        var i = 0
        var j = 0
        var localPending = left.lowerBound
        var remotePending = right.lowerBound
        while i < left.count && j < right.count {
            try checkpoint()
            if localKeys[left.lowerBound + i] == remoteKeys[right.lowerBound + j] {
                try appendChangedBlock(local: localPending..<(left.lowerBound + i), remote: remotePending..<(right.lowerBound + j))
                append(local: left.lowerBound + i, remote: right.lowerBound + j, change: .unchanged)
                i += 1
                j += 1
                localPending = left.lowerBound + i
                remotePending = right.lowerBound + j
            } else if lengths[(i + 1) * width + j] >= lengths[i * width + j + 1] { i += 1 }
            else { j += 1 }
        }
        try appendChangedBlock(local: localPending..<left.upperBound, remote: remotePending..<right.upperBound)
    }

    private mutating func appendChangedBlock(local left: Range<Int>, remote right: Range<Int>) throws {
        let paired = min(left.count, right.count)
        for offset in 0..<paired {
            try checkpoint()
            append(local: left.lowerBound + offset, remote: right.lowerBound + offset, change: .modified)
        }
        for index in (left.lowerBound + paired)..<left.upperBound {
            try checkpoint()
            append(local: index, remote: nil, change: .added)
        }
        for index in (right.lowerBound + paired)..<right.upperBound {
            try checkpoint()
            append(local: nil, remote: index, change: .deleted)
        }
    }

    private mutating func append(local left: Int?, remote right: Int?, change: SVNLineChange) {
        rows.append(SVNComparisonRow(id: rows.count, localNumber: left.map { $0 + 1 }, localText: left.map { local[$0] },
                                     remoteNumber: right.map { $0 + 1 }, remoteText: right.map { remote[$0] }, change: change))
        switch change {
        case .added: addedCount += 1
        case .deleted: deletedCount += 1
        case .modified: modifiedCount += 1
        case .unchanged: break
        }
    }

    private func checkpoint() throws { try Task.checkCancellation() }
}
