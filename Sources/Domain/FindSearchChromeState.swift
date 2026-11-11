import Foundation

/// Pure presentation policy for the iPhone root shell while the Find query field is focused.
/// Focus only hides chrome (title, mini-player, reserved clearance); it never touches playback.
public struct FindSearchChromeState: Equatable, Sendable {
    public static let trackAccessoryHeight: CGFloat = 56
    public static let accessorySpacing: CGFloat = 4
    public static let accessoryBottomPadding: CGFloat = 58

    public var isFindActive: Bool
    public var isQueryFocused: Bool
    public var hasCurrentTrack: Bool
    public var hasTransferBanner: Bool
    public var isNowPlayingPresented: Bool

    public init(isFindActive: Bool, isQueryFocused: Bool, hasCurrentTrack: Bool,
                hasTransferBanner: Bool, isNowPlayingPresented: Bool) {
        self.isFindActive = isFindActive
        self.isQueryFocused = isQueryFocused
        self.hasCurrentTrack = hasCurrentTrack
        self.hasTransferBanner = hasTransferBanner
        self.isNowPlayingPresented = isNowPlayingPresented
    }

    /// A stale focus signal never applies off the Find tab or over Now Playing.
    public var isEditing: Bool { isFindActive && isQueryFocused && !isNowPlayingPresented }

    public var hidesNavigationChrome: Bool { isEditing }

    public var showsMiniPlayer: Bool { hasCurrentTrack && !isEditing && !isNowPlayingPresented }
    public var showsTransferBanner: Bool { hasTransferBanner && !isEditing && !isNowPlayingPresented }

    public var accessoryHeight: CGFloat {
        let count = (showsMiniPlayer ? 1 : 0) + (showsTransferBanner ? 1 : 0)
        guard count > 0 else { return 0 }
        return CGFloat(count) * Self.trackAccessoryHeight
            + CGFloat(count - 1) * Self.accessorySpacing + Self.accessoryBottomPadding
    }
}
