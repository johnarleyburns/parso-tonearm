import AVFoundation
import Foundation

/// The main-actor control/telemetry façade over the RT audio engine (App. I.4,
/// plan §2.7).
///
/// Every mutating call enqueues a lock-free `RTCommand` on the command ring
/// (§12.2) and returns immediately — none of them block on audio. The 4.3
/// surface is single-deck transport/loading — `load/play/pause/cue/seek/
/// setQuantize`, hot cues and loops; sync, mixer and recording members land
/// with their commits (4.4–4.6, plan §2.7) rather than being stubbed.
///
/// `load` boxes the caller's `DeckSource` into a heap allocation whose raw
/// pointer becomes the `loadArm` ownership-transfer marker (§12.2). The box is
/// the render thread's only view of the source: it reads the pure value with a
/// plain memory load, no ARC, no lock. The façade keeps each box alive until the
/// deck is reloaded, and reclaims it then (safe here — the offline harness is
/// synchronous; the real-time retire list arrives with the live graph).
@MainActor
public final class PerformanceEngine {

    public enum Deck: UInt8, Sendable, Hashable {
        case a = 0
        case b = 1
    }

    public let graph: AudioGraph
    private let registry = SourceBoxRegistry()

    public init(graph: AudioGraph) {
        self.graph = graph
    }

    public convenience init(configuration: AudioGraph.Configuration = .init()) throws {
        self.init(graph: try AudioGraph(configuration: configuration))
    }

    deinit {
        registry.reclaimAll()
    }

    // MARK: - Engine lifecycle

    public func start() throws { try graph.start() }
    public func stop() { graph.stop() }

    // MARK: - Telemetry (read-only; sampled at display cadence, §40.3)

    /// The control channel (tests drive it through the ring, §6).
    public var commandRing: CommandRing { graph.commandRing }
    public var masterSample: Int64 { graph.masterSample }
    public var starvedFrames: UInt64 { graph.starvedFrames }
    public var guardWasActive: Bool { graph.guardWasActive }
    public func deckPlayhead(_ deck: Deck) -> Int64 { graph.deckPlayhead(deck.rawValue) }

    // MARK: - Transport / loading

    /// Arm a pre-decoded source for a deck. Ownership of the `DeckSource`'s PCM
    /// memory stays with the caller; the engine boxes only the (pure-value)
    /// descriptor.
    public func load(_ deck: Deck, source: DeckSource) {
        precondition(source.sampleRate == graph.sampleRate,
                     "deck source sample rate must match the engine graph")
        precondition(source.channelCount == Int(graph.channelCount),
                     "deck source channel count must match the engine graph")
        let box = UnsafeMutablePointer<DeckSource>.allocate(capacity: 1)
        box.initialize(to: source)
        registry.replace(deck, with: box)
        _ = graph.commandRing.tryPush(.loadArm(deck: deck.rawValue, source: UnsafeRawPointer(box)))
    }

    public func play(_ deck: Deck) {
        _ = graph.commandRing.tryPush(.play(deck: deck.rawValue))
    }

    public func pause(_ deck: Deck) {
        _ = graph.commandRing.tryPush(.pause(deck: deck.rawValue))
    }

    /// Move the playhead to `toSample`; when `quantized`, to the next grid
    /// boundary at-or-after it (§30.3).
    public func seek(_ deck: Deck, toSample: Int64, quantized: Bool) {
        _ = graph.commandRing.tryPush(.seek(deck: deck.rawValue, toSample: toSample, quantized: quantized))
    }

    /// Set the temporary CDJ cue point at an explicit track sample (§33.1).
    public func setCue(_ deck: Deck, atSample: Int64) {
        _ = graph.commandRing.tryPush(.setCue(deck: deck.rawValue, atSample: atSample))
    }

    /// Press the CUE transport — jump to the temporary cue point and preview
    /// while held (§33.1).
    public func cue(_ deck: Deck) {
        _ = graph.commandRing.tryPush(.cuePress(deck: deck.rawValue))
    }

    /// Release CUE — return to the pre-preview position and pause.
    public func releaseCue(_ deck: Deck) {
        _ = graph.commandRing.tryPush(.cueRelease(deck: deck.rawValue))
    }

    /// Trigger a hot cue (from `cue_point`). Honors the deck's quantize state
    /// (§33.1, §33.3).
    public func triggerHotCue(_ deck: Deck, atSample: Int64) {
        _ = graph.commandRing.tryPush(.triggerHotCue(deck: deck.rawValue, atSample: atSample))
    }

    /// Engage a loop `[start, end)` (§33.2).
    public func setLoopRange(_ deck: Deck, start: Int64, end: Int64) {
        _ = graph.commandRing.tryPush(.setLoop(deck: deck.rawValue, start: start, end: end))
    }

    /// CDJ-style loop of `beats` from the deck's current playhead (exact
    /// telemetry), snapped to the grid (§33.2).
    public func setLoop(_ deck: Deck, beats: Double) {
        let start = deckPlayhead(deck)
        let grid = currentGrid(deck)
        let end = CueLoop.loopEnd(start: start, beats: beats, grid: grid)
        setLoopRange(deck, start: start, end: end)
    }

    public func exitLoop(_ deck: Deck) {
        _ = graph.commandRing.tryPush(.exitLoop(deck: deck.rawValue))
    }

    /// Set the global quantize state (both decks, §33.3).
    public func setQuantize(_ on: Bool, resolution: QuantizeResolution) {
        for deck in [Deck.a, Deck.b] {
            _ = graph.commandRing.tryPush(.setQuantize(deck: deck.rawValue, on: on, resolution: resolution))
        }
    }

    /// Set the deck's playback rate (§31.1).
    public func setRate(_ deck: Deck, rate: Float) {
        _ = graph.commandRing.tryPush(.setRate(deck: deck.rawValue, rate: rate))
    }

    /// Engage/disengage key lock: pitch is held constant while the deck's
    /// tempo (rate) changes (§31.2).
    public func setKeyLock(_ deck: Deck, locked: Bool) {
        _ = graph.commandRing.tryPush(.setKeyLock(deck: deck.rawValue, locked: locked))
    }

    /// Shift the deck's musical key by ±N semitones, rate held — harmonic
    /// mixing (§31.3). The UI reads the shifted key back for the Camelot hint.
    public func setKeyShift(_ deck: Deck, semitones: Float) {
        _ = graph.commandRing.tryPush(.setKeyShift(deck: deck.rawValue, semitones: semitones))
    }

    // MARK: - Mixer (§35)

    /// Set the deck's 3-band EQ from knob positions (−1 kill … 0 unity …
    /// +1 max boost). The knob-to-gain mapping is `ThreeBandEQ.knobToGain`
    /// (§35.2); the gains cross the ring as linear values.
    public func setEQKnobs(_ deck: Deck, low: Float, mid: Float, high: Float) {
        _ = graph.commandRing.tryPush(.setEQ(deck: deck.rawValue,
                                             low: ThreeBandEQ.knobToGain(low),
                                             mid: ThreeBandEQ.knobToGain(mid),
                                             high: ThreeBandEQ.knobToGain(high)))
    }

    /// Set the deck's sweep filter knob (−1 … 1; the centre detent bypasses,
    /// §35.3).
    public func setFilter(_ deck: Deck, knob: Float) {
        _ = graph.commandRing.tryPush(.setFilter(deck: deck.rawValue, knob: knob))
    }

    /// Set the deck's channel fader (trim) gain (§35.4).
    public func setChannelFader(_ deck: Deck, gain: Float) {
        _ = graph.commandRing.tryPush(.setFader(deck: deck.rawValue, gain: gain))
    }

    /// Position the master crossfader (−1 = deck A full … +1 = deck B full).
    /// The first call arms the crossfader; before that both decks pass at
    /// unity (§35.4).
    public func setCrossfader(_ position: Float, curve: CrossfaderCurve) {
        _ = graph.commandRing.tryPush(.setCrossfader(position: position, curve: curve))
    }

    // MARK: - Offline rendering (harness)

    public func render(_ frameCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        try graph.render(frameCount)
    }

    /// Render and return channel 0 as a `[Float]` — the control-side assertion
    /// surface for the offline harness (§47.2).
    public func renderMono(_ frameCount: AVAudioFrameCount) throws -> [Float] {
        let buffer = try graph.render(frameCount)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private func currentGrid(_ deck: Deck) -> DeckGrid {
        guard let box = registry.box(deck) else { return DeckGrid(sampleRate: graph.sampleRate) }
        return box.pointee.grid
    }
}

/// The control side owns the boxed `DeckSource` allocations (the §12.2
/// ownership-transfer contract). This registry keeps them alive for the render
/// thread's duration and reclaims them when a deck is reloaded or the engine
/// deallocates. `@unchecked Sendable` so the `deinit` (nonisolated) can reach it.
private final class SourceBoxRegistry: @unchecked Sendable {
    private var boxes: [PerformanceEngine.Deck: UnsafeMutablePointer<DeckSource>] = [:]

    func replace(_ deck: PerformanceEngine.Deck, with box: UnsafeMutablePointer<DeckSource>) {
        if let old = boxes[deck] {
            old.deinitialize(count: 1)
            old.deallocate()
        }
        boxes[deck] = box
    }

    func box(_ deck: PerformanceEngine.Deck) -> UnsafeMutablePointer<DeckSource>? {
        boxes[deck]
    }

    func reclaimAll() {
        for box in boxes.values {
            box.deinitialize(count: 1)
            box.deallocate()
        }
        boxes.removeAll()
    }
}
