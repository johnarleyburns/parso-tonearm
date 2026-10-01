import Foundation

/// Watch redesign §6.4 — everything the watch derives from the connection banner, in one place, so
/// the banner, the search scope and "is the iPhone reachable" can never disagree.
public struct WatchConnectionProjection: Equatable, Sendable {
    public let phoneReachable: Bool
    public let searchMode: WatchSearchPresenter.Mode

    public init(banner: WatchConnectionChrome.Banner) {
        phoneReachable = banner == .connected
        searchMode = phoneReachable ? .connected : .offline
    }
}
