import Foundation
import SVNCore

struct ComparisonDecorationTests {
    func testCharacterChangesKeepUnicodeRangesAndSeparateEdits() throws {
        let local = "var 👨‍👩‍👧‍👦值 = 20; // new"
        let remote = "var 👩‍💻值 = 10; // old"
        let row = SVNComparisonRow(id: 0, localNumber: 1, localText: local, remoteNumber: 1, remoteText: remote, change: .modified)
        let decoration = try SVNComparisonDecorations.prepare(rows: [row])
        let changes = try require(decoration.inlineChanges[0])
        let left = changes.local.map { (local as NSString).substring(with: $0) }.joined(separator: "|")
        let right = changes.remote.map { (remote as NSString).substring(with: $0) }.joined(separator: "|")
        try expect(left.contains("👨‍👩‍👧‍👦") && right.contains("👩‍💻"))
        try expect(left.contains("2") && left.contains("new") && right.contains("1") && right.contains("old"))
        try expect(!left.contains("var") && !left.contains("值"), "Unchanged identifiers must not be emphasized")
        for range in changes.local {
            try expect((local as NSString).rangeOfComposedCharacterSequences(for: range) == range)
        }
        let canonical = SVNComparisonRow(id: 1, localNumber: 1, localText: "\u{E9}", remoteNumber: 1, remoteText: "e\u{301}", change: .modified)
        let canonicalChanges = try require(SVNComparisonDecorations.prepare(rows: [canonical]).inlineChanges[0])
        try expect(canonicalChanges.local == [NSRange(location: 0, length: 1)] && canonicalChanges.remote == [NSRange(location: 0, length: 2)], "Canonical equivalence must not hide byte-level source edits")
        let insertion = SVNComparisonRow(id: 2, localNumber: 1, localText: "a🚀b", remoteNumber: 1, remoteText: "ab", change: .modified)
        let inserted = try require(SVNComparisonDecorations.prepare(rows: [insertion]).inlineChanges[0])
        try expect(inserted.local == [NSRange(location: 1, length: 2)] && inserted.remote.isEmpty)
    }

    func testCollapsedContextMapsOriginalRowsWithoutDuplicates() throws {
        let rows = (0..<100).map { index in
            SVNComparisonRow(id: index, localNumber: index + 1, localText: "line\(index)", remoteNumber: index + 1,
                             remoteText: "line\(index)", change: [10, 12, 80].contains(index) ? .modified : .unchanged)
        }
        let map = try SVNDiffRowMap.make(rows: rows, changesOnly: true)
        let expected = Array(7...15) + Array(77...83)
        try expect(map.sourceIndexes == expected && map.hiddenCount == 84)
        try expect(map.gapBefore == Set([0, 9]))
        try expect(map.displayIndex(forSource: 10) == 3 && map.displayIndex(forSource: 80) == 12)
        try expect(map.displayIndex(forSource: 50) == nil && map.displayIndex(forSource: -1) == nil)
        let all = try SVNDiffRowMap.make(rows: rows, changesOnly: false)
        try expect(all.sourceIndexes == Array(0..<100) && all.hiddenCount == 0 && all.gapBefore.isEmpty)
        let noChanges = try SVNDiffRowMap.make(rows: Array(rows[20...30]), changesOnly: true)
        try expect(noChanges.sourceIndexes.isEmpty && noChanges.hiddenCount == 11)
        let empty = try SVNDiffRowMap.make(rows: [], changesOnly: true)
        try expect(empty.sourceIndexes.isEmpty && empty.hiddenCount == 0)
    }

    func testVisibleCodeStylingUsesBoundedLiteralTokens() throws {
        let text = "public static int value = 42; var name = \"return // text\"; // comment"
        let tokens = try SVNCodeStyling.tokens(in: text, language: "cs")
        let values = tokens.map { ((text as NSString).substring(with: $0.range), $0.kind) }
        try expect(values.contains { $0.0 == "public" && $0.1 == .keyword })
        try expect(values.contains { $0.0 == "42" && $0.1 == .number })
        try expect(values.contains { $0.0 == "\"return // text\"" && $0.1 == .string })
        try expect(values.last?.0 == "// comment" && values.last?.1 == .comment)
        let xml = "<Project Sdk=\"Microsoft.NET.Sdk\"><PropertyGroup>"
        let xmlTokens = try SVNCodeStyling.tokens(in: xml, language: "csproj")
        try expect(xmlTokens.filter { $0.kind == .tag }.map { (xml as NSString).substring(with: $0.range) } == ["<Project", "<PropertyGroup"])
        let long = String(repeating: "public 42; ", count: 20_000)
        let limited = try SVNCodeStyling.tokens(in: long, language: "cs")
        try expect(limited.count <= 256 && limited.allSatisfy { NSMaxRange($0.range) <= 8_192 })
    }

    func testCharacterBudgetAndVeryLongLinesRemainBounded() throws {
        let row = SVNComparisonRow(id: 0, localNumber: 1, localText: String(repeating: "new", count: 20_000), remoteNumber: 1,
                                   remoteText: String(repeating: "old", count: 20_000), change: .modified)
        let changes = try require(SVNComparisonDecorations.prepare(rows: [row]).inlineChanges[0])
        try expect(changes.local == [NSRange(location: 0, length: 60_000)] && changes.remote == changes.local)
        let budgetRows = (0..<500).map { index in
            SVNComparisonRow(id: index, localNumber: index + 1, localText: String(repeating: "a", count: 128), remoteNumber: index + 1,
                             remoteText: String(repeating: "b", count: 128), change: .modified)
        }
        let budget = try SVNComparisonDecorations.prepare(rows: budgetRows)
        try expect(budget.inlineChanges.count == 500 && budget.inlineChanges.values.allSatisfy { $0.local == [NSRange(location: 0, length: 128)] && $0.remote == $0.local })
    }

    func testDecorationAndContextCancellation() async throws {
        let worker = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try SVNComparisonDecorations.prepare(rows: []); throw CheckFailure.failed("Expected cancellation") }
            catch is CancellationError { }
            do { _ = try SVNDiffRowMap.make(rows: [], changesOnly: false); throw CheckFailure.failed("Expected cancellation") }
            catch is CancellationError { }
            do { _ = try SVNCodeStyling.tokens(in: "public"); throw CheckFailure.failed("Expected cancellation") }
            catch is CancellationError { }
        }
        try await worker.value
    }
}
