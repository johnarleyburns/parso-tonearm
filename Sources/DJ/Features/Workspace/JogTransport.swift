import Foundation

/// The jog's only contact with the transport (FR-ENG-11, §40.7.7). Maps the
/// four `JogGestureModel.Intent`s onto the `WorkspaceEngine` transport intents
/// the engine already defines, and is guarded by `RTGuard.assertRTSafe` so a
/// jog callback could never execute on the render thread under the §46.3 shim
/// (AT-TWIN-4).
///
/// The mapping is the honest one for the current engine surface:
/// - `.hold` pauses a playing deck (touch = hold) and `.release` resumes it —
///   a paused deck is never started by lifting the platter;
/// - `.scrub` seeks relative to the playhead — one full platter revolution
///   scrubs one beat of the deck's current tempo (§40.7.2's position intent);
/// - `.nudge` bends tempo off the deck's current rate (`base × (1 + rate)`) and
///   `.release` restores it.
///
/// Moved to its own file (plan dj-midi-alpha M3) so `WorkspaceModel` can own
/// one per deck without importing a view: a MIDI jog and a finger jog must
/// share the same transport, or their `bendBaseRate` bookkeeping would fight.
@MainActor
final class JogTransport {
    /// The §46.3 violation message carried by the jog's RT-safety guard.
    static let guardMessage = "jog → transport"

    private let engine: any WorkspaceEngine
    private let deck: PerformanceEngine.Deck
    private var heldWasPlaying = false
    private var bendBaseRate: Double?

    init(engine: any WorkspaceEngine, deck: PerformanceEngine.Deck) {
        self.engine = engine
        self.deck = deck
    }

    func route(_ intent: JogGestureModel.Intent) {
        RTGuard.assertRTSafe(Self.guardMessage)
        switch intent {
        case .hold:
            heldWasPlaying = telemetry(for: deck).playing
            if heldWasPlaying { engine.pause(deck) }
        case let .scrub(radians):
            guard radians != 0 else { return }
            let t = telemetry(for: deck)
            let perRadian = Self.scrubSamplesPerRadian(bpm: t.bpmEffective,
                                                       sampleRate: engine.sampleRate)
            guard perRadian > 0 else { return }
            let target = max(0, t.playheadSample + Int64(radians * Double(perRadian)))
            engine.seek(deck, toSample: target, quantized: false)
        case let .nudge(rate):
            if bendBaseRate == nil { bendBaseRate = engine.deckRate(deck) }
            if let base = bendBaseRate {
                engine.setRate(deck, rate: Float(base * (1 + rate)))
            }
        case .release:
            restoreBend()
            if heldWasPlaying {
                engine.play(deck)
                heldWasPlaying = false
            }
        }
    }

    /// Restore the base rate from a bend **without** releasing a held platter —
    /// the MIDI jog's idle-release path when the touch is still down (M3): a
    /// DJ holds the platter while nudging with the encoder, and the hold must
    /// survive the bend going quiet.
    func restoreBend() {
        if let base = bendBaseRate {
            engine.setRate(deck, rate: Float(base))
            bendBaseRate = nil
        }
    }

    private func telemetry(for deck: PerformanceEngine.Deck) -> EngineTelemetry.Deck {
        let t = engine.sampleTelemetry()
        return deck == .a ? t.deckA : t.deckB
    }

    /// The track samples a full platter revolution scrubs: one beat of the
    /// deck's current tempo (§40.7.2 — a thumb's arc is the effective control).
    static func scrubSamplesPerRadian(bpm: Double, sampleRate: Double) -> Int64 {
        guard bpm > 0, sampleRate > 0 else { return 0 }
        return Int64(sampleRate * 60 / bpm / (2 * .pi))
    }
}
