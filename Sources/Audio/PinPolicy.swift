import Foundation

struct PinPolicy {
    struct Item: Equatable {
        var key: String
        var bytes: Int64
        var lastAccessedAt: Date
        var isPinned: Bool
    }

    enum Availability: Equatable {
        case active
        case inactiveRequiresPro
    }

    struct EvictionPlan: Equatable {
        var evictKeys: [String]
        var protectedKeys: Set<String>
        var bytesAfterEviction: Int64
        var overLimitBytes: Int64
        var pinnedBytes: Int64
        var availability: Availability
    }

    static func evictionPlan(items: [Item],
                             cacheLimitBytes: Int64,
                             proEnabled: Bool,
                             protectedKey: String? = nil) -> EvictionPlan {
        let totalBytes = items.reduce(Int64(0)) { $0 + max(0, $1.bytes) }
        let pinnedBytes = items
            .filter(\.isPinned)
            .reduce(Int64(0)) { $0 + max(0, $1.bytes) }
        guard cacheLimitBytes > 0 else {
            return EvictionPlan(
                evictKeys: [],
                protectedKeys: activeProtectedKeys(items: items, proEnabled: proEnabled, protectedKey: protectedKey),
                bytesAfterEviction: totalBytes,
                overLimitBytes: 0,
                pinnedBytes: pinnedBytes,
                availability: proEnabled ? .active : .inactiveRequiresPro
            )
        }

        let protectedKeys = activeProtectedKeys(items: items, proEnabled: proEnabled, protectedKey: protectedKey)
        var bytesAfterEviction = totalBytes
        var evictKeys: [String] = []
        let candidates = items
            .filter { !protectedKeys.contains($0.key) }
            .sorted { lhs, rhs in
                if lhs.lastAccessedAt == rhs.lastAccessedAt { return lhs.key < rhs.key }
                return lhs.lastAccessedAt < rhs.lastAccessedAt
            }

        for item in candidates where bytesAfterEviction > cacheLimitBytes {
            evictKeys.append(item.key)
            bytesAfterEviction -= max(0, item.bytes)
        }

        return EvictionPlan(
            evictKeys: evictKeys,
            protectedKeys: protectedKeys,
            bytesAfterEviction: bytesAfterEviction,
            overLimitBytes: max(0, bytesAfterEviction - cacheLimitBytes),
            pinnedBytes: pinnedBytes,
            availability: proEnabled ? .active : .inactiveRequiresPro
        )
    }

    static func setPinned(_ pinned: Bool, key: String, in items: [Item]) -> [Item] {
        items.map { item in
            guard item.key == key else { return item }
            return Item(
                key: item.key,
                bytes: item.bytes,
                lastAccessedAt: item.lastAccessedAt,
                isPinned: pinned
            )
        }
    }

    private static func activeProtectedKeys(items: [Item],
                                            proEnabled: Bool,
                                            protectedKey: String?) -> Set<String> {
        var protected = Set<String>()
        if proEnabled {
            protected.formUnion(items.filter(\.isPinned).map(\.key))
        }
        if let protectedKey {
            protected.insert(protectedKey)
        }
        return protected
    }
}
