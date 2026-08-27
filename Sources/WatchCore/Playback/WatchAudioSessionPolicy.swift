import Foundation

/// A system audio-lifecycle event the watch playback layer must react to. These map one-to-one to
/// `AVAudioSession` notifications and watchOS scene transitions, but the type is platform-free so the
/// decision table is fully host-tested (§7.2, §11.1).
public enum WatchAudioEvent: Equatable, Sendable {
    /// No route is available, or the active route went away (headphones unplugged / disconnected).
    case routeLost
    /// A route became available again. The watch never auto-resumes on this — the user decides.
    case routeAvailable
    /// An interruption began (a call, Siri, another app taking the session).
    case interruptionBegan
    /// An interruption ended. `shouldResume` is the system's hint that resuming is appropriate.
    case interruptionEnded(shouldResume: Bool)
    /// The media server crashed and restarted; every session/player object is now invalid.
    case mediaServicesReset
    /// The app moved to the background. Background audio keeps playing; we only checkpoint.
    case appDidBackground
    /// The app returned to the foreground.
    case appWillForeground
    /// The wrist went down. Local playback continues.
    case wristDown
}

/// One concrete step the platform adapter performs, in the returned order.
public enum WatchAudioAction: Equatable, Sendable {
    /// Pause the player.
    case pause
    /// Persist the current queue snapshot now.
    case persist
    /// Reconfigure and reactivate the audio session, then reload the current item into a fresh player.
    case rebuildSession
    /// Resume playback, but only if the engine was playing when the event arrived.
    case resumeIfWasPlaying
    /// Surface "Choose headphones or a speaker" and stay paused.
    case showRouteHint
    /// Clear any route hint that was shown.
    case clearRouteHint
}

/// The pure route/interruption/media-reset decision table for watch-local playback (§7.2).
///
/// Invariants:
/// - an interruption or route loss always parks the player *paused* and *persisted*;
/// - nothing here ever auto-plays except `interruptionEnded(shouldResume: true)` while the engine was
///   already playing — and even then only via `resumeIfWasPlaying`, which the caller gates;
/// - a media-services reset rebuilds from the persisted snapshot and stays paused.
public enum WatchAudioSessionPolicy {
    public static func actions(for event: WatchAudioEvent, wasPlaying: Bool) -> [WatchAudioAction] {
        switch event {
        case .routeLost:
            return [.pause, .persist, .showRouteHint]
        case .routeAvailable:
            return [.clearRouteHint]
        case .interruptionBegan:
            return [.pause, .persist]
        case .interruptionEnded(let shouldResume):
            guard shouldResume, wasPlaying else { return [] }
            return [.rebuildSession, .resumeIfWasPlaying]
        case .mediaServicesReset:
            return [.pause, .rebuildSession, .persist]
        case .appDidBackground:
            return [.persist]
        case .appWillForeground:
            return []
        case .wristDown:
            return []
        }
    }
}
