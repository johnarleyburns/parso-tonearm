import Foundation

/// The last few committed search queries, newest first. §9 W2 lists these before the user types.
/// Backed by `UserDefaults` so they survive a launch; capped so the list stays a glance, not a log.
public protocol WatchRecentSearchStoring {
    func load() -> [String]
    func record(_ query: String)
    func clear()
}

public struct WatchRecentSearchStore: WatchRecentSearchStoring {
    public static let capacity = 6
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "watch.search.recents") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> [String] {
        (defaults.array(forKey: key) as? [String]) ?? []
    }

    public func record(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = load().filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        list.insert(trimmed, at: 0)
        if list.count > Self.capacity { list = Array(list.prefix(Self.capacity)) }
        defaults.set(list, forKey: key)
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }
}

/// In-memory double for host tests.
public final class WatchInMemoryRecentSearchStore: WatchRecentSearchStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String]

    public init(_ seed: [String] = []) { self.list = seed }

    public func load() -> [String] { lock.withLock { list } }

    public func record(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.withLock {
            list.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
            list.insert(trimmed, at: 0)
            if list.count > WatchRecentSearchStore.capacity {
                list = Array(list.prefix(WatchRecentSearchStore.capacity))
            }
        }
    }

    public func clear() { lock.withLock { list.removeAll() } }
}
