import Foundation
import SVNCore

struct LineComparisonTests {
    func testAlignmentPreservesNumbersAndClassifiesChanges() throws {
        let remote = ["header", "remove only", "same", "old one", "old two", "end"]
        let local = ["header", "same", "new one", "new two", "extra", "end"]
        let result = try SVNLineComparison.compare(local: local.joined(separator: "\n") + "\n",
                                                   remote: remote.joined(separator: "\n") + "\n")
        try verifySources(result, local: local, remote: remote)
        try expect(result.addedCount == 1 && result.deletedCount == 1 && result.modifiedCount == 2)
        let deleted = try require(result.rows.first(where: { $0.change == .deleted }))
        try expect(deleted.remoteNumber == 2 && deleted.remoteText == "remove only" && deleted.localNumber == nil)
        let added = try require(result.rows.first(where: { $0.change == .added }))
        try expect(added.localNumber == 5 && added.localText == "extra" && added.remoteNumber == nil)
        let modified = result.rows.filter { $0.change == .modified }
        try expect(modified.map(\.localNumber) == [3, 4] && modified.map(\.remoteNumber) == [4, 5])
        try expect(result.rows.last?.localNumber == 6 && result.rows.last?.remoteNumber == 6 && result.notice == nil)
    }

    func testRepeatedLinesUnicodeWhitespaceAndFinalNewline() throws {
        let local = ["start", "重复", "\tvalue", "重复", "结束"]
        let remote = ["start", "重复", "  value", "重复", "结束"]
        let result = try SVNLineComparison.compare(local: local.joined(separator: "\n") + "\n",
                                                   remote: remote.joined(separator: "\r\n"))
        try verifySources(result, local: local, remote: remote)
        try expect(result.modifiedCount == 1 && result.addedCount == 0 && result.deletedCount == 0)
        let changed = try require(result.rows.first(where: { $0.change == .modified }))
        try expect(changed.localNumber == 3 && changed.remoteNumber == 3 && changed.localText == "\tvalue" && changed.remoteText == "  value")
        try expect(result.notice?.contains("末尾") == true)
        let blank = try SVNLineComparison.compare(local: "甲\n \n乙\n", remote: "甲\n\n乙\n")
        try verifySources(blank, local: ["甲", " ", "乙"], remote: ["甲", "", "乙"])
        try expect(blank.modifiedCount == 1, "Whitespace-only edits must remain visible")
        let trailing = try SVNLineComparison.compare(local: "最后一行\n", remote: "最后一行")
        try expect(trailing.rows.count == 1 && trailing.rows.first?.change == .unchanged && trailing.notice?.contains("末尾") == true,
                   "Final LF differences need a notice without inventing an extra source line")
        let nfc = "\u{E9}"
        let nfd = "e\u{301}"
        let canonical = try SVNLineComparison.compare(local: nfc + "\n", remote: nfd + "\n")
        try expect(canonical.rows.count == 1 && canonical.modifiedCount == 1 && canonical.rows.first?.change == .modified,
                   "Canonically equivalent Unicode strings still differ in source bytes")
        let canonicalRow = try require(canonical.rows.first)
        try expect(canonicalRow.localText.map { Data($0.utf8) } == Data(nfc.utf8) && canonicalRow.remoteText.map { Data($0.utf8) } == Data(nfd.utf8))
    }

    func testIdenticalAndEmptyFiles() throws {
        let empty = try SVNLineComparison.compare(local: "", remote: "")
        try expect(empty.rows.isEmpty && empty.addedCount == 0 && empty.deletedCount == 0 && empty.modifiedCount == 0 && empty.notice == nil)
        let same = try SVNLineComparison.compare(local: "one\n\ntwo\n", remote: "one\r\n\r\ntwo\r")
        try verifySources(same, local: ["one", "", "two"], remote: ["one", "", "two"])
        try expect(same.rows.allSatisfy { $0.change == .unchanged } && same.notice == nil, "CRLF/CR styles must not create false line changes")
        let addedBlank = try SVNLineComparison.compare(local: "\n", remote: "")
        try verifySources(addedBlank, local: [""], remote: [])
        try expect(addedBlank.addedCount == 1 && addedBlank.rows.first?.localNumber == 1)
        let deletedFile = try SVNLineComparison.compare(local: "", remote: "one\ntwo\n")
        try verifySources(deletedFile, local: [], remote: ["one", "two"])
        try expect(deletedFile.deletedCount == 2 && deletedFile.rows.allSatisfy { $0.change == .deleted })
    }

    func testLargeUnanchoredChangesRemainBoundedAndDeterministic() throws {
        let source = (0..<30_000).map { "stable line \($0)" }
        var edited = source
        edited[10_000] = "changed line"
        edited.remove(at: 20_000)
        edited.insert("inserted line", at: 100)
        let anchored = try SVNLineComparison.compare(local: edited.joined(separator: "\n"), remote: source.joined(separator: "\n"))
        try verifySources(anchored, local: edited, remote: source)
        try expect(anchored.addedCount == 1 && anchored.deletedCount == 1 && anchored.modifiedCount == 1 && anchored.notice == nil,
                   "Distant edits in large files should still align around unchanged text")

        let local = (0..<50_000).map { "new \($0)" }
        let remote = (0..<50_000).map { "old \($0)" }
        let left = local.joined(separator: "\n")
        let right = remote.joined(separator: "\n")
        let first = try SVNLineComparison.compare(local: left, remote: right)
        let second = try SVNLineComparison.compare(local: left, remote: right)
        try verifySources(first, local: local, remote: remote)
        try expect(first == second, "The same large inputs must produce exactly the same alignment and notice")
        try expect(first.rows.count == 50_000 && first.modifiedCount == 50_000 && first.notice?.contains("按行配对") == true,
                   "Unrelated large blocks require an explicit bounded coarse alignment instead of quadratic work")
    }

    func testLineLimitAndCancellation() async throws {
        let oversized = String(repeating: "line\n", count: 50_001)
        for (local, remote, side) in [(oversized, "", "本地"), ("", oversized, "对照")] {
            do {
                _ = try SVNLineComparison.compare(local: local, remote: remote)
                throw CheckFailure.failed("Oversized \(side) text must be rejected")
            } catch let failure as CheckFailure { throw failure }
            catch let error as SVNError { try expect(error.localizedDescription.contains(side) && error.localizedDescription.contains("50,000")) }
        }
        let task = Task.detached { () async throws -> SVNLineComparison in
            // Deliberately start comparing in a cancelled task, eliminating a race
            // between the test scheduler and a fast successful comparison.
            while !Task.isCancelled { await Task.yield() }
            return try SVNLineComparison.compare(local: "local\n", remote: "remote\n")
        }
        task.cancel()
        do {
            _ = try await task.value
            throw CheckFailure.failed("A cancelled comparison must not return rows")
        } catch is CancellationError { }
    }

    private func verifySources(_ comparison: SVNLineComparison, local: [String], remote: [String]) throws {
        try expect(comparison.rows.compactMap(\.localText) == local, "Alignment must preserve every complete local line")
        try expect(comparison.rows.compactMap(\.remoteText) == remote, "Alignment must preserve every complete remote line")
        try expect(comparison.rows.compactMap(\.localNumber) == local.indices.map { $0 + 1 })
        try expect(comparison.rows.compactMap(\.remoteNumber) == remote.indices.map { $0 + 1 })
        try expect(comparison.rows.map(\.id) == Array(comparison.rows.indices))
        for row in comparison.rows {
            try expect((row.localNumber == nil) == (row.localText == nil) && (row.remoteNumber == nil) == (row.remoteText == nil))
            switch row.change {
            case .unchanged: try expect(row.localText != nil && row.localText == row.remoteText)
            case .added: try expect(row.localText != nil && row.remoteText == nil)
            case .deleted: try expect(row.remoteText != nil && row.localText == nil)
            case .modified: try expect(row.localText != nil && row.remoteText != nil)
            }
        }
    }
}
