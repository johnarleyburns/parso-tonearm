import Foundation

public struct DJCoachSnapshot: Sendable, Equatable {
    public var loadedA: Bool; public var playingA: Bool; public var loadedB: Bool; public var playingB: Bool
    public var syncedB: Bool; public var crossfader: Double; public var keysCompatible: Bool?
    public var dismissedTipID: String?
    public init(loadedA: Bool = false, playingA: Bool = false, loadedB: Bool = false, playingB: Bool = false,
                syncedB: Bool = false, crossfader: Double = 0.5, keysCompatible: Bool? = nil, dismissedTipID: String? = nil) {
        self.loadedA = loadedA; self.playingA = playingA; self.loadedB = loadedB; self.playingB = playingB
        self.syncedB = syncedB; self.crossfader = crossfader; self.keysCompatible = keysCompatible; self.dismissedTipID = dismissedTipID
    }
}

public struct DJCoachTip: Sendable, Equatable, Identifiable {
    public let id: String; public let text: String
    public init(id: String, text: String) { self.id = id; self.text = text }
}

public enum DJCoachPolicy {
    public static func tip(for state: DJCoachSnapshot) -> DJCoachTip? {
        let candidate: DJCoachTip?
        if !state.loadedA && !state.loadedB { candidate = .init(id: "load-a", text: "Load a track on Deck A to start.") }
        else if state.playingA && !state.loadedB { candidate = .init(id: "load-b", text: "Load your next track on Deck B.") }
        else if state.loadedB && !state.syncedB { candidate = .init(id: "sync-b", text: "Tap SYNC on Deck B to match A's tempo.") }
        else if state.loadedB && state.syncedB && !state.playingB { candidate = .init(id: "play-b", text: "B is synced to A. Press Play on the next bar, then slide the crossfader toward B.") }
        else if state.playingB && state.crossfader < 0.35 { candidate = .init(id: "fade-b", text: "Slide the crossfader toward B over the next 16 beats.") }
        else if state.playingA && state.playingB && state.crossfader > 0.8 { candidate = .init(id: "stop-a", text: "B is on air. Stop Deck A when you're ready.") }
        else if state.keysCompatible == false { candidate = .init(id: "keys", text: "These keys clash. Try Key lock or pick a track marked Key match.") }
        else { candidate = nil }
        guard let candidate, candidate.id != state.dismissedTipID else { return nil }
        return candidate
    }
}
