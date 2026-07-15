import AppIntents
import Foundation

@MainActor
protocol TonearmPlaybackCommanding {
    func toggle()
    func next()
    func previous()
}

@MainActor
enum TonearmPlaybackCommands {
    static var handler: (any TonearmPlaybackCommanding)?
}

@available(iOS 17.0, *)
struct TonearmTogglePlaybackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play/Pause"

    @MainActor
    func perform() async throws -> some IntentResult {
        TonearmPlaybackCommands.handler?.toggle()
        return .result()
    }
}

@available(iOS 17.0, *)
struct TonearmNextTrackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Next Track"

    @MainActor
    func perform() async throws -> some IntentResult {
        TonearmPlaybackCommands.handler?.next()
        return .result()
    }
}

@available(iOS 17.0, *)
struct TonearmPreviousTrackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Previous Track"

    @MainActor
    func perform() async throws -> some IntentResult {
        TonearmPlaybackCommands.handler?.previous()
        return .result()
    }
}
