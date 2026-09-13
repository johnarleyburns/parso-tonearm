import Combine
import CoreGraphics
import Foundation
import TonearmCore

/// Transport / loading — the thin per-deck forwarding calls onto the control
/// surface (`WorkspaceEngine`). Split out of `WorkspaceModel.swift` (a pure
/// reorganization, same convention as the other `WorkspaceModel+*.swift`
/// files) because these are a distinct, self-contained concern: none of them
/// touch the model's own stored state, they just forward to `engine`.
extension WorkspaceModel {

    /// The deck's current playback rate — the jog reads it as the base for a
    /// temporary pitch bend (§40.7.3).
    public func deckRate(_ deck: Deck) -> Double {
        engine.deckRate(deck)
    }

    public func load(_ deck: Deck, source: DeckSource) {
        engine.load(deck, source: source)
    }

    public func play(_ deck: Deck) {
        engine.play(deck)
    }

    public func pause(_ deck: Deck) {
        engine.pause(deck)
    }

    public func cue(_ deck: Deck) {
        engine.cue(deck)
    }

    public func releaseCue(_ deck: Deck) {
        engine.releaseCue(deck)
    }

    public func seek(_ deck: Deck, toSample: Int64, quantized: Bool) {
        engine.seek(deck, toSample: toSample, quantized: quantized)
    }

    public func setCue(_ deck: Deck, atSample: Int64) {
        engine.setCue(deck, atSample: atSample)
    }

    public func triggerHotCue(_ deck: Deck, atSample: Int64) {
        engine.triggerHotCue(deck, atSample: atSample)
    }

    public func setLoop(_ deck: Deck, beats: Double) {
        engine.setLoop(deck, beats: beats)
    }

    public func exitLoop(_ deck: Deck) {
        engine.exitLoop(deck)
    }

    public func setQuantize(_ on: Bool, resolution: QuantizeResolution) {
        engine.setQuantize(on, resolution: resolution)
    }

    public func setRate(_ deck: Deck, rate: Float) {
        engine.setRate(deck, rate: rate)
    }

    public func setKeyLock(_ deck: Deck, locked: Bool) {
        engine.setKeyLock(deck, locked: locked)
    }

    public func setKeyShift(_ deck: Deck, semitones: Float) {
        engine.setKeyShift(deck, semitones: semitones)
    }
}
