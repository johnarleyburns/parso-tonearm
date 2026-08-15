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
    private let stemRegistry = StemSetRegistry()
    /// Where recordings land (plan 5.10): the parent directory per-recording
    /// subdirectories are created under. Defaults to the DJ Mixes directory;
    /// tests inject a temp directory.
    public let recordingDirectory: URL
    /// The §37.2 encoder currently draining (plan 5.10, FR-ENG-7). `nil` while
    /// not recording.
    private var recordingEncoder: RecordingEncoder?
    /// The off-RT drain loop for the active recording.
    private var drainTask: Task<Void, Never>?

    public init(graph: AudioGraph,
                recordingDirectory: URL = DJDatabase.mixesDirectory) {
        self.graph = graph
        self.recordingDirectory = recordingDirectory
    }

    public convenience init(configuration: AudioGraph.Configuration = .init(),
                            recordingDirectory: URL = DJDatabase.mixesDirectory) throws {
        self.init(graph: try AudioGraph(configuration: configuration),
                  recordingDirectory: recordingDirectory)
    }

    deinit {
        registry.reclaimAll()
        stemRegistry.reclaimAll()
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

    /// The buffer period in milliseconds (mockup `ipad/07`'s "256 · 11.4 ms"
    /// readout, from the graph's granted buffer — §34.2).
    public var bufferPeriodMillis: Double { graph.bufferPeriodMillis }

    /// The graph's sample rate, used to render playheads as clock time.
    public var sampleRate: Double { graph.sampleRate }

    /// The configured master limiter ceiling, nil when the limiter is out of
    /// the path (§35.5).
    public var limiterCeiling: Float? { graph.limiterCeiling }

    /// The deck's current playback rate (published by the render thread each
    /// callback — §32.1). The jog's pitch-bend intent reads it as the base for
    /// its temporary tempo offset (§40.7.3).
    public func deckRate(_ deck: Deck) -> Double {
        Double(graph.deckRate(deck.rawValue))
    }

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

    // MARK: - Beat FX — the §35A post-fader echo (FR-TRANS-4, plan 5.5)

    /// Turn the deck's §35A echo on/off. Disabling stops new input to the line
    /// but the tail keeps ringing until it decays, then bypasses (§35A.2).
    public func setEchoEnabled(_ deck: Deck, enabled: Bool) {
        _ = graph.commandRing.tryPush(.setEchoEnabled(deck: deck.rawValue, enabled: enabled))
    }

    /// Set the deck's §35A echo beat length (1/4 … 4 beats). The delay is
    /// derived from the master clock, so a tempo change moves the echo with it.
    public func setEchoBeats(_ deck: Deck, beats: Double) {
        _ = graph.commandRing.tryPush(.setEchoBeats(deck: deck.rawValue, beats: beats))
    }

    /// Set the deck's §35A echo wet depth (0…1).
    public func setEchoDepth(_ deck: Deck, depth: Float) {
        _ = graph.commandRing.tryPush(.setEchoDepth(deck: deck.rawValue, depth: depth))
    }

    /// Set the deck's §35A echo feedback — tail length, 0…0.85 (clamped below
    /// unity so the tail always decays).
    public func setEchoFeedback(_ deck: Deck, feedback: Float) {
        _ = graph.commandRing.tryPush(.setEchoFeedback(deck: deck.rawValue, feedback: feedback))
    }

    // MARK: - Stems (§35.1, plan 5.8)

    /// Arm a prepared `StemSet` for a deck, or disarm it with `nil` (§35.1,
    /// plan decision 3). Ownership of the set's PCM memory stays with the
    /// caller; the engine boxes only the (pure-value) descriptor, exactly like
    /// `load(_:source:)`. A disarmed deck reads the single full-mix source,
    /// byte-for-byte.
    public func armStemSet(_ deck: Deck, stemSet: StemSet?) {
        if let stemSet {
            let box = UnsafeMutablePointer<StemSet>.allocate(capacity: 1)
            box.initialize(to: stemSet)
            stemRegistry.replace(deck, with: box)
            _ = graph.commandRing.tryPush(.armStemSet(deck: deck.rawValue, stemSet: UnsafeRawPointer(box)))
        } else {
            stemRegistry.replace(deck, with: nil)
            _ = graph.commandRing.tryPush(.armStemSet(deck: deck.rawValue, stemSet: nil))
        }
    }

    /// Set a stem voice's gain target — a linear gain, smoothed render-side so
    /// a fader move never clicks (§35.1).
    public func setStemGain(_ deck: Deck, stem: StemKind, gain: Float) {
        _ = graph.commandRing.tryPush(.setStemGain(deck: deck.rawValue, stem: stem, gain: gain))
    }

    /// Mute a stem voice — its gain target drops to 0 through the same ramp.
    public func setStemMute(_ deck: Deck, stem: StemKind, muted: Bool) {
        _ = graph.commandRing.tryPush(.setStemMute(deck: deck.rawValue, stem: stem, muted: muted))
    }

    /// Solo a stem voice — when any voice is soloed, only soloed voices sound.
    public func setStemSolo(_ deck: Deck, stem: StemKind, soloed: Bool) {
        _ = graph.commandRing.tryPush(.setStemSolo(deck: deck.rawValue, stem: stem, soloed: soloed))
    }

    // MARK: - Sync (§32, FR-ENG-4)

    /// Engage beat sync: tempo-match `deck` to `master` and phase-align its
    /// beats at the sync instant (§32.1). `barSync` aligns downbeats rather
    /// than beats (§32.2). While engaged the render thread keeps the deck's
    /// rate tracking the master (continuous, §32.1), so a master pitch change
    /// moves the synced deck with it. The correction is computed purely
    /// (`SyncEngine`) and applied as a rate command plus a scheduled,
    /// sample-accurate nudge.
    public func sync(_ deck: Deck, to master: Deck, barSync: Bool = false) {
        let correction = barSync
            ? SyncEngine.downbeatCorrection(master: clockSnapshot(master),
                                            synced: clockSnapshot(deck),
                                            atMasterSample: graph.masterSample)
            : SyncEngine.correction(master: clockSnapshot(master),
                                    synced: clockSnapshot(deck),
                                    atMasterSample: graph.masterSample)
        _ = graph.commandRing.tryPush(.setRate(deck: deck.rawValue, rate: correction.setRate))
        if correction.playheadShiftSamples != 0 {
            _ = graph.commandRing.tryPush(.syncNudge(deck: deck.rawValue,
                                                     shiftSamples: correction.playheadShiftSamples))
        }
        _ = graph.commandRing.tryPush(.sync(deck: deck.rawValue, master: master.rawValue))
    }

    /// Disengage sync; the deck returns to manual rate control.
    public func unsync(_ deck: Deck) {
        _ = graph.commandRing.tryPush(.unsync(deck: deck.rawValue))
    }

    /// Whether beat sync is currently engaged for the deck (read from the
    /// render thread's published state, §32.1).
    public func isSynced(_ deck: Deck) -> Bool {
        graph.deckIsSynced(deck.rawValue)
    }

    private func clockSnapshot(_ deck: Deck) -> SyncClock {
        SyncClock(playheadSample: Double(deckPlayhead(deck)),
                  grid: currentGrid(deck),
                  rate: Double(graph.deckRate(deck.rawValue)))
    }

    // MARK: - Telemetry (§40.3, App. I.4)

    /// Sample the published atomics into one telemetry value. The display-rate
    /// pump calls this and hands the value to `pushTelemetry`; the workspace
    /// readouts and beat-phase meter are driven by the result (§40.3).
    public func sampleTelemetry() -> EngineTelemetry {
        EngineTelemetry(masterSample: graph.masterSample,
                        masterBPM: graph.masterClock.masterBPM,
                        downbeatPhase: graph.masterClock.downbeatPhase,
                        deckA: deckTelemetry(.a),
                        deckB: deckTelemetry(.b),
                        masterLevel: graph.masterLevel,
                        renderLoad: graph.renderLoadRatio)
    }

    private func deckTelemetry(_ deck: Deck) -> EngineTelemetry.Deck {
        let playhead = deckPlayhead(deck)
        let clock = clockSnapshot(deck)
        return EngineTelemetry.Deck(playheadSample: playhead,
                                    bpmEffective: clock.effectiveBPM,
                                    phase: clock.beatPhase(at: clock.playheadSample),
                                    level: graph.deckLevel(deck.rawValue),
                                    playing: graph.deckIsPlaying(deck.rawValue),
                                    synced: graph.deckIsSynced(deck.rawValue))
    }

    /// The atomics → `AsyncStream` bridge. The pump yields sampled values here;
    /// the session view model awaits them (App. I.4, §40.3).
    public let telemetryStream = EngineTelemetryStream()

    /// The consumer stream over `telemetryStream`.
    public var telemetry: AsyncStream<EngineTelemetry> { telemetryStream.stream }

    /// Sample the atomics and yield the value onto the telemetry stream
    /// (display cadence, §40.3).
    public func pushTelemetry() {
        telemetryStream.push(sampleTelemetry())
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

    // MARK: - Recording (§37.2, FR-ENG-7; plan 5.10, 5.11)

    /// Start recording the post-limiter master bus (§37.2). Creates the
    /// `RecordingEncoder` for a fresh per-session subdirectory, starts it,
    /// enables the tap, and kicks off the off-RT drain loop. Returns the
    /// per-session output directory — 5.11's `RecordingService` journals it
    /// (the `mix_asset.localRelPath` derives from it). Throws when the graph
    /// has no record tap (built with `recordTapEnabled: false`) — an honest
    /// unavailable state, never a silent no-op.
    public func startRecording() async throws -> URL {
        guard let tap = graph.recordTap else {
            throw RecordingEncoder.RecordingError.tapNotRecording
        }
        guard recordingEncoder == nil else {
            return recordingDirectory.appendingPathComponent("already-recording")
        }
        let sessionDir = recordingDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let encoder = try RecordingEncoder(
            tap: tap,
            configuration: .init(sampleRate: graph.sampleRate,
                                 channelCount: Int(graph.channelCount),
                                 segmentFrames: 30 * Int(graph.sampleRate),
                                 outputDirectory: sessionDir))
        try await encoder.start()
        recordingEncoder = encoder
        tap.setRecording(true)
        let drainTask = Task.detached { [encoder] in
            while !Task.isCancelled {
                _ = try? await encoder.drain(maxFrames: 8192)
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        self.drainTask = drainTask
        return sessionDir
    }

    /// Stop recording: stop the tap, drain and finalize, and return the
    /// finished recording (segments + metadata for the `mix`/`mix_asset`
    /// rows). Nil when nothing was recording.
    public func stopRecording() async throws -> RecordingEncoder.RecordingOutput? {
        guard let encoder = recordingEncoder else { return nil }
        graph.recordTap?.setRecording(false)
        drainTask?.cancel()
        drainTask = nil
        recordingEncoder = nil
        return try await encoder.finalize()
    }

    /// Frames the record tap dropped because the ring was full (§37.2). Zero
    /// on a graph with no tap. The tap drops rather than blocking — the live
    /// performance is never held up by a slow encoder — so this is the honest
    /// count of what the recording lost, and the journal carries it so the
    /// analyzer can name a starved drain instead of puzzling over a hole.
    public var droppedRecordFrames: UInt64 {
        graph.recordTap?.droppedFrames ?? 0
    }

    /// §34A.4 `.began` (plan 5.11): flush the active recording's current
    /// segment so it is a complete playable M4A — the critical line behind
    /// NFR-REL-2. A no-op when nothing is recording (nothing to flush).
    public func interruptRecordingForInterruption() async throws {
        guard let encoder = recordingEncoder else { return }
        try await encoder.interruptSegment()
    }

    /// §34A.4 `.ended` with `.shouldResume` (plan 5.11): open a **new** segment,
    /// never the flushed one. A no-op when nothing is recording. Decks are
    /// never auto-played here — the resume is the human's call (§34A.4).
    public func resumeRecordingFromInterruption() async throws {
        guard let encoder = recordingEncoder else { return }
        try await encoder.resumeSegment()
    }

    /// Whether a recording is currently in flight (the workspace's record
    /// toggle state, decision 14).
    public var isRecording: Bool {
        recordingEncoder != nil
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

/// The control side owns the boxed `StemSet` allocations (the §12.2
/// ownership-transfer contract), exactly like `SourceBoxRegistry` for deck
/// sources. This registry keeps them alive for the render thread's duration
/// and reclaims them when a set is replaced/disarmed or the engine deallocates.
private final class StemSetRegistry: @unchecked Sendable {
    private var boxes: [PerformanceEngine.Deck: UnsafeMutablePointer<StemSet>] = [:]

    func replace(_ deck: PerformanceEngine.Deck, with box: UnsafeMutablePointer<StemSet>?) {
        if let old = boxes[deck] {
            old.deinitialize(count: 1)
            old.deallocate()
        }
        boxes[deck] = box
    }

    func reclaimAll() {
        for box in boxes.values {
            box.deinitialize(count: 1)
            box.deallocate()
        }
        boxes.removeAll()
    }
}
