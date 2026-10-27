import Foundation

public struct RecentLocationHistory: Sendable {
    public private(set) var pinned: [String]
    private var recent: [String]
    private let limit: Int
    public var items: [String] { pinned + recent }

    public init(recent: [String] = [], pinned: [String] = [], limit: Int = 10) {
        self.limit = max(0, limit)
        self.pinned = Self.unique(pinned)
        let fixed = Set(self.pinned)
        self.recent = Array(Self.unique(recent).filter { !fixed.contains($0) }.prefix(self.limit))
    }

    public init(defaults: UserDefaults, recentKey: String, pinnedKey: String, limit: Int = 10) {
        self.init(recent: defaults.stringArray(forKey: recentKey) ?? [],
                  pinned: defaults.stringArray(forKey: pinnedKey) ?? [], limit: limit)
    }

    public func save(to defaults: UserDefaults, recentKey: String, pinnedKey: String) {
        defaults.set(items, forKey: recentKey)
        defaults.set(pinned, forKey: pinnedKey)
    }

    public func isPinned(_ value: String) -> Bool { pinned.contains(value) }

    public mutating func remember(_ value: String) {
        guard !value.isEmpty, !isPinned(value) else { return }
        recent.removeAll { $0 == value }
        recent.insert(value, at: 0)
        recent = Array(recent.prefix(limit))
    }

    public mutating func togglePin(_ value: String) {
        if isPinned(value) {
            pinned.removeAll { $0 == value }
            remember(value)
        } else if !value.isEmpty {
            recent.removeAll { $0 == value }
            pinned.insert(value, at: 0)
        }
    }

    public mutating func clearRecent() { recent = [] }

    public mutating func remove(_ value: String) {
        pinned.removeAll { $0 == value }
        recent.removeAll { $0 == value }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
