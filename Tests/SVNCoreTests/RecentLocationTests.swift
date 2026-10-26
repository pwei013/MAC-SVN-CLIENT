import Foundation
import SVNCore

struct RecentLocationTests {
    func testDisplayDecodesChineseAndEmojiWithoutChangingASCIISpelling() throws {
        let encoded = "https://svn.example.invalid/Topone/%E4%B8%AD%E6%96%87/%F0%9F%9A%80/a%2Fb%23c%3Fd%25e%20f"
        let displayed = "https://svn.example.invalid/Topone/中文/🚀/a%2Fb%23c%3Fd%25e%20f"
        try expect(SVNLocation.display(encoded) == displayed)
        try expect(SVNLocation.display(displayed) == displayed, "Display conversion must be idempotent")
        try expect(SVNLocation.display("原始中文/%e4%b8%ad/%F0%9f%9a%80") == "原始中文/中/🚀")
        try expect(SVNLocation.display("%25E4%25B8%25AD/%41/%7E/%00/%0A") == "%25E4%25B8%25AD/%41/%7E/%00/%0A",
                   "ASCII escapes and double-encoded values must not be decoded")
    }

    func testDisplayKeepsMalformedAndInvalidUTF8Escapes() throws {
        for text in ["%", "%E", "%GG", "%E4%B8", "%80", "%C0%AF", "%ED%A0%80", "%F4%90%80%80"] {
            try expect(SVNLocation.display(text) == text, "Invalid percent or UTF-8 sequences must remain visible verbatim")
        }
        try expect(SVNLocation.display("%E4%B8%AD/%GG/%E6%96%87") == "中/%GG/文")
        try expect(SVNLocation.display("") == "")
    }

    func testDisplayRoundTripsThroughRepositoryCanonicalization() throws {
        for text in [
            "https://svn.example.invalid/repos/%E4%B8%AD%E6%96%87/%23%3F%25%20/%F0%9F%9A%80",
            "svn://svn.example.invalid/repos/%E4%B8%AD%E6%96%87/trunk",
            "file:///tmp/svn/%E4%B8%AD%E6%96%87/%F0%9F%9A%80"
        ] {
            let original = try RepositoryCredentialScope.canonicalURL(text)
            let displayed = SVNLocation.display(original)
            try expect(displayed.contains("中文"))
            try expect(try RepositoryCredentialScope.canonicalURL(displayed) == original,
                       "Readable URLs must preserve the exact repository target and escaped delimiters")
        }
    }

    func testHistoryDeduplicatesAndKeepsOnlyLimitedRecentItems() throws {
        var history = RecentLocationHistory(recent: ["", "alpha", "alpha", "beta", "gamma", "delta"], limit: 3)
        try expect(history.items == ["alpha", "beta", "gamma"])
        try expect(history.pinned.isEmpty)
        history.remember("beta")
        try expect(history.items == ["beta", "alpha", "gamma"])
        history.remember("")
        try expect(history.items == ["beta", "alpha", "gamma"])
        history.remember("delta")
        try expect(history.items == ["delta", "beta", "alpha"])
    }

    func testPinnedOrderSurvivesVisitsAndNewPinsGoFirst() throws {
        var history = RecentLocationHistory(recent: ["alpha", "beta", "gamma"])
        history.togglePin("alpha")
        history.togglePin("beta")
        try expect(history.pinned == ["beta", "alpha"])
        try expect(history.items == ["beta", "alpha", "gamma"])
        try expect(history.isPinned("alpha") && history.isPinned("beta"))
        try expect(!history.isPinned("gamma"))
        history.remember("alpha")
        history.remember("delta")
        history.remember("gamma")
        try expect(history.pinned == ["beta", "alpha"], "Opening an older pin must not reorder the fixed section")
        try expect(history.items == ["beta", "alpha", "gamma", "delta"])
        history.togglePin("")
        try expect(history.pinned == ["beta", "alpha"])
    }

    func testPinnedItemsSurviveRecentEvictionAndUnpinBecomesMostRecent() throws {
        var history = RecentLocationHistory(recent: ["fixed"])
        history.togglePin("fixed")
        for index in 0..<15 { history.remember("recent-\(index)") }
        let expectedRecent = (5..<15).reversed().map { "recent-\($0)" }
        try expect(history.items == ["fixed"] + expectedRecent,
                   "The default ten-entry recent limit must not count or evict fixed entries")
        history.togglePin("fixed")
        try expect(history.pinned.isEmpty && !history.isPinned("fixed"))
        try expect(history.items == ["fixed"] + Array(expectedRecent.prefix(9)))
    }

    func testHistoryDeduplicatesPinnedAndClearPreservesThem() throws {
        var history = RecentLocationHistory(
            recent: ["alpha", "beta", "alpha", "gamma", ""], pinned: ["", "beta", "beta", "fixed", "alpha"])
        try expect(history.pinned == ["beta", "fixed", "alpha"])
        try expect(history.items == ["beta", "fixed", "alpha", "gamma"])
        history.clearRecent()
        try expect(history.items == ["beta", "fixed", "alpha"])
        history.remember("new")
        try expect(history.items == ["beta", "fixed", "alpha", "new"])
    }

    func testLegacyPreferencesLoadAndPinnedPreferencesRoundTrip() throws {
        let suiteName = "com.mky.svnmanager.checks.recent-\(UUID().uuidString)"
        let defaults = try require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recentKey = "fixtureRecent"
        let pinnedKey = "fixturePinned"
        try expect(RecentLocationHistory(defaults: defaults, recentKey: recentKey, pinnedKey: pinnedKey).items.isEmpty)

        defaults.set(["alpha", "", "beta", "alpha", "gamma"], forKey: recentKey)
        var history = RecentLocationHistory(defaults: defaults, recentKey: recentKey, pinnedKey: pinnedKey)
        try expect(history.items == ["alpha", "beta", "gamma"], "Existing recent preferences must load without pin metadata")
        history.togglePin("beta")
        history.togglePin("fixed")
        history.remember("delta")
        history.save(to: defaults, recentKey: recentKey, pinnedKey: pinnedKey)
        try expect(defaults.stringArray(forKey: recentKey) == history.items,
                   "The legacy recent key must retain the complete visible history for compatibility")
        try expect(defaults.stringArray(forKey: pinnedKey) == ["fixed", "beta"])

        let reloadedDefaults = try require(UserDefaults(suiteName: suiteName))
        var reloaded = RecentLocationHistory(defaults: reloadedDefaults, recentKey: recentKey, pinnedKey: pinnedKey)
        try expect(reloaded.items == ["fixed", "beta", "delta", "alpha", "gamma"])
        try expect(reloaded.pinned == ["fixed", "beta"])
        reloaded.togglePin("fixed")
        reloaded.clearRecent()
        reloaded.save(to: reloadedDefaults, recentKey: recentKey, pinnedKey: pinnedKey)
        let final = RecentLocationHistory(defaults: defaults, recentKey: recentKey, pinnedKey: pinnedKey)
        try expect(final.items == ["beta"] && final.pinned == ["beta"])

        defaults.set(["alpha", "alpha", "", "beta", "gamma"], forKey: recentKey)
        defaults.set(["beta", "beta", "", "fixed"], forKey: pinnedKey)
        let deduplicated = RecentLocationHistory(defaults: defaults, recentKey: recentKey, pinnedKey: pinnedKey, limit: 1)
        try expect(deduplicated.items == ["beta", "fixed", "alpha"])
    }
}
