import AVFoundation
import Foundation
import Synchronization

public enum AudioGraphError: Error, Equatable {
    case failedToEnableManualRendering
    case failedToAllocateRenderBuffer
    case renderFailed(status: AVAudioEngineManualRenderingStatus)
}

/// The offline `AVAudioEngine` graph (plan §2.5, commit 4.1; §29 from 4.3).
///
/// The graph hosts two decks, each backed by a `DeckState` (the deck reader):
/// a pre-decoded PCM source is armed via `loadArm`, and the render block walks
/// the output buffer splitting it at sample-accurate loop and cue boundaries
/// (§30.2), exactly as the §30.2 pseudocode specifies. Control never touches
/// render state directly — only `RTCommand`s cross the boundary (§12.2). The
/// engine runs in `.offline` manual-rendering mode, so the harness is fully
/// deterministic on the `swift test` macOS host — no hardware (§47.2 "engine
/// integration, deterministic" tier).
///
/// The render block runs under the `RTGuard` shim and meters itself with
/// `RenderLoad`. The callback deliberately captures the ring/snapshot/load/
/// probe/graph-state objects rather than `self`, so the graph's lifetime is not
/// tied to the engine's, and the DEBUG probe (`guardWasActive`) proves the shim
/// wraps the callback.
///
/// After each callback the graph publishes the master sample and both decks'
/// playheads through relaxed atomics — the telemetry surface the control side
/// reads at display cadence (§30.1, §40.3). A playing deck with no valid source
/// (or one that has run past the end of its track) renders silence and bumps
/// the `starvedFrames` counter instead of garbage (§46.2).
public final class AudioGraph: @unchecked Sendable {

    public struct Configuration: Sendable {
        public var sampleRate: Double
        public var channelCount: AVAudioChannelCount
        public var maximumFrameCount: AVAudioFrameCount
        public var ringCapacity: Int
        /// Master limiter ceiling; `nil` leaves the limiter out of the path.
        /// The offline deck-reader harness runs without one so its assertions
        /// stay frame-exact; mixer tests configure it explicitly (§35.5).
        public var limiterCeiling: Float?
        /// Master limiter lookahead in frames (0 = delay-free brickwall).
        public var limiterLookaheadFrames: Int
        /// Engage the per-deck `AVAudioUnitTimePitch` graph (§31, plan 4.5).
        ///
        /// When `false` the graph is the bit-exact single-source-node deck
        /// reader (the frame-exact tier); when `true` each deck routes through
        /// its own time-pitch unit (`source → unit → main mixer`, §29.1) and
        /// the pitch/key offline tests render real stretched output. The
        /// time-pitch topology is the §31 pitch tier — the master stage
        /// (crossfader/limiter, §35.5) is exercised by the direct topology, so
        /// `limiterCeiling` is not applied here. Default `false`.
        public var timePitch: Bool

        public init(sampleRate: Double = 48_000,
                    channelCount: AVAudioChannelCount = 1,
                    maximumFrameCount: AVAudioFrameCount = 4096,
                    ringCapacity: Int = 8,
                    limiterCeiling: Float? = nil,
                    limiterLookaheadFrames: Int = 0,
                    timePitch: Bool = false) {
            self.sampleRate = sampleRate
            self.channelCount = channelCount
            self.maximumFrameCount = maximumFrameCount
            self.ringCapacity = ringCapacity
            self.limiterCeiling = limiterCeiling
            self.limiterLookaheadFrames = limiterLookaheadFrames
            self.timePitch = timePitch
        }
    }

    public let sampleRate: Double
    public let channelCount: AVAudioChannelCount
    /// The manual-rendering maximum frame count per callback (§34.1).
    public let maximumFrameCount: AVAudioFrameCount
    /// The control channel: commands are enqueued here and drained by the
    /// render thread (§12.2).
    public let commandRing: CommandRing
    /// Published snapshots are read once per callback (§12.2).
    public let snapshot: EngineSnapshot
    /// Meters the render callback (§34.3).
    public let renderLoad: RenderLoad

    /// DEBUG: true after a render that ran inside `RTGuard.withRenderContext`
    /// (the shim actually wrapped the callback). Always false in RELEASE.
    public var guardWasActive: Bool {
        guardProbe.flag.load(ordering: .relaxed)
    }

    /// The master clock's absolute sample position (published after each
    /// callback — §30.1).
    public var masterSample: Int64 {
        graphState.masterSampleAtomic.load(ordering: .relaxed)
    }

    /// The assembled master clock snapshot (§30.1) — master sample, effective
    /// BPM and downbeat phase, published by the render thread each callback and
    /// read here once per callback by the control side.
    public var masterClock: MasterClock {
        MasterClock(masterSample: masterSample,
                    masterBPM: Double(graphState.masterBPMAromic.load(ordering: .relaxed)),
                    downbeatPhase: Double(graphState.downbeatPhaseAtomic.load(ordering: .relaxed)))
    }

    /// Post-limiter master-bus peak level (0…1) from the last callback.
    public var masterLevel: Float {
        graphState.masterLevelAtomic.load(ordering: .relaxed)
    }

    /// The most recently published playhead for a deck (0 = A, 1 = B).
    public func deckPlayhead(_ deck: UInt8) -> Int64 {
        switch deck {
        case 0: return graphState.playheadAtomicA.load(ordering: .relaxed)
        default: return graphState.playheadAtomicB.load(ordering: .relaxed)
        }
    }

    /// The most recently published playback rate for a deck (§32.1 — the sync
    /// path reads the authoritative render-side value back).
    public func deckRate(_ deck: UInt8) -> Float {
        switch deck {
        case 0: return graphState.rateAtomicA.load(ordering: .relaxed)
        default: return graphState.rateAtomicB.load(ordering: .relaxed)
        }
    }

    /// The most recently published post-chain peak level (0…1) for a deck.
    public func deckLevel(_ deck: UInt8) -> Float {
        switch deck {
        case 0: return graphState.levelAtomicA.load(ordering: .relaxed)
        default: return graphState.levelAtomicB.load(ordering: .relaxed)
        }
    }

    /// Whether a deck is currently rendering (published each callback).
    public func deckIsPlaying(_ deck: UInt8) -> Bool {
        switch deck {
        case 0: return graphState.playingAtomicA.load(ordering: .relaxed)
        default: return graphState.playingAtomicB.load(ordering: .relaxed)
        }
    }

    /// Whether beat sync is currently engaged for a deck (§32.1).
    public func deckIsSynced(_ deck: UInt8) -> Bool {
        switch deck {
        case 0: return graphState.syncedAtomicA.load(ordering: .relaxed)
        default: return graphState.syncedAtomicB.load(ordering: .relaxed)
        }
    }

    /// Render load as time-over-buffer-period (0…1) for the last callback
    /// (§34.3). The mockup's CPU% is this value scaled to 100.
    public var renderLoadRatio: Double {
        let periodNanos = UInt64((Double(maximumFrameCount) / sampleRate) * 1e9)
        return renderLoad.loadRatio(periodNanos: periodNanos)
    }

    /// Whether a master limiter ceiling is configured (the workspace's limiter
    /// indicator, §35.5).
    public var limiterCeiling: Float? {
        graphState.limiterCeiling
    }

    /// The buffer period in milliseconds (`maximumFrameCount` at `sampleRate`)
    /// — the workspace's "256 · 11.4 ms" readout, from the graph's granted
    /// buffer (§34.2).
    public var bufferPeriodMillis: Double {
        Double(maximumFrameCount) / sampleRate * 1000.0
    }

    /// Frames a playing deck rendered as silence because it had no source or
    /// ran past the end of its track (§46.2).
    public var starvedFrames: UInt64 {
        graphState.starvedAtomic.load(ordering: .relaxed)
    }

    private let engine: AVAudioEngine
    /// The graph's source node(s): one for the direct topology, two (one per
    /// deck) for the time-pitch topology. Retained so the render closures'
    /// captures stay alive.
    private let sourceNodes: [AVAudioSourceNode]
    /// The per-deck `AVAudioUnitTimePitch` units; empty in the direct topology.
    private let timePitchUnits: [TimePitchUnit]
    private let manualRenderingFormat: AVAudioFormat
    private let guardProbe: GuardActiveProbe
    private let graphState: RenderGraphState

    public init(configuration: Configuration = Configuration()) throws {
        let sampleRate = configuration.sampleRate
        channelCount = configuration.channelCount

        let engine = AVAudioEngine()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: configuration.sampleRate,
                                         channels: configuration.channelCount) else {
            throw AudioGraphError.failedToEnableManualRendering
        }
        try engine.enableManualRenderingMode(.offline, format: format,
                                             maximumFrameCount: configuration.maximumFrameCount)

        let ring = CommandRing(capacity: configuration.ringCapacity)
        let snap = EngineSnapshot()
        let load = RenderLoad()
        let probe = GuardActiveProbe()
        let graphState = RenderGraphState(sampleRate: sampleRate,
                                          channelCount: Int(channelCount),
                                          limiterCeiling: configuration.limiterCeiling,
                                          limiterLookaheadFrames: configuration.limiterLookaheadFrames)

        let sourceNodes: [AVAudioSourceNode]
        let timePitchUnits: [TimePitchUnit]

        if configuration.timePitch {
            // §31 pitch tier (§29.1 shape): per-deck `source → unit → main
            // mixer`. Each deck's source node renders only its deck through the
            // shared reader and sets its unit's key compensation from the
            // drained deck state. Both blocks drain the ring — the first drain
            // applies every command (deck-addressed dispatch, §12.2), the
            // second finds it empty — so command application is independent of
            // engine pull order. The master stage is not in this topology
            // (plan 4.5: the pitch tier; the master path is the direct
            // topology's). The master clock is advanced after each callback in
            // `render` rather than by a node, so both decks see the same
            // pre-advance `frameStart` within a callback.
            let unitA = TimePitchUnit()
            let unitB = TimePitchUnit()
            let sourceA = AVAudioSourceNode(format: format) { _, _, frameCount, outputData in
                RTGuard.withRenderContext {
                    let start = load.startTicks()
                    probe.flag.store(RTGuard.isInRenderContext, ordering: .relaxed)
                    let masterSample = graphState.clock.masterSample
                    let frames = Int(frameCount)
                    ring.drain { graphState.apply($0, masterSample: masterSample) }
                    graphState.applyContinuousSync()
                    graphState.applyTimePitch(unitA, deck: 0)
                    graphState.renderDeckIntoOutput(0,
                                                    into: UnsafeMutableAudioBufferListPointer(outputData),
                                                    frames: frames)
                    load.endTicks(start)
                }
                return 0
            }
            let sourceB = AVAudioSourceNode(format: format) { _, _, frameCount, outputData in
                RTGuard.withRenderContext {
                    let masterSample = graphState.clock.masterSample
                    let frames = Int(frameCount)
                    ring.drain { graphState.apply($0, masterSample: masterSample) }
                    graphState.applyContinuousSync()
                    graphState.applyTimePitch(unitB, deck: 1)
                    graphState.renderDeckIntoOutput(1,
                                                    into: UnsafeMutableAudioBufferListPointer(outputData),
                                                    frames: frames)
                }
                return 0
            }
            engine.attach(sourceA)
            engine.attach(sourceB)
            engine.attach(unitA.node)
            engine.attach(unitB.node)
            engine.connect(sourceA, to: unitA.node, format: format)
            engine.connect(sourceB, to: unitB.node, format: format)
            engine.connect(unitA.node, to: engine.mainMixerNode, format: format)
            engine.connect(unitB.node, to: engine.mainMixerNode, format: format)
            sourceNodes = [sourceA, sourceB]
            timePitchUnits = [unitA, unitB]
        } else {
            // Direct topology: one source node renders both decks, the master
            // stage and the clock advance (§29.1 simplified, plan 4.3/4.4).
            let sourceNode = AVAudioSourceNode(format: format) { _, _, frameCount, outputData in
                RTGuard.withRenderContext {
                    let start = load.startTicks()
                    probe.flag.store(RTGuard.isInRenderContext, ordering: .relaxed)
                    let masterSample = graphState.clock.masterSample
                    let frames = Int(frameCount)
                    ring.drain { graphState.apply($0, masterSample: masterSample) }
                    graphState.applyContinuousSync()
                    _ = snap.read() // acquire the current snapshot once per callback
                    graphState.renderDecks(into: UnsafeMutableAudioBufferListPointer(outputData),
                                           frames: frames)
                    load.endTicks(start)
                }
                return 0
            }
            engine.attach(sourceNode)
            engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
            sourceNodes = [sourceNode]
            timePitchUnits = []
        }

        self.sampleRate = sampleRate
        self.maximumFrameCount = configuration.maximumFrameCount
        self.engine = engine
        self.sourceNodes = sourceNodes
        self.timePitchUnits = timePitchUnits
        self.commandRing = ring
        self.snapshot = snap
        self.renderLoad = load
        self.guardProbe = probe
        self.graphState = graphState
        self.manualRenderingFormat = format
    }

    deinit {
        engine.stop()
    }

    /// Start the manual-rendering engine. Required before any `render`.
    public func start() throws {
        try engine.start()
    }

    public func stop() {
        engine.stop()
    }

    /// Render `frameCount` frames into a fresh buffer. The source node's render
    /// block runs synchronously inside this call (offline mode — no hardware).
    @discardableResult
    public func render(_ frameCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: manualRenderingFormat,
                                            frameCapacity: frameCount) else {
            throw AudioGraphError.failedToAllocateRenderBuffer
        }
        let status = try engine.renderOffline(frameCount, to: buffer)
        guard status == .success else {
            throw AudioGraphError.renderFailed(status: status)
        }
        if !timePitchUnits.isEmpty {
            // The time-pitch topology's clock is advanced here (off-RT but
            // synchronous — the offline pull completed above) so both decks'
            // source nodes read the same pre-advance `frameStart` in a
            // callback and the timeline advances exactly once per pull.
            graphState.clock.advance(by: Int64(frameCount))
            graphState.publishMasterClock()
            graphState.publishDeckTelemetry(0)
            graphState.publishDeckTelemetry(1)
        }
        return buffer
    }
}

/// The render-thread-private graph state (§12.2 "its private RT state"). Only
/// the render block mutates it; the control side changes it solely via commands
/// applied through `apply`, and reads it back only through the published atomics.
final class RenderGraphState: @unchecked Sendable {
    /// The master clock in absolute samples on the device timeline (§30.1).
    var clock: DeckClock
    let masterSampleAtomic = Atomic<Int64>(0)
    let masterBPMAromic = Atomic<Float>(0)
    let downbeatPhaseAtomic = Atomic<Float>(0)
    let starvedAtomic = Atomic<UInt64>(0)
    let playheadAtomicA = Atomic<Int64>(0)
    let playheadAtomicB = Atomic<Int64>(0)
    let rateAtomicA = Atomic<Float>(1)
    let rateAtomicB = Atomic<Float>(1)
    let levelAtomicA = Atomic<Float>(0)
    let levelAtomicB = Atomic<Float>(0)
    let playingAtomicA = Atomic<Bool>(false)
    let playingAtomicB = Atomic<Bool>(false)
    let syncedAtomicA = Atomic<Bool>(false)
    let syncedAtomicB = Atomic<Bool>(false)
    let masterLevelAtomic = Atomic<Float>(0)
    let limiterCeiling: Float?
    let decks: [DeckState]
    let master: MasterStage

    init(sampleRate: Double, channelCount: Int,
         limiterCeiling: Float?, limiterLookaheadFrames: Int) {
        clock = DeckClock(sampleRate: sampleRate)
        self.limiterCeiling = limiterCeiling
        decks = [DeckState(sampleRate: sampleRate, channelCount: channelCount),
                 DeckState(sampleRate: sampleRate, channelCount: channelCount)]
        master = MasterStage(channelCount: channelCount, sampleRate: sampleRate,
                             ceiling: limiterCeiling, lookaheadFrames: limiterLookaheadFrames)
    }

    /// Apply a drained command. The crossfader is global (master stage); every
    /// other command addresses a deck. A bad deck index is ignored at the
    /// boundary (§46.2).
    func apply(_ command: RTCommand, masterSample: Int64) {
        if command.tag == .setCrossfader {
            master.apply(command)
            return
        }
        let index = Int(command.deck)
        guard decks.indices.contains(index) else { return }
        decks[index].apply(command, masterSample: masterSample)
    }

    /// Render both decks into the output. The baseline is zeroed first, so a
    /// paused or unloaded deck contributes silence rather than garbage (§46.2);
    /// loaded, playing decks accumulate onto it through their EQ/filter/fader
    /// chains. The crossfader gains are applied per deck, then the master
    /// limiter shapes the summed bus (§35.5).
    func renderDecks(into list: UnsafeMutableAudioBufferListPointer, frames: Int) {
        let frameStart = clock.masterSample
        for m in list {
            guard let data = m.mData else { continue }
            memset(data, 0, frames * MemoryLayout<Float>.size)
        }
        let (gainA, gainB) = master.gains()
        decks[0].setCrossfaderGain(gainA)
        decks[1].setCrossfaderGain(gainB)
        for deck in decks {
            renderDeck(deck, into: list, frames: frames, frameStart: frameStart)
        }
        master.limit(into: list, frames: frames)
        publishMasterLevel(into: list, frames: frames)
        clock.advance(by: Int64(frames))
        publishMasterClock()
        publishDeckTelemetry(0)
        publishDeckTelemetry(1)
    }

    /// Publish the master clock snapshot — master sample, effective BPM and
    /// downbeat phase — from the master deck (deck A, §30.1). The direct
    /// topology calls this from the render block; the time-pitch topology from
    /// `render`.
    func publishMasterClock() {
        masterSampleAtomic.store(clock.masterSample, ordering: .relaxed)
        guard !decks.isEmpty else {
            masterBPMAromic.store(0, ordering: .relaxed)
            downbeatPhaseAtomic.store(0, ordering: .relaxed)
            return
        }
        let master = decks[0]
        guard let masterSource = master.source() else {
            masterBPMAromic.store(0, ordering: .relaxed)
            downbeatPhaseAtomic.store(0, ordering: .relaxed)
            return
        }
        masterBPMAromic.store(Float(masterSource.grid.bpm * master.rate), ordering: .relaxed)
        downbeatPhaseAtomic.store(Float(masterSource.grid.barPhase(at: master.playhead)),
                                  ordering: .relaxed)
    }

    /// Publish the post-limiter master-bus peak level (0…1).
    func publishMasterLevel(into list: UnsafeMutableAudioBufferListPointer, frames: Int) {
        var peak: Float = 0
        for m in list {
            guard let data = m.mData else { continue }
            let p = data.assumingMemoryBound(to: Float.self)
            for i in 0..<frames {
                let magnitude = abs(p[i])
                if magnitude > peak { peak = magnitude }
            }
        }
        masterLevelAtomic.store(peak, ordering: .relaxed)
    }

    /// Continuous rate tracking (§32.1): while a deck is synced to the master,
    /// its rate is re-derived every callback so its effective BPM stays equal
    /// to the master's — a master pitch change moves the synced deck with it.
    /// Called right after the ring drain, before any deck renders.
    func applyContinuousSync() {
        guard decks.count == 2 else { return }
        for deck in decks where deck.syncedToMaster >= 0 {
            let masterIndex = deck.syncedToMaster
            guard decks.indices.contains(masterIndex),
                  let masterSource = decks[masterIndex].source(),
                  let syncedSource = deck.source() else { continue }
            deck.rate = SyncEngine.continuousRate(masterRate: decks[masterIndex].rate,
                                                  masterBPM: masterSource.grid.bpm,
                                                  syncedBPM: syncedSource.grid.bpm)
        }
    }

    /// Publish a deck's playhead/rate/level/play/sync state through its relaxed
    /// atomics (§30.1).
    func publishDeckTelemetry(_ deck: Int) {
        guard decks.indices.contains(deck) else { return }
        let d = decks[deck]
        switch deck {
        case 0:
            playheadAtomicA.store(Int64(d.playhead), ordering: .relaxed)
            rateAtomicA.store(Float(d.rate), ordering: .relaxed)
            levelAtomicA.store(d.peak, ordering: .relaxed)
            playingAtomicA.store(d.playing, ordering: .relaxed)
            syncedAtomicA.store(d.syncedToMaster >= 0, ordering: .relaxed)
        default:
            playheadAtomicB.store(Int64(d.playhead), ordering: .relaxed)
            rateAtomicB.store(Float(d.rate), ordering: .relaxed)
            levelAtomicB.store(d.peak, ordering: .relaxed)
            playingAtomicB.store(d.playing, ordering: .relaxed)
            syncedAtomicB.store(d.syncedToMaster >= 0, ordering: .relaxed)
        }
    }

    /// Render one deck into an output that feeds its time-pitch unit (the
    /// §31 pitch tier's per-deck chain). Zeroes the buffer first so an
    /// unloaded or paused deck renders silence, not garbage (§46.2), then
    /// publishes the deck's playhead.
    func renderDeckIntoOutput(_ deck: Int,
                              into list: UnsafeMutableAudioBufferListPointer,
                              frames: Int) {
        guard decks.indices.contains(deck) else { return }
        for m in list {
            guard let data = m.mData else { continue }
            memset(data, 0, frames * MemoryLayout<Float>.size)
        }
        renderDeck(decks[deck], into: list, frames: frames,
                   frameStart: clock.masterSample)
        publishDeckTelemetry(deck)
    }

    /// Set a deck's time-pitch unit from its drained tempo/key state (§31).
    /// Called every callback so a `setRate`/`setKeyLock`/`setKeyShift` command
    /// is reflected in the unit's pitch at the same boundary the reader starts
    /// using it. The unit's `apply` is the RT-safe AU-parameter path and
    /// skips the set when nothing changed.
    func applyTimePitch(_ unit: TimePitchUnit, deck: Int) {
        guard decks.indices.contains(deck) else { return }
        let state = decks[deck]
        unit.apply(TimePitchSettings(rate: state.rate,
                                     keyLock: state.keyLock,
                                     keyShiftSemitones: state.keyShift))
    }

    /// Render one deck's output for the callback, splitting the buffer at the
    /// exact frame for scheduled cue jumps and loop boundaries (§30.2).
    private func renderDeck(_ deck: DeckState, into list: UnsafeMutableAudioBufferListPointer,
                            frames: Int, frameStart: Int64) {
        deck.peak = 0
        guard deck.playing else { return } // paused: silence, playhead frozen
        guard let source = deck.source() else {
            deck.starved = true
            starvedAtomic.add(UInt64(frames), ordering: .relaxed)
            return
        }

        var f = 0
        while f < frames {
            // Next sample-accurate boundary within this callback (§30.2).
            var boundary = frames

            // A scheduled cue/seek jump fires at its absolute master sample.
            if let jump = deck.pendingJump {
                let fireOffset = Int(jump.atSample - frameStart)
                if fireOffset <= f {
                    // Already at/past the fire frame — apply now and split here.
                    deck.playhead = Double(jump.targetSample)
                    deck.pendingJump = nil
                    continue
                }
                boundary = min(boundary, fireOffset)
            }

            // The loop's half-open [start, end) end boundary (§33.2).
            if deck.loopActive && deck.playhead < Double(deck.loopEnd) {
                let framesToEnd = (Double(deck.loopEnd) - deck.playhead) / deck.rate
                boundary = min(boundary, f + max(1, Int(framesToEnd.rounded(.up))))
            }

            let count = boundary - f
            readChunk(deck, source, into: list, at: f, count: count)
            f = boundary
            deck.playhead += Double(count) * deck.rate

            if deck.loopActive && CueLoop.reachedEnd(deck.playhead, loopEnd: deck.loopEnd) {
                deck.playhead = CueLoop.wrap(deck.playhead, loopStart: deck.loopStart,
                                             loopEnd: deck.loopEnd)
            }
        }

        if Int64(deck.playhead) >= source.frameCount {
            deck.starved = true
            starvedAtomic.add(UInt64(frames), ordering: .relaxed)
        }
    }

    /// Copy `source[playhead ..< playhead+count)` into the output at `frame`,
    /// clamped at the end of the track — frames past EOF render silence, never
    /// an out-of-bounds read (§46.2). Each sample runs through the deck's
    /// EQ/filter/fader/crossfader chain (§35.1). Accumulates (`+=`) so both
    /// decks sum.
    private func readChunk(_ deck: DeckState, _ source: DeckSource,
                           into list: UnsafeMutableAudioBufferListPointer,
                           at frame: Int, count: Int) {
        guard count > 0 else { return }
        let start = deck.playhead
        let rate = deck.rate
        let base = source.pcm.assumingMemoryBound(to: Float.self)
        let srcChannels = source.channelCount
        for c in 0..<Int(list.count) {
            guard let mData = list[c].mData else { continue }
            let out = mData.assumingMemoryBound(to: Float.self)
            let srcChannel = srcChannels == 1 ? 0 : min(c, srcChannels - 1)
            for i in 0..<count {
                let track = Int64(start + Double(i) * rate)
                if track >= 0 && track < source.frameCount {
                    let raw = base[Int(track) * srcChannels + srcChannel]
                    let processed = deck.mixers[c].process(raw)
                    out[frame + i] += processed
                    let magnitude = abs(processed)
                    if magnitude > deck.peak { deck.peak = magnitude }
                }
            }
        }
    }
}

/// The render-thread-private deck state (§12.2). Only the render block mutates
/// it; the control side changes it solely via `apply`.
final class DeckState: @unchecked Sendable {

    struct PendingJump {
        /// Absolute master-timeline sample at which the jump fires (§30.2).
        var atSample: Int64
        /// Track sample the playhead moves to when it fires.
        var targetSample: Int64
    }

    /// Ownership-transfer marker for the armed `DeckSource` (control side keeps
    /// the boxed allocation alive; §12.2).
    var sourcePointer: UnsafeRawPointer?
    var playing = false
    var playhead: Double = 0
    var rate: Double = 1
    /// Key lock on — pitch held constant under tempo changes (§31.2).
    var keyLock = false
    /// Independent musical key shift in semitones, rate held (§31.3).
    var keyShift: Double = 0
    var loopStart: Int64 = 0
    var loopEnd: Int64 = 0
    var loopActive = false
    var quantizeOn = false
    var quantizeResolution: QuantizeResolution = .beat
    var cue = TempCueState()
    var pendingJump: PendingJump?
    var starved = false
    /// Master deck index while beat sync is engaged, −1 when not (§32.1). The
    /// render thread re-derives the rate each callback (continuous tracking).
    var syncedToMaster: Int = -1
    /// Post-chain peak level (0…1) for the current callback's telemetry.
    var peak: Float = 0
    /// The per-channel EQ/filter/fader/crossfader chain (§35.1). Only the
    /// render thread mutates it.
    var mixers: [DeckMixer]
    private let sampleRate: Double

    init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        mixers = (0..<channelCount).map { _ in DeckMixer(sampleRate: sampleRate) }
    }

    /// Read the armed source without retaining anything (§12.3).
    func source() -> DeckSource? {
        guard let pointer = sourcePointer else { return nil }
        return pointer.load(as: DeckSource.self)
    }

    /// The deck's beat grid; falls back to a nominal grid before any source is
    /// loaded so quantize math stays well-defined.
    private func grid() -> DeckGrid {
        source()?.grid ?? DeckGrid(sampleRate: sampleRate)
    }

    func apply(_ command: RTCommand, masterSample: Int64) {
        switch command.tag {
        case .play:
            playing = true
        case .pause:
            playing = false
        case .setRate:
            rate = Double(command.f0)
        case .loadArm:
            sourcePointer = command.ptr
        case .seek:
            let target = command.f0 >= 0.5
                ? Scheduler.quantizedBoundary(after: command.i0,
                                              resolution: quantizeResolution, grid: grid())
                : command.i0
            pendingJump = PendingJump(atSample: masterSample, targetSample: target)
        case .setCue:
            cue.setPoint(command.i0)
        case .cuePress:
            if cue.press(at: Int64(playhead)) {
                playhead = Double(cue.pointSample)
                playing = true
            }
        case .cueRelease:
            if let restore = cue.release() {
                playhead = Double(restore)
                playing = false
            }
        case .triggerHotCue:
            let at = Scheduler.triggerFrame(playhead: Int64(playhead), masterSample: masterSample,
                                            targetSample: command.i0, quantized: quantizeOn,
                                            resolution: quantizeResolution, grid: grid(), rate: rate)
            pendingJump = PendingJump(atSample: at, targetSample: command.i0)
        case .setLoop:
            loopStart = command.i0
            loopEnd = command.i1
            loopActive = true
        case .exitLoop:
            loopActive = false
        case .setQuantize:
            quantizeOn = command.f0 >= 0.5
            if let resolution = QuantizeResolution(rawValue: UInt8(command.f1)) {
                quantizeResolution = resolution
            }
        case .setKeyLock:
            keyLock = command.f0 >= 0.5
        case .setKeyShift:
            keyShift = Double(command.f0)
        case .setEQ:
            for c in mixers.indices {
                mixers[c].eqEngaged = true
                mixers[c].eq.setGains(low: command.f0, mid: command.f1, high: command.f2)
            }
        case .setFilter:
            for c in mixers.indices { mixers[c].filter.setKnob(command.f0) }
        case .setFader:
            for c in mixers.indices { mixers[c].fader.target = command.f0 }
        case .setCrossfader:
            break // global — handled by the master stage
        case .sync:
            syncedToMaster = Int(command.f0)
        case .unsync:
            syncedToMaster = -1
        case .syncNudge:
            // Phase-align: a scheduled, sample-accurate jump to the current
            // playhead plus the signed shift — fires at this callback's frame 0
            // (§32.1).
            pendingJump = PendingJump(atSample: masterSample,
                                      targetSample: Int64(playhead) + command.i0)
        }
    }

    /// Set the per-channel crossfader gain target (applied each callback from
    /// the master stage's current position).
    func setCrossfaderGain(_ gain: Float) {
        for c in mixers.indices { mixers[c].crossfaderGain.target = gain }
    }
}

/// Reference box so the render block and the graph share one atomic (a captured
/// struct `Atomic` copy would otherwise be ambiguous under copy/move semantics).
private final class GuardActiveProbe: @unchecked Sendable {
    let flag = Atomic<Bool>(false)
}
