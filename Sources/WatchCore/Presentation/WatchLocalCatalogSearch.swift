import Foundation
import TonearmWatchProtocol

/// Pure local catalog search. Keeping this outside SwiftUI makes the most important watch-only
/// guarantee executable in host tests: no result can require a phone round trip.
public enum WatchLocalCatalogSearch {
    public static func rows(query: String, tracks: [WatchTrackSnapshot], playlists: [WatchPlaylistSnapshot],
                            onWatchOnly: Bool) -> [WatchResultRow] {
        let terms = WatchTextNormalizer.normalize(query).split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return [] }
        let visibleTracks = tracks.filter { !onWatchOnly || $0.isReady }
        let matchingTracks = visibleTracks.filter {
            let haystack = [$0.title, $0.artist, $0.albumTitle]
                .map(WatchTextNormalizer.normalize)
                .joined(separator: " ")
            return terms.allSatisfy { haystack.contains($0) }
        }
        var rows = matchingTracks.map {
            WatchResultRow(kind: .track, id: $0.id, title: $0.title,
                           subtitle: [$0.artist, $0.albumTitle].filter { !$0.isEmpty }.joined(separator: " — "),
                           artworkID: $0.artworkID, durationSeconds: $0.durationSeconds,
                           isDownloadedOnWatch: $0.isReady)
        }
        let albums = Dictionary(grouping: matchingTracks.filter { !$0.albumTitle.isEmpty }, by: \.albumTitle)
        rows += albums.map { title, values in
            WatchResultRow(kind: .album, id: title, title: title,
                           subtitle: values.first(where: { !$0.artist.isEmpty })?.artist,
                           trackCount: values.count, isDownloadedOnWatch: values.allSatisfy(\.isReady))
        }
        let matchingPlaylists = playlists.filter { playlist in
            let normalizedTitle = WatchTextNormalizer.normalize(playlist.title)
            let titleMatches = terms.allSatisfy { normalizedTitle.contains($0) }
            return titleMatches && (!onWatchOnly || !playlist.readyTrackIDs.isEmpty)
        }
        rows += matchingPlaylists.map {
            WatchResultRow(kind: .playlist, id: $0.id, title: $0.title,
                           trackCount: $0.trackIDs.count, isDownloadedOnWatch: !$0.isPartial)
        }
        let artists = Set(matchingTracks.map(\.artist).filter { !$0.isEmpty })
        rows += artists.map { WatchResultRow(kind: .artist, id: $0, title: $0) }
        return rows.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}
