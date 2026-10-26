import Foundation
import SVNCore

struct RepositoryListingTests {
    func testDefaultSortUsesNaturalNamesAndKeepsDirectoriesFirst() throws {
        let entries = [entry("file10.txt"), entry("Folder10", kind: "dir"),
                       entry("file2.txt"), entry("Folder2", kind: "dir"),
                       entry("file1.txt"), entry("Folder1", kind: "dir")]
        let sorted = RepositoryEntry.sorted(entries, using: RepositoryEntry.defaultSortOrder)
        try expect(sorted.map(\.name) == ["Folder1", "Folder2", "Folder10", "file1.txt", "file2.txt", "file10.txt"])
        try expect(RepositoryEntry.sorted([], using: RepositoryEntry.defaultSortOrder).isEmpty)
    }

    func testRevisionSortUsesNumbersInBothDirections() throws {
        let entries = [entry("file100", revision: "100"), entry("dir10", kind: "dir", revision: "10"),
                       entry("file9", revision: "9"), entry("dir2", kind: "dir", revision: "2"),
                       entry("file2", revision: "2"), entry("fileUnknown")]
        try expect(entries.last?.revisionNumber == -1)
        let ascending = RepositoryEntry.sorted(entries, using: [KeyPathComparator(\RepositoryEntry.revisionNumber)])
        try expect(ascending.map(\.name) == ["dir2", "dir10", "fileUnknown", "file2", "file9", "file100"])
        let descending = RepositoryEntry.sorted(entries, using: [KeyPathComparator(\RepositoryEntry.revisionNumber, order: .reverse)])
        try expect(descending.map(\.name) == ["dir10", "dir2", "file100", "file9", "file2", "fileUnknown"])
    }

    func testAuthorSortSupportsBothDirectionsAndNaturalNameTies() throws {
        let entries = [entry("file10", author: "alice"), entry("file2", author: "alice"),
                       entry("file3", author: "bob"), entry("dir2", kind: "dir", author: "bob"),
                       entry("dir1", kind: "dir", author: "alice")]
        let ascending = RepositoryEntry.sorted(entries, using: [KeyPathComparator(\RepositoryEntry.author)])
        try expect(ascending.map(\.name) == ["dir1", "dir2", "file2", "file10", "file3"])
        let descending = RepositoryEntry.sorted(entries, using: [KeyPathComparator(\RepositoryEntry.author, order: .reverse)])
        try expect(descending.map(\.name) == ["dir2", "dir1", "file3", "file2", "file10"])
    }

    func testSizeSortSupportsBothDirections() throws {
        let entries = [entry("file10", size: 10), entry("dir2", kind: "dir", size: 20),
                       entry("file2", size: 2), entry("dir1", kind: "dir", size: 1),
                       entry("file100", size: 100)]
        let ascending = RepositoryEntry.sorted(entries, using: [KeyPathComparator(\RepositoryEntry.size)])
        try expect(ascending.map(\.name) == ["dir1", "dir2", "file2", "file10", "file100"])
        let descending = RepositoryEntry.sorted(entries, using: [KeyPathComparator(\RepositoryEntry.size, order: .reverse)])
        try expect(descending.map(\.name) == ["dir2", "dir1", "file100", "file10", "file2"])
    }

    func testLastCommitTimeSortSupportsBothDirectionsAndMissingDates() throws {
        let entries = [entry("fileLater", date: "1970-01-01T00:00:10Z"),
                       entry("dirLater", kind: "dir", date: "1970-01-01T00:00:20Z"),
                       entry("fileEarlier", date: "1970-01-01T00:00:02.125000Z"),
                       entry("dirEarlier", kind: "dir", date: "1970-01-01T00:00:01Z"),
                       entry("fileUnknown")]
        let ascending = RepositoryEntry.sorted(entries, using: [KeyPathComparator(\RepositoryEntry.lastCommitTimestamp)])
        try expect(ascending.map(\.name) == ["dirEarlier", "dirLater", "fileUnknown", "fileEarlier", "fileLater"])
        let descending = RepositoryEntry.sorted(entries, using: [KeyPathComparator(\RepositoryEntry.lastCommitTimestamp, order: .reverse)])
        try expect(descending.map(\.name) == ["dirLater", "dirEarlier", "fileLater", "fileEarlier", "fileUnknown"])
    }

    func testCommitDatesPreserveRawValueAndParseOptionalFractionalSeconds() throws {
        for (text, timestamp) in [("1970-01-01T00:00:02Z", 2.0),
                                  ("1970-01-01T00:00:02.125000Z", 2.125)] {
            let value = entry("fixture", date: text)
            let parsed = try require(value.lastCommitDate)
            try expect(value.date == text, "Display metadata must retain the original SVN timestamp")
            try expect(abs(parsed.timeIntervalSince1970 - timestamp) < 0.000001)
            try expect(abs(value.lastCommitTimestamp - timestamp) < 0.000001)
        }
        for text in ["", "not-a-date"] {
            let value = entry("fixture", date: text)
            try expect(value.date == text)
            try expect(value.lastCommitDate == nil)
            try expect(value.lastCommitTimestamp == -Double.greatestFiniteMagnitude)
        }
    }

    func testMultipleSortColumnsAndEmptySortHaveDeterministicNameFallback() throws {
        let entries = [entry("file10", revision: "2", author: "alice"),
                       entry("file2", revision: "2", author: "alice"),
                       entry("file1", revision: "10", author: "alice"),
                       entry("file3", revision: "1", author: "bob")]
        let sorted = RepositoryEntry.sorted(entries, using: [KeyPathComparator(\RepositoryEntry.author),
                                                            KeyPathComparator(\RepositoryEntry.revisionNumber, order: .reverse)])
        try expect(sorted.map(\.name) == ["file1", "file2", "file10", "file3"])
        try expect(RepositoryEntry.sorted(entries, using: []).map(\.name) == ["file1", "file2", "file3", "file10"])
        try expect(RepositoryEntry.sorted(Array(entries.reversed()), using: []).map(\.name) == ["file1", "file2", "file3", "file10"])
    }

    func testCacheExpiresAtTTLWithoutExtendingLifetimeOnReads() throws {
        var cache = RepositoryListingCache(ttl: 30, capacity: 2)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let url = "https://svn.example.invalid/repos/alpha/trunk"
        let entries = [entry("initial", kind: "dir")]
        cache.store(entries, for: url, now: now)
        try expect(cache.entries(for: url, now: now) == entries)
        try expect(cache.entries(for: url, now: now.addingTimeInterval(29.999)) == entries)
        try expect(cache.entries(for: url, now: now.addingTimeInterval(30)) == nil,
                   "A recent cache read must not renew the stored listing's TTL")
        try expect(cache.entries(for: url, now: now.addingTimeInterval(31)) == nil)
        cache.store([], for: url, now: now.addingTimeInterval(31))
        let emptyListing = try require(cache.entries(for: url, now: now.addingTimeInterval(32)))
        try expect(emptyListing.isEmpty, "An empty directory is a cache hit, not a missing entry")
    }

    func testCacheEvictsLeastRecentlyReadListing() throws {
        var cache = RepositoryListingCache(ttl: 30, capacity: 2)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let alpha = "https://svn.example.invalid/repos/alpha"
        let beta = "https://svn.example.invalid/repos/beta"
        let gamma = "https://svn.example.invalid/repos/gamma"
        let entries = [entry("fixture")]
        cache.store(entries, for: alpha, now: now)
        cache.store(entries, for: beta, now: now.addingTimeInterval(1))
        try expect(cache.entries(for: alpha, now: now.addingTimeInterval(2)) == entries)
        cache.store(entries, for: gamma, now: now.addingTimeInterval(3))
        try expect(cache.entries(for: beta, now: now.addingTimeInterval(4)) == nil)
        try expect(cache.entries(for: alpha, now: now.addingTimeInterval(4)) == entries)
        try expect(cache.entries(for: gamma, now: now.addingTimeInterval(4)) == entries)
    }

    func testCacheReplacementRefreshesContentsTTLAndRecency() throws {
        var cache = RepositoryListingCache(ttl: 30, capacity: 2)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let alpha = "https://svn.example.invalid/repos/alpha"
        let beta = "https://svn.example.invalid/repos/beta"
        let gamma = "https://svn.example.invalid/repos/gamma"
        let previous = [entry("old")]
        let updated = [entry("new")]
        cache.store(previous, for: alpha, now: now)
        cache.store(previous, for: beta, now: now.addingTimeInterval(1))
        cache.store(updated, for: alpha, now: now.addingTimeInterval(20))
        cache.store(previous, for: gamma, now: now.addingTimeInterval(21))
        try expect(cache.entries(for: beta, now: now.addingTimeInterval(22)) == nil)
        try expect(cache.entries(for: alpha, now: now.addingTimeInterval(31)) == updated)
        try expect(cache.entries(for: alpha, now: now.addingTimeInterval(50)) == nil)
    }

    func testCacheUsesCompleteCanonicalURLKeysAndCanBeCleared() throws {
        var cache = RepositoryListingCache(ttl: 30, capacity: 10)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let canonical = try RepositoryCredentialScope.canonicalURL("HTTPS://SVN.Example.invalid:443/repos/alpha/")
        let entries = [entry("alpha-only")]
        cache.store(entries, for: canonical, now: now)
        try expect(cache.entries(for: canonical, now: now) == entries)
        for url in ["https://svn.example.invalid/repos/alpha/trunk",
                    "https://svn.example.invalid/repos/alphabet",
                    "https://svn.example.invalid/repos/Alpha",
                    "https://other.example.invalid/repos/alpha",
                    "http://svn.example.invalid/repos/alpha",
                    "https://svn.example.invalid:8443/repos/alpha"] {
            try expect(cache.entries(for: url, now: now) == nil, "A cached listing must remain scoped to its full URL")
            cache.store([entry("other-only")], for: url, now: now)
        }
        try expect(cache.entries(for: canonical, now: now) == entries)
        cache.invalidateAll()
        try expect(cache.entries(for: canonical, now: now) == nil)
        try expect(cache.entries(for: "https://svn.example.invalid/repos/alpha/trunk", now: now) == nil)
    }

    private func entry(_ name: String, kind: String = "file", revision: String = "",
                       author: String = "", size: Int64 = 0, date: String = "") -> RepositoryEntry {
        RepositoryEntry(name: name, kind: kind, revision: revision, author: author, size: size, date: date)
    }
}
