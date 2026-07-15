import AppIntents
import Foundation

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

@available(iOS 17.0, *)
struct TonearmTogglePlaybackIntent: AudioPlaybackIntent, LiveActivityIntent {
    static var title: LocalizedStringResource = "Play/Pause"

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let handler = TonearmPlaybackCommands.handler else { return .result() }
        await handler.ensureReady()
        handler.toggle()
        return .result()
    }
}

@available(iOS 17.0, *)
struct TonearmNextTrackIntent: AudioPlaybackIntent, LiveActivityIntent {
    static var title: LocalizedStringResource = "Next Track"

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let handler = TonearmPlaybackCommands.handler else { return .result() }
        await handler.ensureReady()
        handler.next()
        return .result()
    }
}

@available(iOS 17.0, *)
struct TonearmPreviousTrackIntent: AudioPlaybackIntent, LiveActivityIntent {
    static var title: LocalizedStringResource = "Previous Track"

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let handler = TonearmPlaybackCommands.handler else { return .result() }
        await handler.ensureReady()
        handler.previous()
        return .result()
    }
}
