public enum WatchArtworkSource: Equatable, Sendable {
    case custom, cover, embedded, none
}

public struct WatchArtworkResolver {
    /// Resolves only separately installed artwork. A nil result tells playback to try embedded art.
    public static func resolve(
        customArtworkID: String?,
        coverArtworkID: String?,
        installed: (String) -> Bool
    ) -> (WatchArtworkSource, artworkID: String?) {
        if let customArtworkID, installed(customArtworkID) {
            return (.custom, customArtworkID)
        }
        if let coverArtworkID, installed(coverArtworkID) {
            return (.cover, coverArtworkID)
        }
        return (.none, nil)
    }
}
