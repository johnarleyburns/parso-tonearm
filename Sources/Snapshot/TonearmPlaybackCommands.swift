import Foundation

/// The playback commands the Live Activity / widget intents dispatch. Lives in
/// Core so `AudioPlayer` can conform (the app wires `handler = .shared`), while
/// the `AppIntents` structs that call these stay in the app/extension target.
@MainActor
protocol TonearmPlaybackCommanding {
    func toggle()
    func next()
    func previous()
    /// Restores the play queue from persisted state when the app was relaunched
    /// by an intent and the player is empty, so commands never no-op.
    func ensureReady() async
}

@MainActor
enum TonearmPlaybackCommands {
    static var handler: (any TonearmPlaybackCommanding)?
}
