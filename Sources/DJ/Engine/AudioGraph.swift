import AVFoundation
import Foundation
import Synchronization

public enum AudioGraphError: Error, Equatable {
    case failedToEnableManualRendering
    case failedToAllocateRenderBuffer
    case renderFailed(status: AVAudioEngineManualRenderingStatus)
    /// `render(_:)` was called on a graph in `.realtime` mode — the offline
    /// pull is meaningless when the device output owns the callback.
    case renderingUnavailableInRealtimeMode
}

/// How the graph's render closures are driven (§53.11, commit 5.4a).
///
/// The closures themselves are shared — one render-closure body, two drivers —
/// so the realtime path cannot grow its own copy of the deck reader. The mode
/// only changes *who pulls*: the manual `render(_:)` pull (deterministic,
/// test-only) or the device output.
public enum AudioGraphRenderingMode: Sendable, Equatable {
    /// Manual-rendering mode: the graph is pulled by `render(_:)` calls. The
    /// offline harness's mode — today's behaviour, unchanged, still the test
    /// default (§53.11).
    case offline
    /// Device-output mode: the graph is driven by CoreAudio's real-time pull;
    /// `start()` connects the source nodes through the main mixer to the
    /// output node and the render closures run on the audio thread.
    case realtime
}

/// The `AVAudioEngine` graph (plan §2.5, commit 4.1; §29 from 4.3; the
/// `.realtime` driver from 5.4a).
///
/// The graph hosts two decks, each backed by a `DeckState` (the deck reader):
/// a pre-decoded PCM source is armed via `loadArm`, and the render block walks
/// the output buffer splitting it at sample-accurate loop and cue boundaries
/// (§30.2), exactly as the §30.2 pseudocode specifies. Control never touches
/// render state directly — only `RTCommand`s cross the boundary (§12.2).
///
/// In `.offline` mode the engine runs manual rendering, so the harness is fully
/// deterministic on the `swift test` macOS host — no hardware (§47.2 "engine
/// integration, deterministic" tier). In `.realtime` mode the same render
/// closures run on the device output's audio thread (§53.11).
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
        /// How the render closures are driven (§53.11, commit 5.4a): `.offline`
        /// is the manual-rendering harness's mode (unchanged, the test default);
        /// `.realtime` runs the same closures on the device output.
        public var rendering: AudioGraphRenderingMode
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
        /// Whether to construct the §37.2 record tap (plan 5.10, FR-ENG-7).
        ///
        /// Default `false`: the frame-exact reader harness never constructs a
        /// tap at all, so it stays bit-exact. When `true` the graph allocates a
        /// `RecordTap` and the render closures copy the **post-limiter** master
        /// output into it — the tap is read-only on the signal and idle unless
        /// recording (`RecordTap.setRecording`), so even an enabled tap never
        /// changes what the reader produces.
        public var recordTapEnabled: Bool
        /// The record tap's ring capacity in frames (plan 5.10: sized to absorb
        /// encoder scheduling jitter — a slow drain costs recording, never the
        /// live performance). Ignored when `recordTapEnabled` is false.
        public var recordTapCapacityFrames: Int

        public init(sampleRate: Double = 48_000,
                    channelCount: AVAudioChannelCount = 1,
                    maximumFrameCount: AVAudioFrameCount = 4096,
                    ringCapacity: Int = 8,
                    rendering: AudioGraphRenderingMode = .offline,
                    limiterCeiling: Float? = nil,
                    limiterLookaheadFrames: Int = 0,
                    timePitch: Bool = false,
                    recordTapEnabled: Bool = false,
                    recordTapCapacityFrames: Int = 96_000) {
            self.sampleRate = sampleRate
            self.channelCount = channelCount
            self.maximumFrameCount = maximumFrameCount
            self.ringCapacity = ringCapacity
            self.rendering = rendering
            self.limiterCeiling = limiterCeiling
            self.limiterLookaheadFrames = limiterLookaheadFrames
            self.timePitch = timePitch
            self.recordTapEnabled = recordTapEnabled
            self.recordTapCapacityFrames = recordTapCapacityFrames
        }
    }

    public let sampleRate: Double
    public let channelCount: AVAudioChannelCount
    /// The manual-rendering maximum frame count per callback (§34.1).
    public let maximumFrameCount: AVAudioFrameCount
    /// The §37.2 record tap — the post-limiter master-bus copy the render
    /// closures write into (plan 5.10). `nil` when `recordTapEnabled` is false
    /// (the frame-exact reader harness); the encoder drains this ring off-RT.
    public let recordTap: RecordTap?
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
    /// The driver mode this graph was constructed for (§53.11).
    private let renderingMode: AudioGraphRenderingMode

    public init(configuration: Configuration = Configuration()) throws {
        let sampleRate = configuration.sampleRate
        channelCount = configuration.channelCount

        let engine = AVAudioEngine()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: configuration.sampleRate,
                                         channels: configuration.channelCount) else {
            throw AudioGraphError.failedToEnableManualRendering
        }
        if configuration.rendering == .offline {
            // The deterministic harness's mode: the graph is pulled by
            // `render(_:)`. `.realtime` skips manual rendering and is driven by
            // the device output instead (§53.11).
            try engine.enableManualRenderingMode(.offline, format: format,
                                                 maximumFrameCount: configuration.maximumFrameCount)
        }

        let ring = CommandRing(capacity: configuration.ringCapacity)
        let snap = EngineSnapshot()
        let load = RenderLoad()
        let probe = GuardActiveProbe()
        let recordTap: RecordTap? = configuration.recordTapEnabled
            ? RecordTap(sampleRate: sampleRate, channelCount: Int(channelCount),
                        capacityFrames: configuration.recordTapCapacityFrames)
            : nil
        let graphState = RenderGraphState(sampleRate: sampleRate,
                                          channelCount: Int(channelCount),
                                          limiterCeiling: configuration.limiterCeiling,
                                          limiterLookaheadFrames: configuration.limiterLookaheadFrames,
                                          echoCapacity: BeatEcho.maxDelayFrames(sampleRate: sampleRate) + 1,
                                          echoCrossfadeFrames: Int(configuration.maximumFrameCount),
                                          recordTap: recordTap)
        // Captured by the render closures so they can stay one body across the
        // two drivers (§53.11) — the realtime driver needs the clock advanced
        // inside the callback, the offline driver advances it in `render`.
        let renderingMode = configuration.rendering

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
                    if renderingMode == .realtime {
                        // Real-time driver: the deck-B source node is pulled
                        // last per callback (the main mixer pulls its input
                        // buses in order), so it advances the master clock once
                        // per callback after both decks have read the same
                        // pre-advance `frameStart`. The offline driver keeps
                        // today's advance in `render(_:)`.
                        graphState.clock.advance(by: Int64(frames))
                        graphState.publishMasterClock()
                        graphState.publishDeckTelemetry(0)
                        graphState.publishDeckTelemetry(1)
                    }
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

        if configuration.rendering == .realtime {
            // The real-time driver: the source nodes already feed the main
            // mixer; route the mixer's output to the hardware output node so
            // `start()` pulls the graph on the audio thread. The `nil` format
            // lets AVAudioEngine insert the converter to the hardware rate.
            // Never done in `.offline` mode — manual rendering has no output
            // node in the path.
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        }

        self.sampleRate = sampleRate
        self.maximumFrameCount = configuration.maximumFrameCount
        self.engine = engine
        self.sourceNodes = sourceNodes
        self.timePitchUnits = timePitchUnits
        self.recordTap = recordTap
        self.commandRing = ring
        self.snapshot = snap
        self.renderLoad = load
        self.guardProbe = probe
        self.graphState = graphState
        self.renderingMode = renderingMode
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

    /// An observer registration on its way to `removeObserver`.
    ///
    /// `NotificationCenter`'s token is `any NSObjectProtocol`, which Swift 6
    /// will not let cross into the stream's `@Sendable` termination handler. The
    /// box is not a waiver: the token is created once, never read, never
    /// mutated, and used for exactly one call — there is no shared state here to
    /// race on.
    private final class ObserverToken: @unchecked Sendable {
        let value: any NSObjectProtocol
        init(_ value: any NSObjectProtocol) { self.value = value }
    }

    /// Whether `AVAudioEngine` believes it is running.
    ///
    /// Necessary but **not sufficient** as a liveness signal: it reports whether
    /// the engine was told to run, not whether the hardware is pulling the
    /// render callback. `EngineLivenessMonitor` is what closes that gap.
    public var isRunning: Bool {
        engine.isRunning
    }

    /// Restart a stopped realtime graph in place (§34A.5's restart, short of a
    /// full topology rebuild — the node graph is unchanged, so this is the
    /// cheap half). Idempotent: starting a running engine is a no-op rather
    /// than an error, so a coalesced double recovery cannot throw.
    public func restart() throws {
        guard renderingMode == .realtime else {
            throw AudioGraphError.renderingUnavailableInRealtimeMode
        }
        if engine.isRunning { return }
        // `prepare()` re-allocates the render resources the stop released. On a
        // media-services reset the engine object is stale and `start()` throws —
        // which is the honest outcome, surfaced rather than swallowed.
        engine.prepare()
        try engine.start()
    }

    /// `AVAudioEngineConfigurationChange` for **this** engine — the fast path in
    /// `EngineLivenessMonitor`'s hierarchy, and the only signal that names a
    /// reason. AVAudioEngine posts it after it has already stopped itself, so a
    /// receiver's job is to recover, not to prevent.
    ///
    /// The observation is handed out as a stream rather than a callback so the
    /// consumer (`WorkspaceModel`) marshals it the same way it already marshals
    /// session responses (§34A.4) — one idiom for "the system interrupted us".
    public func configurationChanges() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let token = ObserverToken(NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { _ in
                continuation.yield(())
            })
            continuation.onTermination = { _ in
                NotificationCenter.default.removeObserver(token.value)
            }
        }
    }

    /// Render `frameCount` frames into a fresh buffer. The source node's render
    /// block runs synchronously inside this call (offline mode — no hardware).
    /// Only meaningful in `.offline` mode.
    @discardableResult
    public func render(_ frameCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard renderingMode == .offline else {
            throw AudioGraphError.renderingUnavailableInRealtimeMode
        }
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
    /// The §37.2 record tap (plan 5.10): the render closures copy the
    /// **post-limiter** master output into this ring when recording. `nil`
    /// when `recordTapEnabled` is false — the frame-exact reader harness.
    let recordTap: RecordTap?

    init(sampleRate: Double, channelCount: Int,
         limiterCeiling: Float?, limiterLookaheadFrames: Int,
         echoCapacity: Int, echoCrossfadeFrames: Int,
         recordTap: RecordTap?) {
        clock = DeckClock(sampleRate: sampleRate)
        self.limiterCeiling = limiterCeiling
        self.recordTap = recordTap
        decks = [DeckState(sampleRate: sampleRate, channelCount: channelCount,
                           echoCapacity: echoCapacity,
                           echoCrossfadeFrames: echoCrossfadeFrames),
                 DeckState(sampleRate: sampleRate, channelCount: channelCount,
                           echoCapacity: echoCapacity,
                           echoCrossfadeFrames: echoCrossfadeFrames)]
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
        // §35A.2: the echo delay is derived from the master clock, so it is
        // retuned once per callback from the master deck's effective tempo —
        // a tempo change moves the echo with it, crossfading between read
        // pointers over one buffer rather than jumping.
        let masterBPM = effectiveMasterBPM()
        for deck in decks {
            deck.applyEchoMasterBPM(masterBPM)
            renderDeck(deck, into: list, frames: frames, frameStart: frameStart)
        }
        master.limit(into: list, frames: frames)
        // §37.2 (plan 5.10): the post-limiter master bus is what the audience
        // hears AND what the recording captures. Copy it into the record tap
        // (idle unless recording — a no-op otherwise, so the reader harness
        // stays bit-exact). The tap is read-only on the signal.
        recordTap?.write(into: list, frames: frames)
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
        guard let masterGrid = master.referenceGrid() else {
            masterBPMAromic.store(0, ordering: .relaxed)
            downbeatPhaseAtomic.store(0, ordering: .relaxed)
            return
        }
        masterBPMAromic.store(Float(masterGrid.bpm * master.rate), ordering: .relaxed)
        downbeatPhaseAtomic.store(Float(masterGrid.barPhase(at: master.playhead)),
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
                  let masterGrid = decks[masterIndex].referenceGrid(),
                  let syncedGrid = deck.referenceGrid() else { continue }
            deck.rate = SyncEngine.continuousRate(masterRate: decks[masterIndex].rate,
                                                  masterBPM: masterGrid.bpm,
                                                  syncedBPM: syncedGrid.bpm)
        }
    }

    /// The master clock's effective tempo — the master deck's grid BPM × rate
    /// (deck A is the master, §30.1), falling back to the nominal tempo before
    /// any deck is loaded so the echo delay stays well-defined (§35A.2). The
    /// grid is the armed source's or the armed stem set's — both are the same
    /// track in the same sample space (§35.1).
    func effectiveMasterBPM() -> Double {
        guard let masterGrid = decks[0].referenceGrid() else { return BeatEcho.nominalBPM }
        let bpm = masterGrid.bpm * decks[0].rate
        return bpm > 0 ? bpm : BeatEcho.nominalBPM
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
        // §35A.2: the per-callback echo retune from the master deck's tempo
        // (the master clock is the delay reference for both decks — a synced
        // pair echoes in time with both).
        decks[deck].applyEchoMasterBPM(effectiveMasterBPM())
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
        guard let reference = deck.referenceSource() else {
            deck.starved = true
            starvedAtomic.add(UInt64(frames), ordering: .relaxed)
            return
        }
        // The armed stem set, when present: the reader sums the four voices at
        // the shared playhead instead of reading the single full-mix source
        // (§35.1, plan decision 3). A deck with no stem set is byte-for-byte
        // the current reader.
        let stems = deck.stemSet()

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
            if let stems {
                readStemChunk(deck, stems, into: list, at: f, count: count)
            } else {
                readChunk(deck, reference, into: list, at: f, count: count)
            }
            f = boundary
            deck.playhead += Double(count) * deck.rate

            if deck.loopActive && CueLoop.reachedEnd(deck.playhead, loopEnd: deck.loopEnd) {
                deck.playhead = CueLoop.wrap(deck.playhead, loopStart: deck.loopStart,
                                             loopEnd: deck.loopEnd)
            }
        }

        if Int64(deck.playhead) >= reference.frameCount {
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

    /// Sum the armed `StemSet`'s four voices at the shared playhead into the
    /// output at `frame`, then run each channel's EQ/filter/fader/crossfader
    /// chain **once** over the summed voice (§35.1). Per-voice gains are
    /// smoothed one-pole ramps that fold in mute/solo and advance once per
    /// sample (shared across channels, so L/R stay coherent). Frames past a
    /// voice's EOF render silence for that voice, never an out-of-bounds read
    /// (§46.2). Accumulates (`+=`) so both decks sum.
    ///
    /// The render thread must not allocate (§12.3): the per-channel sum lands
    /// in the deck's pre-allocated `stemScratch`, and `StemKind.allCases` is a
    /// static buffer — no arrays are built here.
    private func readStemChunk(_ deck: DeckState, _ stems: StemSet,
                               into list: UnsafeMutableAudioBufferListPointer,
                               at frame: Int, count: Int) {
        guard count > 0 else { return }
        let start = deck.playhead
        let rate = deck.rate
        let outputChannels = Int(list.count)
        for i in 0..<count {
            let track = Int64(start + Double(i) * rate)
            guard track >= 0 else { continue }
            for c in 0..<outputChannels { deck.stemScratch[c] = 0 }
            var anyVoice = false
            for kind in StemKind.allCases {
                let voice = stems.source(kind)
                let gain = deck.stemGainNext(kind)
                guard gain > 0, track < voice.frameCount else { continue }
                let base = voice.pcm.assumingMemoryBound(to: Float.self)
                let srcChannels = voice.channelCount
                for c in 0..<outputChannels {
                    guard list[c].mData != nil else { continue }
                    let srcChannel = srcChannels == 1 ? 0 : min(c, srcChannels - 1)
                    deck.stemScratch[c] += base[Int(track) * srcChannels + srcChannel] * gain
                }
                anyVoice = true
            }
            guard anyVoice else { continue }
            for c in 0..<outputChannels {
                guard let mData = list[c].mData else { continue }
                let out = mData.assumingMemoryBound(to: Float.self)
                let processed = deck.mixers[c].process(deck.stemScratch[c])
                out[frame + i] += processed
                let magnitude = abs(processed)
                if magnitude > deck.peak { deck.peak = magnitude }
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
    /// Ownership-transfer marker for the armed `StemSet` (nil = none — the
    /// deck reads the single full-mix source, byte-for-byte; §35.1, plan
    /// decision 3). The control side keeps the boxed allocation alive.
    var stemSetPointer: UnsafeRawPointer?
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
    /// The §35A post-fader echo's control value — the per-deck target pushed
    /// into every channel's line by the `setEcho*` commands (§35A.3).
    var echo = BeatEcho()
    /// The per-channel EQ/filter/fader/echo/crossfader chain (§35.1). Only the
    /// render thread mutates it.
    var mixers: [DeckMixer]
    /// The per-voice smoothed gain targets, indexed by `StemKind.index`
    /// (§35.1). One ramp per voice — the four voices share the ramp across
    /// channels, so a gain move applies to both L and R. Starts at unity.
    var stemGains: [SmoothedGain]
    /// Per-voice mute state, indexed by `StemKind.index`.
    var stemMuted = [Bool](repeating: false, count: StemKind.allCases.count)
    /// Per-voice solo state, indexed by `StemKind.index`. When any voice is
    /// soloed, only soloed voices sound.
    var stemSoloed = [Bool](repeating: false, count: StemKind.allCases.count)
    /// A fixed-size scratch for the stem-summing pass — pre-allocated so the
    /// render thread never allocates (§12.3). One Float per output channel.
    var stemScratch: [Float]
    private let sampleRate: Double

    init(sampleRate: Double, channelCount: Int,
         echoCapacity: Int, echoCrossfadeFrames: Int) {
        self.sampleRate = sampleRate
        mixers = (0..<channelCount).map { _ in
            DeckMixer(sampleRate: sampleRate, echoCapacity: echoCapacity,
                      echoCrossfadeFrames: echoCrossfadeFrames)
        }
        stemGains = StemKind.allCases.map { _ in SmoothedGain(sampleRate: sampleRate) }
        stemScratch = [Float](repeating: 0, count: channelCount)
    }

    /// Read the armed source without retaining anything (§12.3).
    func source() -> DeckSource? {
        guard let pointer = sourcePointer else { return nil }
        return pointer.load(as: DeckSource.self)
    }

    /// Read the armed `StemSet` without retaining anything, or nil when no set
    /// is armed (§35.1).
    func stemSet() -> StemSet? {
        guard let pointer = stemSetPointer else { return nil }
        return pointer.load(as: StemSet.self)
    }

    /// The deck's reference source for the reader: the armed full-mix source,
    /// or the stem set's first voice when only stems are armed (they are the
    /// same track in the same sample space). Used for the playhead/loop
    /// boundary math and the end-of-track guard — never for audio bytes.
    func referenceSource() -> DeckSource? {
        source() ?? stemSet()?.vocals
    }

    /// The deck's authoritative grid — the armed full-mix source's, else the
    /// armed stem set's (all voices share the track grid), else nil. The grid
    /// surface the master clock, sync and echo read (§30.1, §32.1, §35A.2);
    /// nil means no source at all.
    func referenceGrid() -> DeckGrid? {
        source()?.grid ?? stemSet()?.grid
    }

    /// The deck's beat grid; falls back to a nominal grid before any source is
    /// loaded so quantize math stays well-defined. A stem set's grid is the
    /// deck's grid (all voices are the same track in the same sample space).
    private func grid() -> DeckGrid {
        referenceGrid() ?? DeckGrid(sampleRate: sampleRate)
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
        case .setEchoEnabled:
            echo.enabled = command.f0 >= 0.5
            applyEchoParams()
        case .setEchoBeats:
            echo.beats = Double(command.f0)
            applyEchoParams()
        case .setEchoDepth:
            echo.depth = command.f0
            applyEchoParams()
        case .setEchoFeedback:
            echo.feedback = command.f0
            applyEchoParams()
        case .armStemSet:
            stemSetPointer = command.ptr
        case .setStemGain:
            stemGains[StemKind(index: Int(command.i0)).index].target = command.f0
        case .setStemMute:
            stemMuted[StemKind(index: Int(command.i0)).index] = command.f0 >= 0.5
        case .setStemSolo:
            stemSoloed[StemKind(index: Int(command.i0)).index] = command.f0 >= 0.5
        }
    }

    /// Push the deck's echo control value into every channel's line (clamped
    /// by the line's `setParams`). The delay itself is retuned each callback
    /// from the master clock by `applyEchoMasterBPM` (§35A.2).
    private func applyEchoParams() {
        for c in mixers.indices { mixers[c].echo.setParams(echo) }
    }

    /// Whether any stem voice is soloed — when one is, only soloed voices
    /// sound (§35.1, the mockup's swap idiom).
    var anyStemSolo: Bool {
        stemSoloed.contains(true)
    }

    /// Advance one voice's smoothed gain one sample and return the current
    /// gain. The effective target folds in mute and solo: a muted voice ramps
    /// to 0; when any voice is soloed, only soloed voices sound at their gain
    /// and the rest sit at 0. Called once per sample per voice — never
    /// per-channel — so the ramp is shared across L/R (§35.1).
    func stemGainNext(_ kind: StemKind) -> Float {
        let i = kind.index
        let target: Float
        if anyStemSolo {
            target = stemSoloed[i] ? stemGains[i].target : 0
        } else {
            target = stemMuted[i] ? 0 : stemGains[i].target
        }
        stemGains[i].target = target
        return stemGains[i].next()
    }

    /// Retune every channel's echo delay from the master tempo — called once
    /// per callback. A tempo change moves the echo with it; the line
    /// crossfades between read pointers over one buffer rather than jumping
    /// (§35A.2).
    func applyEchoMasterBPM(_ bpm: Double) {
        let frames = BeatEcho.delayFrames(beats: echo.beats, bpm: bpm,
                                          sampleRate: sampleRate)
        for c in mixers.indices { mixers[c].echo.setDelayFrames(frames) }
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
