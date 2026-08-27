import Foundation
import TonearmWatchProtocol

/// Two-way stable string identifiers for the phone↔watch boundary.
///
/// §4: "All persistent IDs are stable strings from the phone; no phone GRDB integer primary key
/// crosses the protocol boundary." A record that already carries a `syncID` (CloudKit-synced rows,
/// watch-catalog imports) uses it verbatim. A record without one — a purely local album that has
/// never synced — gets a prefixed row token instead of a bare integer, so the wire form is always
/// visibly an opaque key and the reverse lookup can tell the two cases apart.
public enum PhoneWatchID {
    static let trackRowPrefix = "trow:"
    static let playlistRowPrefix = "prow:"
    static let albumRowPrefix = "arow:"
    static let artistRowPrefix = "irow:"

    public static func track(_ track: Track) -> WatchTrackID {
        WatchTrackID(track.syncID ?? "\(trackRowPrefix)\(track.id ?? -1)")
    }

    public static func playlist(_ playlist: Playlist) -> String {
        playlist.syncID ?? "\(playlistRowPrefix)\(playlist.id ?? -1)"
    }

    public static func album(_ album: Album) -> String {
        album.syncID ?? "\(albumRowPrefix)\(album.id ?? -1)"
    }

    public static func artist(_ artist: Artist) -> String {
        artist.syncID ?? "\(artistRowPrefix)\(artist.id ?? -1)"
    }

    /// `nil` when `raw` is a `syncID` (the caller falls back to a `syncID` lookup); a row id when
    /// `raw` is one of this type's own row tokens.
    static func rowID(_ raw: String, prefix: String) -> Int64? {
        guard raw.hasPrefix(prefix) else { return nil }
        return Int64(raw.dropFirst(prefix.count))
    }

    /// Resolution seam for adapters compiled outside this module (the Xcode-only `Sources/App`
    /// wiring): a local track row id when `id` is a row token, `nil` when it is a `syncID` and the
    /// caller should look up by `syncID` instead.
    public static func trackRowID(_ id: WatchTrackID) -> Int64? {
        rowID(id.rawValue, prefix: trackRowPrefix)
    }

    /// Sibling of `trackRowID` for playlist/album source keys, for the Xcode-only `Sources/App`
    /// wiring that has to reverse a `WatchDownloadRootDescriptor.sourceID` back to a local row.
    public static func playlistRowID(_ id: String) -> Int64? { rowID(id, prefix: playlistRowPrefix) }
    public static func albumRowID(_ id: String) -> Int64? { rowID(id, prefix: albumRowPrefix) }
}

/// An opaque forward-only paging cursor. §6.1 forbids serializing the whole catalog; every paged
/// response carries one of these as `nextPageToken` when more rows exist, and the watch echoes it
/// back untouched. Corrupt or absent tokens decode to offset zero rather than throwing — a lost
/// token costs a re-read of the first page, never an error.
public struct PhoneWatchPageToken: Codable, Equatable, Sendable {
    public var offset: Int

    public init(offset: Int) { self.offset = max(0, offset) }

    public func encoded() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return data.base64EncodedString()
    }

    public static func decode(_ token: String?) -> PhoneWatchPageToken {
        guard let token, let data = Data(base64Encoded: token),
              let decoded = try? JSONDecoder().decode(PhoneWatchPageToken.self, from: data) else {
            return PhoneWatchPageToken(offset: 0)
        }
        return decoded
    }

    /// The slice `[offset, offset+limit)` of `all`, and the token for the next page when the slice
    /// does not reach the end.
    public static func page<Element>(_ all: [Element], offset rawOffset: Int, limit: Int)
        -> (slice: ArraySlice<Element>, nextToken: String?) {
        let offset = min(max(0, rawOffset), all.count)
        let end = min(offset + max(1, limit), all.count)
        let next = end < all.count ? PhoneWatchPageToken(offset: end).encoded() : nil
        return (all[offset..<end], next)
    }
}

/// Pure record → DTO factories. §5.2: a paged row carries what a watch draws and nothing else — no
/// file URL, no source identity, no credential-bearing remote address.
public enum PhoneWatchProjection {
    public static func artistName(for row: TrackRow) -> String {
        row.artist?.name
            ?? row.album?.albumArtist
            ?? row.album?.artist
            ?? ""
    }

    public static func trackSummary(from row: TrackRow,
                                    downloadedOnWatch: Set<WatchTrackID>) -> WatchTrackSummary {
        let id = PhoneWatchID.track(row.track)
        return WatchTrackSummary(
            trackID: id,
            title: row.track.title,
            artist: artistName(for: row),
            albumTitle: row.album?.title ?? "",
            durationSeconds: row.track.durationSec,
            artworkID: row.album?.artworkId,
            isDownloadedOnWatch: downloadedOnWatch.contains(id))
    }

    public static func trackRow(from row: TrackRow,
                                downloadedOnWatch: Set<WatchTrackID>) -> WatchResultRow {
        let id = PhoneWatchID.track(row.track)
        return WatchResultRow(
            kind: .track,
            id: id.rawValue,
            title: row.track.title,
            subtitle: subtitle(artist: artistName(for: row), album: row.album?.title),
            artworkID: row.album?.artworkId,
            durationSeconds: row.track.durationSec,
            isDownloadedOnWatch: downloadedOnWatch.contains(id))
    }

    public static func albumRow(from album: Album, trackCount: Int?) -> WatchResultRow {
        WatchResultRow(
            kind: .album,
            id: PhoneWatchID.album(album),
            title: album.title,
            subtitle: album.albumArtist ?? album.artist,
            artworkID: album.artworkId,
            trackCount: trackCount)
    }

    public static func playlistRow(from playlist: Playlist, trackCount: Int?) -> WatchResultRow {
        WatchResultRow(
            kind: .playlist,
            id: PhoneWatchID.playlist(playlist),
            title: playlist.title,
            subtitle: nil,
            trackCount: trackCount)
    }

    public static func artistRow(from artist: Artist) -> WatchResultRow {
        WatchResultRow(kind: .artist, id: PhoneWatchID.artist(artist), title: artist.name)
    }

    private static func subtitle(artist: String, album: String?) -> String? {
        switch (artist.isEmpty, album?.isEmpty ?? true) {
        case (false, false): return "\(artist) — \(album!)"
        case (false, true): return artist
        case (true, false): return album
        case (true, true): return nil
        }
    }
}
