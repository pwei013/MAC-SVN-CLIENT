import Foundation

/// Session-only directory listings, keyed by the caller's canonical repository URL.
public struct RepositoryListingCache {
    private struct Snapshot {
        let entries: [RepositoryEntry]
        let createdAt: Date
        var lastAccess: UInt64
    }
    private let ttl: TimeInterval
    private let capacity: Int
    private var snapshots: [String: Snapshot] = [:]
    private var sequence: UInt64 = 0

    public init(ttl: TimeInterval = 30, capacity: Int = 50) {
        self.ttl = ttl
        self.capacity = max(0, capacity)
    }

    public mutating func entries(for url: String, now: Date = Date()) -> [RepositoryEntry]? {
        guard var snapshot = snapshots[url] else { return nil }
        guard now.timeIntervalSince(snapshot.createdAt) >= 0,
              now.timeIntervalSince(snapshot.createdAt) < ttl else {
            snapshots.removeValue(forKey: url)
            return nil
        }
        sequence &+= 1
        snapshot.lastAccess = sequence
        snapshots[url] = snapshot
        return snapshot.entries
    }

    public mutating func store(_ entries: [RepositoryEntry], for url: String, now: Date = Date()) {
        guard ttl > 0, capacity > 0 else { return }
        sequence &+= 1
        snapshots[url] = Snapshot(entries: entries, createdAt: now, lastAccess: sequence)
        while snapshots.count > capacity, let oldest = snapshots.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            snapshots.removeValue(forKey: oldest)
        }
    }

    public mutating func invalidateAll() { snapshots.removeAll() }
}
