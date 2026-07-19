import Foundation

public enum PlaybackDisplayPolicy {
    public static func providerName(for source: Source?) -> String {
        switch source?.kind {
        case .iaItem, .iaList, .iaCollection, .iaFavorites:
            return "archive.org"
        case .subsonic, .webDAV, .smb, .jellyfin, .plex,
             .dropbox, .googleDrive, .oneDrive, .pCloud:
            return RemoteConnectorCatalog.connector(for: source?.kind ?? .local)?.title ?? "Remote"
        case .local, .none:
            return "On Device"
        }
    }

    public static func miniPlayerSubtitle(row: TrackRow,
                                          cacheState: CacheGlyphState,
                                          shuffle: Bool,
                                          repeatMode: RepeatMode) -> String {
        var parts: [String] = []
        if shuffle { parts.append("Shuffled") }
        switch repeatMode {
        case .off:
            break
        case .one:
            parts.append("Repeat 1")
        case .all:
            parts.append("Repeat All")
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
