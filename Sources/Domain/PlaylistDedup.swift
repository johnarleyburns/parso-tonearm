import Foundation

public enum PlaylistDedup {
    public static func duplicateItemIDs(in items: [PlaylistItem]) -> [Int64] {
        var seen: Set<Int64> = []
        return items.compactMap { item in
            guard !seen.insert(item.trackId).inserted else { return nil }
            return item.id
        }
    }

    public static func deduplicated(_ items: [PlaylistItem]) -> [PlaylistItem] {
        var seen: Set<Int64> = []
        return items.compactMap { item in
            guard seen.insert(item.trackId).inserted else { return nil }
            var survivor = item
            survivor.position = seen.count - 1
            return survivor
        }
    }
}
