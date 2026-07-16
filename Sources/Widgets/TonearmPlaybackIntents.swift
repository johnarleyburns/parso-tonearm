import AppIntents
import Foundation
import TonearmCore

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
