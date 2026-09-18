import Foundation

/// Real gap found comparing against Apple Music/Plex (docs/plans/carplay-and-
/// competitor-gaps-plan.md item 2): both let you surface the playlists you
/// actually use above the rest. Descoped from true nested "folders" (a real
/// data-model change — a parent/child column, migration, recursive UI) to
/// plain pinning, which gets most of the organizational value at a fraction
/// of the cost; folders remain a documented follow-up.
///
/// Deliberately local-only (`UserDefaults`, not the synced `LibraryStore`
/// DB) — this is presentation ordering, not library data, so it doesn't
/// need iCloud sync or cross-device consistency the way playlist contents
/// do.
enum PinnedPlaylistsStore {
    private static let key = "pinnedPlaylistIds.v1"

    static func pinnedIds() -> Set<Int64> {
        let raw = UserDefaults.standard.array(forKey: key) as? [Int64] ?? []
        return Set(raw)
    }

    static func isPinned(_ id: Int64?) -> Bool {
        guard let id else { return false }
        return pinnedIds().contains(id)
    }

    @discardableResult
    static func togglePin(_ id: Int64?) -> Set<Int64> {
        guard let id else { return pinnedIds() }
        var ids = pinnedIds()
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        UserDefaults.standard.set(Array(ids), forKey: key)
        return ids
    }
}
