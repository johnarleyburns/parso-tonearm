import Foundation

public enum WatchLibraryFilter {

    /// Filter tracks that have a local asset (on the watch).
    public static func onWatchTracks(_ rows: [TrackRow], fileExists: (String) -> Bool) -> [TrackRow] {
        rows.filter { row in
            guard let relPath = row.asset?.relPath else { return false }
            return fileExists(relPath)
        }
    }

    /// Filter tracks visible when tethered (phone reachable): all cataloged tracks.
    public static func tetheredTracks(_ rows: [TrackRow]) -> [TrackRow] {
        rows
    }

    /// Filter tracks visible when untethered (phone not reachable): only on-watch tracks.
    public static func untetheredTracks(_ rows: [TrackRow], fileExists: (String) -> Bool) -> [TrackRow] {
        onWatchTracks(rows, fileExists: fileExists)
    }

    /// Apply the 5000-row cap for the songs view.
    public static func cap(_ rows: [TrackRow], at limit: Int = 5000) -> [TrackRow] {
        Array(rows.prefix(limit))
    }

    /// Filter playlists that have at least one on-watch track.
    public static func visiblePlaylists(
        allPlaylists: [Playlist],
        playlistItems: [String: [String]],  // playlistTitle → trackKeys
        manifestKeys: Set<String>
    ) -> [Playlist] {
        allPlaylists.filter { playlist in
            guard let keys = playlistItems[playlist.title] else { return false }
            return keys.contains(where: { manifestKeys.contains($0) }) || !playlistItems.keys.contains(playlist.title)
        }
    }

    /// Filter albums that have at least one on-watch track.
    public static func visibleAlbums(
        _ albums: [Album],
        albumTrackCounts: [Int64: Int],      // albumId → onWatch track count
        emptyReturnAll: Bool
    ) -> [Album] {
        if emptyReturnAll && albumTrackCounts.isEmpty { return albums }
        return albums.filter { album in
            guard let id = album.id else { return false }
            return (albumTrackCounts[id] ?? 0) > 0
        }
    }

    /// Compute counts by key for the root view display.
    public struct Counts {
        public var playlists: Int
        public var albums: Int
        public var songs: Int
    }

    public static func counts(
        tracks: [TrackRow],
        fileExists: (String) -> Bool,
        playlists: [Playlist],
        playlistItems: [String: [String]],
        manifestKeys: Set<String>
    ) -> Counts {
        let onWatch = onWatchTracks(tracks, fileExists: fileExists)
        let capped = cap(onWatch)
        return Counts(
            playlists: visiblePlaylists(allPlaylists: playlists, playlistItems: playlistItems,
                                         manifestKeys: manifestKeys).count,
            albums: 0, // computed by caller with album groupings
            songs: capped.count)
    }
}
