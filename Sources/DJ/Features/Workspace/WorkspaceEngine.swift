import Combine
import CoreGraphics
import Foundation
import TonearmCore

import Combine
import CoreGraphics
import Foundation
import TonearmCore

/// The control/telemetry seam the session view model talks to. `PAEWorkspaceEngine`
/// conforms; tests inject a recording fake so the model's states and gate are
/// exercised deterministically (plan 4.6, §47.2).
@MainActor
public protocol WorkspaceEngine: AnyObject {
    var masterSample: Int64 { get }
    var telemetry: AsyncStream<EngineTelemetry> { get }
    /// The buffer period in milliseconds (mockup `ipad/07` readout, §34.2).
    var bufferPeriodMillis: Double { get }
    /// The configured master limiter ceiling, nil when the limiter is out of
    /// the path (§35.5).
    var limiterCeiling: Float? { get }
    /// The graph's sample rate — the model renders playheads as clock time
    /// from this (mockup `iphone/05a`'s −mm:ss readouts).
    var sampleRate: Double { get }
    /// The deck's current playback rate — the jog's pitch-bend base (§40.7.3).
    func deckRate(_ deck: Deck) -> Double
    func start() throws
    func stop()
    func load(_ deck: Deck, source: DeckSource)
    func play(_ deck: Deck)
    func pause(_ deck: Deck)
    func cue(_ deck: Deck)
    func releaseCue(_ deck: Deck)
    func seek(_ deck: Deck, toSample: Int64, quantized: Bool)
    func setCue(_ deck: Deck, atSample: Int64)
    func triggerHotCue(_ deck: Deck, atSample: Int64)
    func setLoopRange(_ deck: Deck, start: Int64, end: Int64)
    func setLoop(_ deck: Deck, beats: Double)
    func exitLoop(_ deck: Deck)
    func setQuantize(_ on: Bool, resolution: QuantizeResolution)
    func setRate(_ deck: Deck, rate: Float)
    func setKeyLock(_ deck: Deck, locked: Bool)
    func setKeyShift(_ deck: Deck, semitones: Float)
    func sync(_ deck: Deck, to master: Deck, barSync: Bool)
    func unsync(_ deck: Deck)
    func isSynced(_ deck: Deck) -> Bool
    func setEQKnobs(_ deck: Deck, low: Float, mid: Float, high: Float)
    func setFilter(_ deck: Deck, knob: Float)
    func setChannelFader(_ deck: Deck, gain: Float)
    func setCrossfader(_ position: Float, curve: CrossfaderCurve)
    func setEchoEnabled(_ deck: Deck, enabled: Bool)
    func setEchoBeats(_ deck: Deck, beats: Double)
    func setEchoDepth(_ deck: Deck, depth: Float)
    func setEchoFeedback(_ deck: Deck, feedback: Float)
    /// Arm a prepared `StemSet` for a deck, or disarm it with `nil` (§35.1,
    /// plan 5.8). A disarmed deck reads the single full-mix source.
    func armStemSet(_ deck: Deck, stemSet: StemSet?)
    /// Set a stem voice's gain target — a linear gain, smoothed render-side.
    func setStemGain(_ deck: Deck, stem: SeparationVoice, gain: Float)
    /// Mute a stem voice — its gain target ramps to 0.
    func setStemMute(_ deck: Deck, stem: SeparationVoice, muted: Bool)
    /// Solo a stem voice — when any voice is soloed, only soloed voices sound.
    func setStemSolo(_ deck: Deck, stem: SeparationVoice, soloed: Bool)
    /// Start recording the post-limiter master bus (§37.2, plan 5.10). The
    /// record toggle (decision 14) forwards this; the engine starts the tap +
    /// encoder. Returns the per-session output directory — 5.11's journal
    /// derives the `mix_asset` path from it. Throws when the graph has no
    /// record tap (built with `recordTapEnabled: false`) — an honest
    /// unavailable state, never a silent no-op.
    func startRecording() async throws -> URL
    /// Stop recording and return the finished recording (segments + metadata).
    func stopRecording() async throws -> RecordingEncoder.RecordingOutput?
    /// Whether a recording is currently in flight (decision 14's session state).
    var isRecording: Bool { get }
    /// §44.2a: route a deck to the pre-fader cue bus.
    func setHeadphoneCue(_ deck: Deck, enabled: Bool)
    /// §44.2a: the global cue mode.
    func setCueMode(_ mode: CueMode)
    /// Frames the record tap dropped because the ring was full (§37.2) — what
    /// the recording lost while the live performance carried on. Carried into
    /// the journal so a starved drain names itself.
    var droppedRecordFrames: UInt64 { get }
    /// Whether the graph reports itself running (NFR-REL-2, §34A.5). Necessary
    /// but not sufficient — see `EngineLiveness`.
    var isGraphRunning: Bool { get }
    /// `AVAudioEngineConfigurationChange` for this engine's graph.
    func configurationChanges() -> AsyncStream<Void>
    /// Restart a stopped graph in place (§34A.5).
    func recoverGraph() throws
    /// §34A.4 `.began` (plan 5.11): flush the active recording's current
    /// segment so it is a complete playable M4A — NFR-REL-2's critical line.
    func interruptRecordingForInterruption() async throws
    /// §34A.4 `.ended` with `.shouldResume` (plan 5.11): open a **new** segment,
    /// never the flushed one. Decks are never auto-played here.
    func resumeRecordingFromInterruption() async throws
    func sampleTelemetry() -> EngineTelemetry
    func pushTelemetry()
}

public extension WorkspaceEngine {
    /// An engine with no record tap dropped nothing — the honest default for
    /// every offline harness and test double (§47.2), so only the real graph
    /// has to answer this.
    var droppedRecordFrames: UInt64 { 0 }

    /// An offline harness is running by definition — it is pulled by the test,
    /// not by hardware — and has no configuration to change. Only the realtime
    /// graph can lose liveness, so only it has to answer these.
    var isGraphRunning: Bool { true }
    func configurationChanges() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func recoverGraph() throws {}

    /// The offline harness has no output route, so there is nothing to monitor
    /// on: cue is inert there by construction (§44.2a).
    func setHeadphoneCue(_ deck: Deck, enabled: Bool) {}
    func setCueMode(_ mode: CueMode) {}
}
