import Foundation

public enum PlaybackDisplayPolicy {
    /// Chooses the duration to display. Architecture-review finding: the periodic time observer
    /// let a remote item's OWN duration estimate unconditionally override the library's known
    /// value every 0.5s — but an `AVPlayerItem`'s live estimate for a streamed file (e.g.
    /// Jamendo's VBR MP3, served with no exact `Content-Length` up front) can be wildly wrong and
    /// keeps changing as more of the file loads, which is a plausible mechanism for "nonsensical
    /// elapsed/remaining times" (the crossfade code already reached the same conclusion for its
    /// own `fadeStart` math). The library's own stored duration is fixed once known and is
    /// authoritative; only fall back to the item's estimate when the library has none at all.
    public static func effectiveDuration(libraryKnown: Double?, itemEstimate: Double?) -> Double? {
        if let libraryKnown, libraryKnown > 0 { return libraryKnown }
        if let itemEstimate, itemEstimate.isFinite, itemEstimate > 0 { return itemEstimate }
        return nil
    }

    public static func providerName(for source: Source?) -> String {
        switch source?.kind {
        case .iaItem, .iaList, .iaCollection, .iaFavorites:
            return "archive.org"
        case .subsonic, .webDAV, .smb, .jellyfin, .emby, .plex,
             .dropbox, .googleDrive, .oneDrive, .pCloud, .box, .yandexDisk, .jamendoGenre:
            return RemoteConnectorCatalog.connector(for: source?.kind ?? .local)?.title ?? "Remote"
        case .local, .none:
            return String(localized: "On Device", bundle: .module)
        }
    }

    public static func miniPlayerSubtitle(row: TrackRow,
                                          cacheState: CacheGlyphState,
                                          shuffle: Bool,
                                          repeatMode: RepeatMode) -> String {
        var parts: [String] = []
        if shuffle { parts.append(String(localized: "Shuffled", bundle: .module)) }
        switch repeatMode {
        case .off:
            break
        case .one:
            parts.append(String(localized: "Repeat 1", bundle: .module))
        case .all:
            parts.append(String(localized: "Repeat All", bundle: .module))
        }

        if row.asset?.kind == .remote {
            parts.append(remoteProvenance(row: row, cacheState: cacheState))
        } else {
            parts.append(row.album?.artist ?? row.artist?.name ?? providerName(for: row.source))
        }
        return parts.joined(separator: " · ")
    }

    public static func remoteProvenance(row: TrackRow, cacheState: CacheGlyphState) -> String {
        let provider = providerName(for: row.source)
        switch cacheState {
        case .cached:
            return "\(provider) · cached"
        case .filling:
            return "\(provider) · caching..."
        case .none:
            return provider
        }
    }
}
