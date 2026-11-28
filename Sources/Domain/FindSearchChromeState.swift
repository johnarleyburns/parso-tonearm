import Foundation

/// Pure presentation policy for the iPhone root shell while the Find query field is focused.
/// Focus only hides chrome (title, mini-player, reserved clearance); it never touches playback.
public struct FindSearchChromeState: Equatable, Sendable {
    public static let trackAccessoryHeight: CGFloat = 56

    public var isFindActive: Bool
    public var isQueryFocused: Bool
    public var hasCurrentTrack: Bool
    public var isNowPlayingPresented: Bool
    /// The Listen tab hosts the larger Continue card instead of the mini player.
    public var isListenActive: Bool
    public var showsListenContinue: Bool

    public init(isFindActive: Bool, isQueryFocused: Bool, hasCurrentTrack: Bool,
                isNowPlayingPresented: Bool, isListenActive: Bool = false,
                showsListenContinue: Bool = false) {
        self.isFindActive = isFindActive
        self.isQueryFocused = isQueryFocused
        self.hasCurrentTrack = hasCurrentTrack
        self.isNowPlayingPresented = isNowPlayingPresented
        self.isListenActive = isListenActive
        self.showsListenContinue = showsListenContinue
    }

    /// A stale focus signal never applies off the Find tab or over Now Playing.
    public var isFindEditing: Bool { isFindActive && isQueryFocused && !isNowPlayingPresented }

    public var isEditing: Bool { isFindEditing }

    public var hidesNavigationChrome: Bool { isFindEditing }

    public var showsMiniPlayer: Bool {
        hasCurrentTrack && !isEditing && !isNowPlayingPresented
            && !(isListenActive && showsListenContinue)
    }

    public var accessoryHeight: CGFloat {
        showsMiniPlayer ? Self.trackAccessoryHeight : 0
    }
}
