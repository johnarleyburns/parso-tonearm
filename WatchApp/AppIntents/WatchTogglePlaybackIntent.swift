import AppIntents
import Foundation

/// Watch redesign A2 — the Smart Stack widget's play/pause. As an `AudioPlaybackIntent` it runs in
/// the watch app's process (which owns the audio), so the widget extension compiles only the
/// declaration (`PLATTERHEAD_WATCH_WIDGET`) and the app compiles the real `perform()`.
struct ToggleWatchPlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play or Pause Platterhead"
    static let description = IntentDescription("Plays or pauses what Platterhead is playing.")

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !PLATTERHEAD_WATCH_WIDGET
        if WatchPlayer.shared.currentTrack == nil { await WatchPlayer.shared.restorePositionIfAvailable() }
        WatchPlayer.shared.togglePlayPause()
        #endif
        return .result()
    }
}
