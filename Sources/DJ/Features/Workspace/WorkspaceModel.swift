import Combine
import CoreGraphics
import Foundation
import TonearmCore

/// The control/telemetry seam the session view model talks to. `PerformanceEngine`
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
    func deckRate(_ deck: PerformanceEngine.Deck) -> Double
    func start() throws
    func stop()
    func load(_ deck: PerformanceEngine.Deck, source: DeckSource)
    func play(_ deck: PerformanceEngine.Deck)
    func pause(_ deck: PerformanceEngine.Deck)
    func cue(_ deck: PerformanceEngine.Deck)
    func releaseCue(_ deck: PerformanceEngine.Deck)
    func seek(_ deck: PerformanceEngine.Deck, toSample: Int64, quantized: Bool)
    func setCue(_ deck: PerformanceEngine.Deck, atSample: Int64)
    func triggerHotCue(_ deck: PerformanceEngine.Deck, atSample: Int64)
    func setLoopRange(_ deck: PerformanceEngine.Deck, start: Int64, end: Int64)
    func setLoop(_ deck: PerformanceEngine.Deck, beats: Double)
    func exitLoop(_ deck: PerformanceEngine.Deck)
    func setQuantize(_ on: Bool, resolution: QuantizeResolution)
    func setRate(_ deck: PerformanceEngine.Deck, rate: Float)
    func setKeyLock(_ deck: PerformanceEngine.Deck, locked: Bool)
    func setKeyShift(_ deck: PerformanceEngine.Deck, semitones: Float)
    func sync(_ deck: PerformanceEngine.Deck, to master: PerformanceEngine.Deck, barSync: Bool)
    func unsync(_ deck: PerformanceEngine.Deck)
    func isSynced(_ deck: PerformanceEngine.Deck) -> Bool
    func setEQKnobs(_ deck: PerformanceEngine.Deck, low: Float, mid: Float, high: Float)
    func setFilter(_ deck: PerformanceEngine.Deck, knob: Float)
    func setChannelFader(_ deck: PerformanceEngine.Deck, gain: Float)
    func setCrossfader(_ position: Float, curve: CrossfaderCurve)
    func setEchoEnabled(_ deck: PerformanceEngine.Deck, enabled: Bool)
    func setEchoBeats(_ deck: PerformanceEngine.Deck, beats: Double)
    func setEchoDepth(_ deck: PerformanceEngine.Deck, depth: Float)
    func setEchoFeedback(_ deck: PerformanceEngine.Deck, feedback: Float)
    /// Arm a prepared `StemSet` for a deck, or disarm it with `nil` (§35.1,
    /// plan 5.8). A disarmed deck reads the single full-mix source.
    func armStemSet(_ deck: PerformanceEngine.Deck, stemSet: StemSet?)
    /// Set a stem voice's gain target — a linear gain, smoothed render-side.
    func setStemGain(_ deck: PerformanceEngine.Deck, stem: StemKind, gain: Float)
    /// Mute a stem voice — its gain target ramps to 0.
    func setStemMute(_ deck: PerformanceEngine.Deck, stem: StemKind, muted: Bool)
    /// Solo a stem voice — when any voice is soloed, only soloed voices sound.
    func setStemSolo(_ deck: PerformanceEngine.Deck, stem: StemKind, soloed: Bool)
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
    func setHeadphoneCue(_ deck: PerformanceEngine.Deck, enabled: Bool)
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
    /// on: cue is inert there by construction, and the graph's own cue tests
    /// (`CueBusTests`) drive the real engine directly (§44.2a).
    func setHeadphoneCue(_ deck: PerformanceEngine.Deck, enabled: Bool) {}
    func setCueMode(_ mode: CueMode) {}
}

extension PerformanceEngine: WorkspaceEngine {}

/// The per-deck load state of the `WorkspaceModel.load(_:trackID:)` one-gesture
/// path (plan 5.1). The gate and decode failures are **honest states with a
/// message**, never a crash; the crate rows render them (plan: "a decode
/// failure is an honest state not a crash").
public enum DeckLoadState: Equatable, Sendable {
    case idle
    case loading(trackID: Int64)
    case loaded(trackID: Int64)
    /// The FR-LIB-8 gate refused the track — it is not deck-ready.
    case refused(trackID: Int64, reason: String)
    /// The decode or resolve failed; the deck is not armed.
    case failed(trackID: Int64, message: String)

    public var trackID: Int64? {
        switch self {
        case .idle: return nil
        case .loading(let id), .loaded(let id), .refused(let id, _), .failed(let id, _):
            return id
        }
    }

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

/// The honest per-deck stem status (§36.5, FR-ENG-3; plan decision 4). The
/// stem faders are **live only when `.prepared`** — any other state renders
/// the honest disabled label, never a fader that looks live and does nothing.
public enum DeckStemStatus: Equatable, Sendable {
    /// No prepared set is on the deck — the deck plays the full mix (§36.5's
    /// fallback; "stems not prepared").
    case unavailable
    /// A separation job for the deck's track is in flight (§36.3) — the faders
    /// stay disabled until the set lands and is armed.
    case separating
    /// A cached, version-matched set is armed on the deck — the faders are live.
    case prepared

    /// The honest one-line label the surfaces render (§36.5).
    public var label: String {
        switch self {
        case .unavailable: return "stems not prepared"
        case .separating: return "separating…"
        case .prepared: return "stems ready"
        }
    }
}

/// The per-deck stem control state the shared session VM owns — the four
/// voices' gains plus the mute/solo sets, mirrored here (like the EQ/fader
/// state) so every surface's STEMS faders read and write the same state.
public struct StemControlState: Equatable, Sendable {
    /// Per-voice linear gain targets, indexed by `StemKind`. Defaults to unity.
    public var gains: [StemKind: Float]
    /// The muted voices.
    public var muted: Set<StemKind>
    /// The soloed voices.
    public var soloed: Set<StemKind>

    public init(gains: [StemKind: Float] = StemControlState.unityGains,
                muted: Set<StemKind> = [],
                soloed: Set<StemKind> = []) {
        self.gains = gains
        self.muted = muted
        self.soloed = soloed
    }

    /// Unity gains for all four voices.
    public static var unityGains: [StemKind: Float] {
        Dictionary(uniqueKeysWithValues: StemKind.allCases.map { ($0, Float(1)) })
    }

    /// The stem fader's full-travel gain (1.5× = +3.5 dB boost). The faders
    /// span 0…this; the render side hard-clamps nothing — the smoothed gain
    /// and the master limiter (§35.5) keep the sum honest.
    public static let maxGain: Float = 1.5
}

/// The one session view model for every performance surface (plan §2.9, 4.6;
/// §41.9): the iPad workspace, and later the compact solo/twin-deck postures,
/// all over this single VM. Two decks, centre mixer, transport + sync + loop —
/// every mutating call forwards a lock-free command and returns immediately;
/// nothing blocks on audio (§12.2).
///
/// Telemetry is driven by a display-rate `TelemetryPump` at the display's
/// native cadence (throttled at `.serious`, §40.3); the model consumes the
/// engine's `AsyncStream` and publishes the value, plus the idle-timer scoping
/// (§34A.6, plan §2.14). The workspace gate is `ProCapability.isEnabled(.decks)`
/// (App. T.3) — free users see the real, dimmed surface with a lock chip
/// (§40.4).
@MainActor
public final class WorkspaceModel: ObservableObject {

    /// The control surface.
    public let engine: any WorkspaceEngine
    /// The entitlement store the workspace gate reads (App. T.3) — exposed so
    /// the performance surfaces can hand it to the paywall (`PaywallModel`),
    /// which buys through the *same* store that unlocks the decks (AT-STORE-2).
    public let store: EntitlementStore
    /// The audio session coordinator the app entered before building the engine
    /// (§34A.2, plan 5.4a). Retained for the workspace's lifetime so its route /
    /// interruption marshalling survives; the responses are consumed here (plan
    /// 5.11) — `.began` flushes the recording segment, `.ended` opens a new one,
    /// never auto-playing (§34A.4). `nil` when the session was never entered
    /// (tests inject none).
    private let session: AudioSessionCoordinator?
    /// The §37.3 recording journal + recovery service (plan 5.11): the record
    /// toggle's `begin`/`finalize` write the `mix`/`mix_asset` rows, and
    /// `reconcile` runs on workspace appear to salvage crashed recordings.
    /// Injectable so the model's wiring is testable with a fake; nil in the
    /// model-level tests that predate the journal.
    private let recordingService: (any RecordingJournaling)?
    /// The library → deck seam (plan 5.1, decision 16): the per-deck queues
    /// (§41.9c, FR-ENG-13) and the one gesture that loads a track to a deck
    /// through the FR-LIB-8 gate and the decode path. Injectable so the model's
    /// queue state and load forwarding are testable with a fake; the real
    /// `DeckLoader(store: .shared)` is resolved lazily so a model that never
    /// touches a queue costs no database I/O.
    public var library: any DeckLibraryServicing {
        injectedLibrary ?? DeckLoader(store: .shared)
    }
    private let injectedLibrary: (any DeckLibraryServicing)?
    private let crateImporter: any PlaylistCrateImporting
    /// The §26A render-model seam (plan 5.3): builds each deck's
    /// `WaveformRenderModel` from persisted analysis when a track loads and
    /// when the thermal state crosses the §26A.7 shed. `WaveformRepository`
    /// conforms; tests inject a fake so the workspace's waveform state is
    /// exercised deterministically (§47.2).
    public var waveformRepository: any WaveformRendering {
        injectedWaveformRepository ?? WaveformRepository(pool: DJLibraryStore.shared.pool)
    }
    private let injectedWaveformRepository: (any WaveformRendering)?
    /// The stem seam (plan 5.8, decision 3): resolve a loaded track's prepared
    /// stem set, or the honest absence. `StemLoader` conforms; tests inject a
    /// fake so the per-deck stem status and fader forwarding are exercised
    /// deterministically (§47.2). Resolved lazily so a model that never loads
    /// a track with prepared stems costs no database I/O.
    public var stemProvider: any StemProviding {
        injectedStemProvider ?? StemLoader()
    }
    private let injectedStemProvider: (any StemProviding)?
    /// The track currently loaded on each deck — what the deck's waveform is
    /// built from. Cleared when the deck is reloaded.
    private var loadedTrackIDs: [PerformanceEngine.Deck: Int64] = [:]
    /// The thermal state the waveform models were last built under, so a
    /// crossing into/out of `.serious` rebuilds them (one level coarser,
    /// §26A.7).
    private var lastWaveformThermal: WaveformThermal?
    private let pump: TelemetryPump?
    private var telemetryTask: Task<Void, Never>?
    private var anyDeckPlaying = false
    /// The §34A.4 session-response consumer (plan 5.11): flushes the recording
    /// segment on `.began`, opens a new one on `.ended` — never auto-plays.
    private var interruptionTask: Task<Void, Never>?

    /// Where the per-deck module-slot / jog-mode choices are remembered
    /// (§41.9a, plan 4.11). Injectable so tests isolate the persistence.
    private let defaults: UserDefaults
    /// How long a pinned bank drawer stays up without touch before it
    /// self-dismisses (§42.7b, AT-TWIN-3). Injectable so the model test runs
    /// fast instead of sleeping 12 s.
    private let pinnedDrawerIdle: Duration
    private var drawerIdleTask: Task<Void, Never>?
    /// The per-deck remembered bank the drawer springs to (§42.7b).
    private var bankByDeck: [PerformanceEngine.Deck: TwinBank] = [:]

    @Published public var telemetry = EngineTelemetry()
    @Published public private(set) var isPro: Bool

    /// Recording session state (plan 5.10, decision 14): `isRecording` mirrors
    /// whether the engine's tap + encoder are live, and `recordingElapsed` is
    /// the recorded duration in seconds. Session VM state, not a view's — the
    /// record/elapsed chip is shared across every performance surface.
    @Published public private(set) var isRecording = false
    @Published public private(set) var recordingElapsed: Double = 0

    /// The graph's liveness (NFR-REL-2, §34A.5) — `nil` while it is live, and
    /// the reason it stopped otherwise.
    ///
    /// Published because **every surface has to stop claiming things that are no
    /// longer true** the moment this is set: the record chip stops running its
    /// timer, the decks stop showing themselves as playing, and a banner says
    /// what happened and what became of the recording. The suite's incident is
    /// the specification here — an app that displays `Stop · 5:07` over a dead
    /// engine for fourteen minutes has told the user a lie that costs them
    /// their set.
    @Published public private(set) var engineStopped: EngineLiveness.StopReason?
    /// What became of an in-flight recording when the engine stopped — surfaced
    /// beside the reason, because "the engine stopped" and "your recording is
    /// safe" are two different pieces of news and the user needs both.
    @Published public private(set) var engineStopRecordingOutcome: String?
    /// True while a recovery attempt is in flight, so the button cannot be
    /// pressed twice into two concurrent restarts.
    @Published public private(set) var isRecoveringEngine = false

    /// The stall window is injectable for the same reason `pinnedDrawerIdle`
    /// is: a test that has to sleep two seconds to watch a watchdog fire is a
    /// test nobody runs.
    private var liveness: EngineLivenessMonitor
    private var configurationChangeTask: Task<Void, Never>?
    /// §44.4: the active controller map, and the task delivering its messages.
    private var midiProfile: ControllerProfile?
    private var midiTask: Task<Void, Never>?
    /// The `HardwareService` backing the attached controller. Held so it
    /// outlives the assembly call that attached it (plan dj-midi-alpha M1) and
    /// is released on `detachMidi()`.
    private var midiHardware: HardwareService?
    /// The router's pickup memory (plan dj-midi-alpha M2) — owned here, one per
    /// attachment, so a finger driving an action on the touchscreen can reset
    /// the physical control's claim on it.
    private var midiTakeover = TakeoverState()
    /// True while a routed MIDI intent is being applied, so the touchscreen
    /// setters it goes through do not reset their own pickup claims.
    private var isApplyingMidi = false
    /// Actions whose MIDI binding is awaiting pickup (M2): the UI shows a small
    /// catch indicator naming the control and which way to move it. `distance`
    /// is signed — positive = move down/left to catch.
    @Published public private(set) var midiPendingPickup: [EngineAction: Float] = [:]

    // MARK: - Jog transports (plan dj-midi-alpha M3, FR-ENG-11)

    /// **One** transport per deck, owned by the model, so a finger nudge and a
    /// MIDI nudge share the same `bendBaseRate` bookkeeping — two transports
    /// would restore the wrong rate after a bend.
    private var jogTransportA: JogTransport?
    private var jogTransportB: JogTransport?
    /// The accumulated MIDI jog bend (relative-encoder deltas, clamped to the
    /// ring's ±16 % ceiling) and the per-deck idle-release tasks.
    private var midiJogBend: [PerformanceEngine.Deck: Double] = [:]
    private var midiJogReleaseTasks: [PerformanceEngine.Deck: Task<Void, Never>] = [:]
    /// Whether a jogTouch is currently held (the platter's touch sensor), and
    /// the accumulated scrub radians while held in vinyl mode.
    private var midiJogHeld: [PerformanceEngine.Deck: Bool] = [:]
    private var midiJogRadians: [PerformanceEngine.Deck: Double] = [:]

    /// The per-deck jog transport, created lazily on first use (finger or
    /// MIDI) so an idle surface costs nothing.
    func jogTransport(for deck: PerformanceEngine.Deck) -> JogTransport {
        switch deck {
        case .a:
            if let transport = jogTransportA { return transport }
            let transport = JogTransport(engine: engine, deck: .a)
            jogTransportA = transport
            return transport
        case .b:
            if let transport = jogTransportB { return transport }
            let transport = JogTransport(engine: engine, deck: .b)
            jogTransportB = transport
            return transport
        }
    }
    /// The master-clock sample position when recording started — `elapsed` is
    /// `(masterSample − start) / sampleRate`, which equals the recorded frames.
    private var recordingStartSample: Int64 = 0

    /// The finished mix the review listen opens from (FR-REC-6, plan 5.12):
    /// set when recording stops and the §37.3 journal finalizes, cleared by
    /// `dismissFinishedMix()` once the finish sheet is dismissed. The
    /// performance surfaces present `RecordingFinishView` off this.
    @Published public private(set) var finishedMix: DJMix?
    /// The §37.4 timeline being accumulated while recording (plan 5.12): a deck
    /// starting to play logs "this track, on this deck, at this offset". Cleared
    /// when a recording starts, handed to `finalize` when it stops.
    private var recordingTimeline = MixTimeline()
    /// The per-deck playing state the timeline's rising-edge detector reads.
    /// Reset when a recording starts so a deck already playing at record time
    /// logs its current track at ~0:00 (mockup `ipad/09`'s "0:00 … opened").
    private var wasDeckAPlaying = false
    private var wasDeckBPlaying = false
    /// The recorded transition gestures (dj-regression-suite §7, hook 5.11):
    /// control moves that the workspace recognises as a DJ Blakey transition,
    /// stamped with their recording-relative sample and handed to the journal
    /// at `finalize` so `verify-mix.py` can cross-check each claim against the
    /// audio. Reset when a recording starts. Only ever filled while recording.
    private var transitionEvents: [RecordingJournalEvent] = []

    /// Each deck's §26A render model — the analysis-driven waveform. `nil`
    /// until the deck loads an analysed track, or for an unanalysed track
    /// (the honest empty state, §26A.1). Built off the main actor when the
    /// track loads and when the thermal state crosses the §26A.7 shed.
    @Published public private(set) var waveformA: WaveformRenderModel?
    @Published public private(set) var waveformB: WaveformRenderModel?

    /// Mixer control state — held here so the shared session VM (not a view's
    /// lifetime) is the single owner of where the knobs and faders sit.
    @Published public var eqALow: Float = 0
    @Published public var eqAMid: Float = 0
    @Published public var eqAHigh: Float = 0
    @Published public var eqBLow: Float = 0
    @Published public var eqBMid: Float = 0
    @Published public var eqBHigh: Float = 0
    @Published public var filterA: Float = 0
    @Published public var filterB: Float = 0
    @Published public var channelA: Float = 1.0
    @Published public var channelB: Float = 1.0
    @Published public var crossfader: Float = 0
    @Published public var crossfaderCurve: CrossfaderCurve = .constantPower

    /// The per-deck tempo fader position (§41.9b rule 4): the deck's rate as
    /// a signed fraction off unity, in the ±8% `ClubGeometry.tempoFaderRange`.
    /// Mirrored here (like the EQ/fader state) so the shared session VM — not a
    /// view — owns where the fader sits.
    @Published public var tempoA: Double = 0
    @Published public var tempoB: Double = 0

    /// The §35A post-fader echo's per-deck control state (plan 5.5,
    /// FR-TRANS-4): enabled/beats/depth/feedback, mirrored here so the shared
    /// session VM owns where every surface's Beat FX controls sit — the same
    /// convention as the mixer knobs and the tempo faders.
    @Published public var echoEnabledA: Bool = false
    @Published public var echoEnabledB: Bool = false
    @Published public var echoBeatsA: Double = 1
    @Published public var echoBeatsB: Double = 1
    @Published public var echoDepthA: Float = 0.6
    @Published public var echoDepthB: Float = 0.6
    @Published public var echoFeedbackA: Float = 0.7
    @Published public var echoFeedbackB: Float = 0.7

    /// The per-deck stem status (§36.5, plan decision 4): `prepared` makes the
    /// STEMS faders live; `unavailable` / `separating` render the honest
    /// disabled label. Computed when a track loads, driven to `.separating` by
    /// the §36.3 service (5.9).
    @Published public private(set) var stemStatusA: DeckStemStatus = .unavailable
    @Published public private(set) var stemStatusB: DeckStemStatus = .unavailable
    /// The per-deck stem controls — the four voices' gains and the mute/solo
    /// sets, mirrored here like the mixer knobs so every surface reads and
    /// writes the same session state. Forwarding is clamped and never touches
    /// the engine when the deck's stems are not prepared.
    @Published public private(set) var stemControlsA = StemControlState()
    @Published public private(set) var stemControlsB = StemControlState()

    /// The iPad module slot each deck occupies (§41.9a) — the per-deck
    /// remembered `JOG · STEMS · PADS · FX` choice, **default `STEMS`** so §41.9
    /// is what an existing user sees unless they ask for something else. The
    /// published values let the slot's seg highlight follow the selection.
    @Published public private(set) var moduleSlotA: DeckModuleSlot
    @Published public private(set) var moduleSlotB: DeckModuleSlot
    /// The per-deck jog platter action (§41.9a): vinyl (scratch) or CDJ
    /// (nudge), shown inside the platter so the mode is never a guess.
    @Published public private(set) var jogModeA: JogGestureModel.JogMode
    @Published public private(set) var jogModeB: JogGestureModel.JogMode
    /// The per-deck jog sensitivity, 0.5–2.0 (§40.7.4) — the mixer column's
    /// faders own these (§41.9a). Session state like the mixer controls.
    @Published public var jogSensitivityA: Double = 1.0
    @Published public var jogSensitivityB: Double = 1.0

    /// The selectable per-deck queues (§41.9c): the whole library plus every
    /// saved playlist. Refresh via `refreshDeckQueues()`.
    @Published public private(set) var availableQueues: [DeckQueueSource] = []
    /// Deck A's queue — its source and rows (FR-ENG-13: the two decks may point
    /// at **different** sources at once).
    @Published public private(set) var queueA = DeckQueue(source: .allTracks, rows: [])
    /// Deck B's queue.
    @Published public private(set) var queueB = DeckQueue(source: .allTracks, rows: [])
    @Published public private(set) var importedCrateA: DeckQueueSource?
    @Published public private(set) var importedCrateB: DeckQueueSource?
    @Published public private(set) var crateImportError: String?
    @Published public private(set) var isImportingCrate = false
    /// The per-deck load state of the `load(_:trackID:)` one-gesture path —
    /// idle / loading / loaded, or the honest FR-LIB-8 refusal or decode
    /// failure as a message. View-only readers render it, never block on it.
    @Published public private(set) var loadStateA: DeckLoadState = .idle
    @Published public private(set) var loadStateB: DeckLoadState = .idle
    /// The §12.2 ownership-transfer boxes: the model keeps each deck's decoded
    /// PCM alive until the deck is reloaded. Dropping the box on reload frees
    /// the previous source — the offline harness is synchronous, so the engine
    /// has already retired it.
    private var sourceBoxes: [PerformanceEngine.Deck: DeckSourceBox] = [:]
    /// The §12.2 ownership-transfer boxes for armed stem sets: the model keeps
    /// each deck's prepared set alive until the deck reloads. Dropping the box
    /// disarms nothing by itself — `resolveStems` disarms first.
    private var stemSetBoxes: [PerformanceEngine.Deck: StemSetBox] = [:]

    public init(engine: any WorkspaceEngine,
                store: EntitlementStore,
                pump: TelemetryPump? = nil,
                pinnedDrawerIdle: Duration = .seconds(12),
                defaults: UserDefaults = .standard,
                library: (any DeckLibraryServicing)? = nil,
                crateImporter: any PlaylistCrateImporting = PlaylistCrateImporter(),
                waveformRepository: (any WaveformRendering)? = nil,
                stemProvider: (any StemProviding)? = nil,
                recordingService: (any RecordingJournaling)? = nil,
                session: AudioSessionCoordinator? = nil,
                engineStallSeconds: Double = 2.0) {
        self.engine = engine
        self.liveness = EngineLivenessMonitor(stallSeconds: engineStallSeconds)
        self.store = store
        self.injectedLibrary = library
        self.crateImporter = crateImporter
        self.injectedWaveformRepository = waveformRepository
        self.injectedStemProvider = stemProvider
        self.recordingService = recordingService
        self.session = session
        self.isPro = store.isPro
        self.pinnedDrawerIdle = pinnedDrawerIdle
        self.defaults = defaults
        // The pump's tick drives the engine's atomics → stream directly, so
        // the closure never captures `self` (a display link would otherwise
        // outlive the model during init).
        self.pump = pump ?? TelemetryPump { [weak engine] in engine?.pushTelemetry() }
        // The per-deck module slot and jog mode are remembered across launches
        // (§41.9a, plan 4.11): read them once here, write on change.
        moduleSlotA = Self.readModuleSlot(defaults: defaults, deck: .a)
        moduleSlotB = Self.readModuleSlot(defaults: defaults, deck: .b)
        jogModeA = Self.readJogMode(defaults: defaults, deck: .a)
        jogModeB = Self.readJogMode(defaults: defaults, deck: .b)
    }

    /// The one gate for the performance surface (App. T.3). Free users see the
    /// real, dimmed workspace with a lock chip (§40.4, §41.15).
    public var isDecksEnabled: Bool {
        ProCapability.isEnabled(.decks, store)
    }

    /// Start the engine, the display-rate pump, and the telemetry subscription.
    /// The view calls this on appear and `end()` on disappear. Also consumes the
    /// §34A.4 session responses (the recording flush/new-segment path) and
    /// reconciles any crashed recordings (plan 5.11).
    public func begin() throws {
        try engine.start()
        telemetryTask?.cancel()
        telemetryTask = Task { [weak self] in
            guard let self else { return }
            for await value in engine.telemetry {
                self.apply(value)
            }
        }
        pump?.start()
        startConsumingSessionResponses()
        startObservingConfigurationChanges()
        Task { [weak self] in
            await self?.reconcileRecordings()
        }
    }

    /// `AVAudioEngineConfigurationChange` (§34A.5) — the fast path to the same
    /// honest state the stall detector reaches on its own, arriving with a
    /// reason attached instead of two seconds later without one.
    private func startObservingConfigurationChanges() {
        configurationChangeTask?.cancel()
        configurationChangeTask = Task { [weak self] in
            guard let self else { return }
            for await _ in self.engine.configurationChanges() {
                // AVAudioEngine posts this *after* stopping itself. If it is
                // somehow still running, the graph absorbed the change and
                // there is nothing to report — saying otherwise would train the
                // user to ignore the banner.
                guard !self.engine.isGraphRunning else { continue }
                self.liveness.report(.configurationChange)
                if self.engineStopped == nil {
                    self.handleEngineStopped(.configurationChange)
                }
            }
        }
    }

    public func end() {
        telemetryTask?.cancel()
        telemetryTask = nil
        interruptionTask?.cancel()
        interruptionTask = nil
        configurationChangeTask?.cancel()
        configurationChangeTask = nil
        midiTask?.cancel()
        midiTask = nil
        drawerIdleTask?.cancel()
        drawerIdleTask = nil
        pump?.stop()
        engine.stop()
        IdleTimerScope.update(anyDeckPlaying: false)
    }

    /// Drive one telemetry sample now (the pump does this at display cadence;
    /// the offline harness calls it directly). §40.3.
    public func pumpTelemetryNow() {
        engine.pushTelemetry()
    }

    public func setPumpPaused(_ paused: Bool) {
        pump?.setPaused(paused)
    }

    /// Fold the telemetry sample into the liveness watchdog (NFR-REL-2).
    ///
    /// Runs on every sample, before anything else reads the telemetry, because
    /// the state it produces changes what the rest of `apply` is allowed to
    /// claim — most of all the recording timer.
    private func observeLiveness(_ value: EngineTelemetry, now: Date = Date()) {
        let playing = value.deckA.playing || value.deckB.playing
        let state = liveness.observe(masterSample: value.masterSample,
                                     anyDeckPlaying: playing,
                                     isRunning: engine.isGraphRunning,
                                     now: now)
        switch state {
        case .live:
            return
        case .stopped(let reason):
            guard engineStopped == nil else { return }
            handleEngineStopped(reason)
        }
    }

    /// The graph stopped. Tell the truth, then save what can be saved.
    ///
    /// Order matters: the flags that make the UI stop lying are set *first* and
    /// synchronously, so there is no window in which the timer keeps running
    /// while an async finalize is in flight. Only then does the recording get
    /// closed out — and it is closed out rather than abandoned, because the
    /// encoder's flushed segments are a real recording (NFR-REL-2) and the user
    /// should get the twenty minutes that did happen instead of nothing.
    private func handleEngineStopped(_ reason: EngineLiveness.StopReason) {
        engineStopped = reason
        let wasRecording = isRecording
        if wasRecording {
            engineStopRecordingOutcome = "Saving what was recorded up to that point…"
            Task { [weak self] in
                guard let self else { return }
                await self.finalizeRecordingAfterEngineStop()
            }
        }
        IdleTimerScope.update(anyDeckPlaying: false)
    }

    /// Close out a recording whose engine died under it. The audio already on
    /// disk is the guarantee §37.3 was built around, so this is the ordinary
    /// stop path — not a special case — and its failure is reported rather than
    /// swallowed.
    private func finalizeRecordingAfterEngineStop() async {
        await stopRecording()
        // `stopRecording` publishes the finished mix when the join and the
        // journal both succeeded. When it did not, the flushed segments are
        // still on disk and §37.3's `reconcile()` salvages them on next
        // appear — so the honest message is "recovered later", never "lost".
        engineStopRecordingOutcome = finishedMix == nil
            ? "The recording could not be finalised now — Recorded Mixes will recover it."
            : "The recording was saved up to the moment the engine stopped."
    }

    /// Try to bring the graph back (§34A.5). Never automatic: a set that
    /// restarts itself mid-transition is worse than one that waits to be told,
    /// and the human is standing right there.
    public func recoverEngine() async {
        guard !isRecoveringEngine else { return }
        isRecoveringEngine = true
        defer { isRecoveringEngine = false }
        do {
            try engine.recoverGraph()
            liveness.recovered()
            engineStopped = nil
            engineStopRecordingOutcome = nil
        } catch {
            engineStopRecordingOutcome =
                "The engine could not be restarted (\(error.localizedDescription)). "
                + "Leave the decks and come back to rebuild the audio graph."
        }
    }

    private func apply(_ value: EngineTelemetry) {
        telemetry = value
        observeLiveness(value)
        // A stopped graph renders nothing, so nothing below this line is true
        // of it: the elapsed timer would run on a stale clock and the timeline
        // would log track starts that never sounded.
        if engineStopped != nil { return }
        if isRecording {
            // Decision 14's elapsed chip: the recorded frames are exactly the
            // master-clock frames captured by the tap (§37.2), so elapsed is
            // `(masterSample − start) / sampleRate`.
            recordingElapsed = Double(value.masterSample - recordingStartSample) / engine.sampleRate
            // §37.4 (plan 5.12): a deck's not-playing → playing edge is a
            // track start — log it for the mix's timeline.
            if value.deckA.playing && !wasDeckAPlaying {
                recordTimelineEvent(for: .a)
            }
            if value.deckB.playing && !wasDeckBPlaying {
                recordTimelineEvent(for: .b)
            }
        }
        wasDeckAPlaying = value.deckA.playing
        wasDeckBPlaying = value.deckB.playing
        let playing = value.deckA.playing || value.deckB.playing
        if playing != anyDeckPlaying {
            anyDeckPlaying = playing
            IdleTimerScope.update(anyDeckPlaying: playing)
        }
        // §26A.7: the waveform detail is one pyramid level coarser at
        // `.serious`. Rebuild a deck's render model when the thermal state
        // crosses the shed line (rare; the build runs off the main actor).
        let thermal = WaveformThermal.current
        if thermal != lastWaveformThermal {
            lastWaveformThermal = thermal
            rebuildAllWaveforms()
        }
    }

    /// Log "the deck started playing its loaded track" into the §37.4 timeline
    /// (plan 5.12). The offset is the recording's own frames (§37.2).
    private func recordTimelineEvent(for deck: PerformanceEngine.Deck) {
        guard let trackID = loadedTrackIDs[deck] else { return }
        recordingTimeline.record(trackID: trackID,
                                 deck: deck == .a ? "A" : "B",
                                 startOffsetSec: recordingElapsed)
    }

    // MARK: - Transport / loading

    /// The deck's current playback rate — the jog reads it as the base for a
    /// temporary pitch bend (§40.7.3).
    public func deckRate(_ deck: PerformanceEngine.Deck) -> Double {
        engine.deckRate(deck)
    }

    public func load(_ deck: PerformanceEngine.Deck, source: DeckSource) {
        engine.load(deck, source: source)
    }

    // MARK: - Per-deck queues (§41.9c, FR-ENG-13; plan 5.1)

    /// A deck's current queue (its source + rows). Both decks stay independent:
    /// `selectQueue(_:for:)` touches only the named deck (FR-ENG-13).
    public func queue(for deck: PerformanceEngine.Deck) -> DeckQueue {
        deck == .a ? queueA : queueB
    }

    public func importedCrate(for deck: PerformanceEngine.Deck) -> DeckQueueSource? {
        deck == .a ? importedCrateA : importedCrateB
    }

    public func availableCratePlaylists() async -> [CratePlaylistSummary] {
        await crateImporter.availablePlaylists()
    }

    public func cratePlaylistTracks(_ id: Int64) async -> [CrateTrackSummary] {
        await crateImporter.tracks(in: id)
    }

    public func importCrate(playlistID: Int64, title: String,
                            into deck: PerformanceEngine.Deck) async {
        isImportingCrate = true
        crateImportError = nil
        defer { isImportingCrate = false }
        do {
            let result = try await crateImporter.importCrate(playlistID: playlistID, title: title)
            if deck == .a { importedCrateA = result.source } else { importedCrateB = result.source }
            await selectQueue(result.source, for: deck)
            if result.skipped > 0 {
                crateImportError = "\(result.skipped) tracks are not on this device."
            }
        } catch {
            crateImportError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// The deck's current load state — the crate rows render it.
    public func loadState(for deck: PerformanceEngine.Deck) -> DeckLoadState {
        deck == .a ? loadStateA : loadStateB
    }

    /// The loaded track's title for a deck, resolved from its queue's rows
    /// (which carry the same `trackID` the load gesture used). `nil` until a
    /// track is loaded — the honest "nothing loaded" state, surfaced on the
    /// surface's accessibility tree as `dj.deck.<a|b>.loaded`.
    public func loadedTrackTitle(for deck: PerformanceEngine.Deck) -> String? {
        guard let id = loadedTrackIDs[deck] else { return nil }
        return queue(for: deck).rows.first { $0.trackID == id }?.title
    }

    /// Refresh the selectable queues and re-read each deck's current queue's
    /// rows. Called when the workspace's browse surface appears (and when a new
    /// playlist is saved). Never changes what is loaded or playing.
    public func refreshDeckQueues() async {
        availableQueues = (try? await library.availableQueues()) ?? []
        await reloadQueue(for: .a)
        await reloadQueue(for: .b)
    }

    /// Point one deck at a source. **The other deck is untouched** — setting
    /// deck A's queue never changes deck B's (FR-ENG-13), and neither queue ever
    /// advances on its own (there is no auto-play-next on a deck, §41.9c).
    public func selectQueue(_ source: DeckQueueSource, for deck: PerformanceEngine.Deck) async {
        let rows = (try? await library.rows(in: source)) ?? []
        switch deck {
        case .a: queueA = DeckQueue(source: source, rows: rows)
        case .b: queueB = DeckQueue(source: source, rows: rows)
        }
    }

    /// The one gesture that loads a library track to a deck (FR-ENG-13,
    /// §41.9c): resolve → FR-LIB-8 gate → decode off the main actor → hand the
    /// `DeckSource` to the engine, keeping the §12.2 box alive. The engine is
    /// touched **only** on a successful load. After the full mix is armed, the
    /// deck's stems are resolved (§36.5): a prepared set is armed and the
    /// faders go live; otherwise the deck plays the full mix with the honest
    /// `unavailable` status.
    public func load(_ deck: PerformanceEngine.Deck, trackID: Int64) async {
        setLoadState(.loading(trackID: trackID), for: deck)
        switch await library.load(trackID: trackID) {
        case .loaded(let box):
            engine.load(deck, source: box.source)
            sourceBoxes[deck] = box
            loadedTrackIDs[deck] = trackID
            setLoadState(.loaded(trackID: trackID), for: deck)
            rebuildWaveform(for: deck)
            await resolveStems(for: deck, trackID: trackID, grid: box.source.grid)
        case .refused(let readiness):
            let reason = Self.unavailableReason(readiness)
            setLoadState(.refused(trackID: trackID, reason: reason), for: deck)
        case .failed(let failure):
            setLoadState(.failed(trackID: trackID, message: failure.message), for: deck)
        }
    }

    /// Load a crate selection and immediately put it on air. The browse
    /// surface is the field-test user's track selection gesture; leaving the
    /// deck merely armed made the UI appear inert and required a second,
    /// hidden transport action before any music could be heard.
    public func loadAndPlay(_ deck: PerformanceEngine.Deck, trackID: Int64) async {
        await load(deck, trackID: trackID)
        guard case .loaded = loadState(for: deck) else { return }
        play(deck)
    }

    // MARK: - Per-deck stems (§36.5, §35.1; plan 5.8)

    /// The deck's stem status — `prepared` makes the STEMS faders live.
    public func stemStatus(_ deck: PerformanceEngine.Deck) -> DeckStemStatus {
        deck == .a ? stemStatusA : stemStatusB
    }

    /// A stem voice's gain target (0…1.5, unity default).
    public func stemGain(_ deck: PerformanceEngine.Deck, stem: StemKind) -> Float {
        controls(deck).gains[stem] ?? 1
    }

    /// Whether a stem voice is muted.
    public func stemIsMuted(_ deck: PerformanceEngine.Deck, stem: StemKind) -> Bool {
        controls(deck).muted.contains(stem)
    }

    /// Whether a stem voice is soloed.
    public func stemIsSoloed(_ deck: PerformanceEngine.Deck, stem: StemKind) -> Bool {
        controls(deck).soloed.contains(stem)
    }

    /// Move a stem voice's gain fader (0…1.5). Forwarded — and mirrored — only
    /// when the deck's stems are prepared: an unprepared fader is **fully
    /// inert**, because a fader that moves while doing nothing is §36.5's exact
    /// prohibition ("never a fader that looks live and does nothing").
    public func setStemGain(_ deck: PerformanceEngine.Deck, stem: StemKind, gain: Float) {
        guard stemStatus(deck) == .prepared else { return }
        let clamped = min(StemControlState.maxGain, max(0, gain))
        let previous = controls(deck).gains[stem] ?? 0
        setControls(deck) { $0.gains[stem] = clamped }
        engine.setStemGain(deck, stem: stem, gain: clamped)
        resetMidiPickup(for: .stemGain(deck: midiDeckID(deck), stem: stem))
        // S8: the DJ stem lane's journal mark — a fader pulled to the floor
        // while recording is the gesture the host analyzer measures
        // (`stem.fader`, §53.9 settled-state band check). Fires once, on the
        // downward crossing, so a drag sends exactly one mark.
        if isRecording, previous > 0.1, clamped <= 0.1 {
            recordTransition(RecordingJournalEvent(kind: "stem.fader",
                                                   atSample: currentRecordingSample,
                                                   outgoing: deckID(deck),
                                                   stem: stem.rawValue))
        }
    }

    /// Mute a stem voice — its gain target ramps to 0. Inert unless prepared
    /// (§36.5's honest-fader rule).
    public func setStemMute(_ deck: PerformanceEngine.Deck, stem: StemKind, muted: Bool) {
        guard stemStatus(deck) == .prepared else { return }
        setControls(deck) {
            if muted { $0.muted.insert(stem) } else { $0.muted.remove(stem) }
        }
        engine.setStemMute(deck, stem: stem, muted: muted)
    }

    /// Solo a stem voice — when any voice is soloed, only soloed voices sound.
    /// Inert unless prepared.
    public func setStemSolo(_ deck: PerformanceEngine.Deck, stem: StemKind, soloed: Bool) {
        guard stemStatus(deck) == .prepared else { return }
        setControls(deck) {
            if soloed { $0.soloed.insert(stem) } else { $0.soloed.remove(stem) }
        }
        engine.setStemSolo(deck, stem: stem, soloed: soloed)
    }

    /// The deck's stem control state (the mirrored gain/mute/solo state).
    private func controls(_ deck: PerformanceEngine.Deck) -> StemControlState {
        deck == .a ? stemControlsA : stemControlsB
    }

    /// Reassign a deck's control state through a mutation, publishing the new
    /// value so the faders follow.
    private func setControls(_ deck: PerformanceEngine.Deck,
                             _ mutate: (inout StemControlState) -> Void) {
        var state = controls(deck)
        mutate(&state)
        switch deck {
        case .a: stemControlsA = state
        case .b: stemControlsB = state
        }
    }

    /// Resolve a just-loaded deck's stems (§36.5): a cached, version-matched
    /// set is armed and the status goes `prepared`; otherwise the deck plays
    /// the full mix with the honest `unavailable` status. The engine is armed
    /// or disarmed exactly once per load.
    private func resolveStems(for deck: PerformanceEngine.Deck, trackID: Int64,
                              grid: DeckGrid) async {
        setStemStatus(.unavailable, for: deck)
        engine.armStemSet(deck, stemSet: nil)
        stemSetBoxes[deck] = nil
        setControls(deck) { state in
            state = StemControlState()
        }
        guard let prepared = try? await stemProvider.preparedStems(trackID: trackID, grid: grid)
        else {
            return // honest unavailable → full mix, faders disabled
        }
        engine.armStemSet(deck, stemSet: prepared.stemSet)
        stemSetBoxes[deck] = prepared
        setStemStatus(.prepared, for: deck)
    }

    /// Report that a separation job for the deck's loaded track has started
    /// (driven by the §36.3 service in 5.9). The faders stay disabled — the
    /// honest `separating` status renders until the set is prepared and armed.
    public func markStemSeparation(_ deck: PerformanceEngine.Deck) {
        setStemStatus(.separating, for: deck)
    }

    private func setStemStatus(_ status: DeckStemStatus, for deck: PerformanceEngine.Deck) {
        switch deck {
        case .a: stemStatusA = status
        case .b: stemStatusB = status
        }
    }

    // MARK: - Per-deck waveform render models (§26A, plan 5.3)

    /// A deck's §26A render model — `nil` until it loads an analysed track, or
    /// for an unanalysed track (the honest empty state). The views draw from
    /// this and take the live playhead from telemetry.
    public func waveform(for deck: PerformanceEngine.Deck) -> WaveformRenderModel? {
        deck == .a ? waveformA : waveformB
    }

    /// Whether a deck currently has a track loaded (drives the waveform's
    /// empty-state wording — "not analysed" vs "load a track").
    public func hasLoadedTrack(_ deck: PerformanceEngine.Deck) -> Bool {
        loadedTrackIDs[deck] != nil
    }

    /// Rebuild every loaded deck's render model — on a load, and on a §26A.7
    /// thermal crossing. Runs off the main actor and publishes back.
    private func rebuildAllWaveforms() {
        rebuildWaveform(for: .a)
        rebuildWaveform(for: .b)
    }

    private func rebuildWaveform(for deck: PerformanceEngine.Deck) {
        guard let trackID = loadedTrackIDs[deck] else {
            setWaveform(nil, for: deck)
            return
        }
        let repository = waveformRepository
        Task.detached { [weak self] in
            let model = try? await repository.renderModel(trackID: trackID)
            await self?.publishWaveform(model, for: deck)
        }
    }

    @MainActor
    private func publishWaveform(_ model: WaveformRenderModel?, for deck: PerformanceEngine.Deck) {
        lastWaveformThermal = WaveformThermal.current
        setWaveform(model, for: deck)
    }

    private func setWaveform(_ model: WaveformRenderModel?, for deck: PerformanceEngine.Deck) {
        switch deck {
        case .a: waveformA = model
        case .b: waveformB = model
        }
    }

    private func reloadQueue(for deck: PerformanceEngine.Deck) async {
        let current = queue(for: deck)
        let rows = (try? await library.rows(in: current.source)) ?? []
        switch deck {
        case .a: queueA = DeckQueue(source: current.source, rows: rows)
        case .b: queueB = DeckQueue(source: current.source, rows: rows)
        }
    }

    private func setLoadState(_ state: DeckLoadState, for deck: PerformanceEngine.Deck) {
        switch deck {
        case .a: loadStateA = state
        case .b: loadStateB = state
        }
    }

    /// The user-facing wording for a refused load (FR-LIB-8) — the crate rows
    /// and the workspace readout share it.
    public static func unavailableReason(_ readiness: DeckReadiness) -> String {
        switch readiness {
        case .ready: return "Ready"
        case .unavailable(let reason): return reason
        }
    }

    public func play(_ deck: PerformanceEngine.Deck) {
        engine.play(deck)
    }

    public func pause(_ deck: PerformanceEngine.Deck) {
        engine.pause(deck)
    }

    public func cue(_ deck: PerformanceEngine.Deck) {
        engine.cue(deck)
    }

    public func releaseCue(_ deck: PerformanceEngine.Deck) {
        engine.releaseCue(deck)
    }

    public func seek(_ deck: PerformanceEngine.Deck, toSample: Int64, quantized: Bool) {
        engine.seek(deck, toSample: toSample, quantized: quantized)
    }

    public func setCue(_ deck: PerformanceEngine.Deck, atSample: Int64) {
        engine.setCue(deck, atSample: atSample)
    }

    public func triggerHotCue(_ deck: PerformanceEngine.Deck, atSample: Int64) {
        engine.triggerHotCue(deck, atSample: atSample)
    }

    public func setLoop(_ deck: PerformanceEngine.Deck, beats: Double) {
        engine.setLoop(deck, beats: beats)
    }

    public func exitLoop(_ deck: PerformanceEngine.Deck) {
        engine.exitLoop(deck)
    }

    public func setQuantize(_ on: Bool, resolution: QuantizeResolution) {
        engine.setQuantize(on, resolution: resolution)
    }

    public func setRate(_ deck: PerformanceEngine.Deck, rate: Float) {
        engine.setRate(deck, rate: rate)
    }

    public func setKeyLock(_ deck: PerformanceEngine.Deck, locked: Bool) {
        engine.setKeyLock(deck, locked: locked)
    }

    public func setKeyShift(_ deck: PerformanceEngine.Deck, semitones: Float) {
        engine.setKeyShift(deck, semitones: semitones)
    }

    // MARK: - Recording (§37.2, FR-ENG-7; plan 5.10, decision 14)

    /// The record toggle every performance surface drives (decision 14): starts
    /// the §37.2 tap + encoder, or stops and finalizes. Forwarding is async —
    /// the engine's encoder is an actor and `stopRecording` returns the
    /// finished recording (5.11 consumes it for the `mix` rows).
    public func toggleRecording() {
        Task {
            if isRecording {
                await stopRecording()
            } else {
                await startRecording()
            }
        }
    }

    /// Start recording: forward to the engine, then mirror the session state
    /// (decision 14). A graph without a record tap is an honest unavailable
    /// state — the chip stays off, it never lies about recording. Once the tap
    /// + encoder are live, the §37.3 journal opens the in-progress `mix` row —
    /// a journal failure aborts the recording rather than running journal-less
    /// (a crash would then lose a recording the app believes is safe).
    public func startRecording() async {
        guard !isRecording else { return }
        let directory: URL
        do {
            directory = try await engine.startRecording()
        } catch {
            return
        }
        guard engine.isRecording else { return }
        if let recordingService {
            do {
                try await recordingService.begin(outputDirectory: directory)
            } catch {
                // The engine is live but nothing will be recoverable — unwind
                // honestly instead of recording silently without a journal.
                _ = try? await engine.stopRecording()
                return
            }
        }
        recordingStartSample = engine.masterSample
        recordingElapsed = 0
        // A fresh §37.4 timeline (§37.4, plan 5.12), and the playing-edge
        // detector reset so a deck already playing at record time logs its
        // current track at ~0:00.
        recordingTimeline = MixTimeline()
        wasDeckAPlaying = false
        wasDeckBPlaying = false
        transitionEvents = []
        finishedMix = nil
        isRecording = true
    }

    /// Stop recording: forward, finalize, write the `mix`/`mix_asset` rows and
    /// join the segments (plan 5.11), persist the §37.4 timeline (plan 5.12),
    /// then mirror the session state off and surface the finished mix for the
    /// review listen (FR-REC-6).
    public func stopRecording() async {
        guard isRecording else { return }
        let output = try? await engine.stopRecording()
        if let output, let recordingService {
            let journal = recordingJournalConfiguration()
            finishedMix = try? await recordingService.finalize(
                output: output, journal: journal, timeline: recordingTimeline)
        }
        isRecording = engine.isRecording
        recordingTimeline = MixTimeline()
        wasDeckAPlaying = false
        wasDeckBPlaying = false
    }

    /// Clear the finished mix — the performance surfaces call this when the
    /// review-listen sheet is dismissed, so a finished recording is presented
    /// exactly once.
    public func dismissFinishedMix() {
        finishedMix = nil
    }

    /// Recover every crashed recording — the §37.3 `reconcile()` on workspace
    /// appear (plan 5.11, NFR-REL-2): stale `recording` rows become `complete`
    /// (segments joined) or `corrupt`. Idempotent; the result is surfaced by
    /// 5.12's Mixes view, not here.
    public func reconcileRecordings() async {
        guard let recordingService else { return }
        _ = try? await recordingService.reconcile()
    }

    /// The engine configuration in force — the self-describing payload for the
    /// regression suite's `mix-journal.json` (dj-regression-suite §7, hook 5.11).
    private func recordingJournalConfiguration() -> RecordingJournalConfiguration {
        RecordingJournalConfiguration(sampleRate: engine.sampleRate,
                                      limiterCeiling: engine.limiterCeiling,
                                      masterBPM: telemetry.masterBPM,
                                      echoBeatsA: echoBeatsA,
                                      echoBeatsB: echoBeatsB,
                                      droppedFrames: Int64(engine.droppedRecordFrames),
                                      events: transitionEvents)
    }

    // MARK: - Transition journal (dj-regression-suite §7)

    /// The recording-relative master-clock sample — the same basis §37.4's
    /// timeline entries use, so a journal event and a `mix_track_event` are
    /// comparable against the same recording.
    private var currentRecordingSample: Int64 {
        engine.masterSample - recordingStartSample
    }

    /// Append one transition event, but only while recording — a gesture made
    /// before the record light is on is a rehearsal, not part of the mix.
    private func recordTransition(_ event: RecordingJournalEvent) {
        guard isRecording else { return }
        transitionEvents.append(event)
    }

    /// Where a control was when the **gesture** now moving it began.
    ///
    /// A transition is a movement, not a value. A finger dragging an EQ knob to
    /// the kill sends dozens of small changes on the way down, and comparing
    /// each one only against the one before it never sees a fall from unity to
    /// kill — it sees thirty tiny steps and recognises nothing. So changes
    /// arriving in quick succession are treated as one gesture, holding the
    /// value the control had when it started, and each gesture may only announce
    /// itself once.
    private var gestures: [String: (origin: Float, touched: Date, fired: Bool)] = [:]
    /// The quiet gap that separates one gesture from the next. Comfortably
    /// longer than a drag's frame interval and far shorter than the musical
    /// distance between two transitions.
    private static let gestureGap: TimeInterval = 0.4

    private func gestureOrigin(_ key: String, current: Float, now: Date = Date()) -> Float {
        if let entry = gestures[key], now.timeIntervalSince(entry.touched) <= Self.gestureGap {
            gestures[key] = (entry.origin, now, entry.fired)
            return entry.origin
        }
        gestures[key] = (current, now, false)
        return current
    }

    private func gestureHasFired(_ key: String) -> Bool { gestures[key]?.fired ?? false }

    private func markGestureFired(_ key: String) {
        guard let entry = gestures[key] else { return }
        gestures[key] = (entry.origin, entry.touched, true)
    }

    private func deckID(_ deck: PerformanceEngine.Deck) -> String {
        deck == .a ? "a" : "b"
    }

    /// `PerformanceEngine.Deck` → the MIDI vocabulary's `EngineAction.DeckID`
    /// (same two decks, two type systems; M2's pickup resets need the action
    /// type).
    private func midiDeckID(_ deck: PerformanceEngine.Deck) -> EngineAction.DeckID {
        deck == .a ? .a : .b
    }

    /// The Bass Swap (§26A.3, transition 1): one deck's low band is killed
    /// while the other's low is already killed — the low end changes hands and
    /// the mids stay put. The `outgoing` deck is the one whose low falls.
    private func detectBassSwap(deck: PerformanceEngine.Deck, newLow: Float) {
        let key = "eq.low.\(deckID(deck))"
        let previous = gestureOrigin(key, current: deck == .a ? eqALow : eqBLow)
        let other = deck == .a ? eqBLow : eqALow
        guard !gestureHasFired(key), previous >= -0.25, newLow <= -0.75, other <= -0.25 else {
            return
        }
        markGestureFired(key)
        recordTransition(RecordingJournalEvent(kind: "transition.bassSwap",
                                               atSample: currentRecordingSample,
                                               outgoing: deckID(deck),
                                               incoming: deckID(deck == .a ? .b : .a)))
    }

    /// The Filter Transition (transition 2): a sweep leaving centre toward the
    /// high-pass side (`filter` fires at the sweep's top), then the return to
    /// centre — the hard bypass (§35.3) — as its own event so the analyzer can
    /// prove low returns to its pre-sweep level. The return is caught by
    /// *state* (the filter was engaged, now it is in the bypass region) rather
    /// than a crossing threshold, because a real sweep's last step can land
    /// anywhere in the bypass band.
    private func detectFilter(deck: PerformanceEngine.Deck, newKnob: Float) {
        let engaged = deck == .a ? filterEngagedA : filterEngagedB
        // Mark the sweep where it **starts** — the knob leaving the bypass band
        // is the moment the DJ began moving it, and a filter transition is the
        // movement, so marking the far end would put the whole sweep before its
        // own mark where nothing measuring it can see it (§53.9 row 2). The
        // engaged flag is what makes it fire once: a sweep arrives as a long
        // run of small changes, and every one of them crosses some threshold.
        // 0.05 is the knob leaving the bypass band, which is where the hand
        // started moving — mark any later and the low is already going by the
        // time the mark lands, so nothing measuring the sweep forward from it
        // sees the sweep.
        if !engaged, newKnob >= 0.05 {
            setFilterEngaged(true, for: deck)
            recordTransition(RecordingJournalEvent(kind: "transition.filter",
                                                   atSample: currentRecordingSample,
                                                   outgoing: deckID(deck)))
        } else if engaged, newKnob < 0.02 {
            // The return to centre is its own mark: §35.3 says centre is a hard
            // bypass, and the analyzer proves the low came back to exactly
            // where it was.
            setFilterEngaged(false, for: deck)
            recordTransition(RecordingJournalEvent(kind: "transition.filterBypass",
                                                   atSample: currentRecordingSample,
                                                   outgoing: deckID(deck)))
        }
    }

    private var filterEngagedA = false
    private var filterEngagedB = false
    private func setFilterEngaged(_ value: Bool, for deck: PerformanceEngine.Deck) {
        switch deck {
        case .a: filterEngagedA = value
        case .b: filterEngagedB = value
        }
    }

    /// The Fader Cut (transition 4) vs Echo Out (transition 3): a channel
    /// fader dropped to the floor is an Echo Out when that deck's §35A echo is
    /// running (the tail is post-fader and keeps ringing), else a plain cut.
    private func detectChannelFader(deck: PerformanceEngine.Deck, newGain: Float) {
        let key = "fader.\(deckID(deck))"
        let previous = gestureOrigin(key, current: deck == .a ? channelA : channelB)
        guard !gestureHasFired(key), previous >= 0.5, newGain <= 0.05 else { return }
        markGestureFired(key)
        if echoEnabled(deck) {
            recordTransition(RecordingJournalEvent(kind: "transition.echoOut",
                                                   atSample: currentRecordingSample,
                                                   outgoing: deckID(deck),
                                                   echoDivision: echoBeats(deck)))
        } else {
            recordTransition(RecordingJournalEvent(kind: "transition.faderCut",
                                                   atSample: currentRecordingSample,
                                                   outgoing: deckID(deck)))
        }
    }

    /// The Blend (transition 5): the crossfader sweeping **into the centre
    /// region** from either side (§35.4), where both decks are audible. Caught
    /// by the new position landing in `|x| ≤ 0.1` while the previous position
    /// was beyond it on that deck's side — so a stepped sweep fires exactly
    /// once as it reaches centre, and a park *away* from centre never does.
    private func detectCrossfader(_ newPosition: Float) {
        let previous = crossfader
        let centered = abs(newPosition) <= 0.1
        if centered, previous <= -0.1 {
            recordTransition(RecordingJournalEvent(kind: "transition.blend",
                                                   atSample: currentRecordingSample,
                                                   outgoing: "a", incoming: "b"))
        } else if centered, previous >= 0.1 {
            recordTransition(RecordingJournalEvent(kind: "transition.blend",
                                                   atSample: currentRecordingSample,
                                                   outgoing: "b", incoming: "a"))
        }
    }

    /// Consume the §34A.4 session responses (plan 5.11): `.began` flushes the
    /// recording segment so the interruption costs at most the in-flight one
    /// (NFR-REL-2); `.ended` opens a **new** segment. Decks are never
    /// auto-played — the resume is the human's call (§34A.4). Route-change
    /// responses are the engine's concern, not the journal's.
    private func startConsumingSessionResponses() {
        guard let session, interruptionTask == nil else { return }
        interruptionTask = Task { [weak self] in
            let responses = await session.responses
            for await response in responses {
                await self?.handleSession(response)
            }
        }
    }

    /// The recording's half of one session response. Only the two §34A.4 rows
    /// touch a recording; everything else is deliberately ignored here (decks
    /// pause/renegotiate elsewhere, and an interruption never resumes playback).
    func handleSession(_ response: SessionPolicy.Response) async {
        guard isRecording else { return }
        switch response {
        case .flushSegmentAndCapturePlayheads:
            try? await engine.interruptRecordingForInterruption()
        case .resume:
            try? await engine.resumeRecordingFromInterruption()
        default:
            break
        }
    }

    // MARK: - Sync (§32)

    public func sync(_ deck: PerformanceEngine.Deck, to master: PerformanceEngine.Deck,
                     barSync: Bool = false) {
        engine.sync(deck, to: master, barSync: barSync)
    }

    public func unsync(_ deck: PerformanceEngine.Deck) {
        engine.unsync(deck)
    }

    public func isSynced(_ deck: PerformanceEngine.Deck) -> Bool {
        engine.isSynced(deck)
    }

    // MARK: - Mixer (§35)

    public func setEQKnobs(_ deck: PerformanceEngine.Deck, low: Float, mid: Float, high: Float) {
        detectBassSwap(deck: deck, newLow: low)
        engine.setEQKnobs(deck, low: low, mid: mid, high: high)
        switch deck {
        case .a:
            eqALow = low; eqAMid = mid; eqAHigh = high
        case .b:
            eqBLow = low; eqBMid = mid; eqBHigh = high
        }
        let id = midiDeckID(deck)
        resetMidiPickup(for: .eq(deck: id, band: .low))
        resetMidiPickup(for: .eq(deck: id, band: .mid))
        resetMidiPickup(for: .eq(deck: id, band: .high))
    }

    public func setFilter(_ deck: PerformanceEngine.Deck, knob: Float) {
        detectFilter(deck: deck, newKnob: knob)
        engine.setFilter(deck, knob: knob)
        switch deck {
        case .a: filterA = knob
        case .b: filterB = knob
        }
        resetMidiPickup(for: .filter(deck: midiDeckID(deck)))
    }

    public func setChannelFader(_ deck: PerformanceEngine.Deck, gain: Float) {
        detectChannelFader(deck: deck, newGain: gain)
        engine.setChannelFader(deck, gain: gain)
        switch deck {
        case .a: channelA = gain
        case .b: channelB = gain
        }
        resetMidiPickup(for: .channelFader(deck: midiDeckID(deck)))
    }

    // MARK: - MIDI (§44.4, FR-HW-1, plan 6.5)

    /// The controller profile in force, and the task feeding it (§44.3).
    ///
    /// Attaching is explicit rather than automatic: the workspace should not
    /// open a MIDI client just because it appeared, and a user with no
    /// controller pays nothing for the feature existing.
    public func attachMidi(_ hardware: HardwareService, profile: ControllerProfile) {
        midiProfile = profile
        midiHardware = hardware
        midiTask?.cancel()
        midiTask = Task { [weak self] in
            for await message in hardware.messages {
                guard let self, let profile = self.midiProfile else { continue }
                // A controller must not drive a Pro-gated surface it cannot
                // otherwise reach — the gate is checked at the intent boundary
                // (T.3), which is exactly here.
                guard self.isDecksEnabled else { continue }
                // Look the binding up once: an unbound address must return
                // before any value is read, or an unmapped relative encoder
                // reads some other control's value as its base (plan M1's
                // latent-bug fix).
                guard let binding = profile.binding(for: message.address) else { continue }
                guard let intent = MidiRouter.intent(
                    for: message, profile: profile,
                    currentValue: self.currentValue(of: binding.action),
                    takeover: &self.midiTakeover) else { continue }
                self.apply(intent)
            }
        }
    }

    public func detachMidi() {
        midiTask?.cancel()
        midiTask = nil
        midiProfile = nil
        midiHardware = nil
        midiTakeover.reset()
        midiPendingPickup = [:]
    }

    /// Apply a routed MIDI intent.
    ///
    /// Every case below goes through the **same public method a finger goes
    /// through** — `setEQKnobs`, `toggleCue`, `setCrossfader` — so a mapped
    /// controller inherits the gesture journal, the transition recognisers and
    /// the Pro gate for free, and cannot become a second path into the engine
    /// that behaves subtly differently (§44.3).
    public func apply(_ intent: MidiRouter.Intent) {
        switch intent {
        case .ignoredRelease(let action):
            // The one deliberate exception to "a release does nothing": the
            // platter's touch sensor (jogTouch) releases the held jog — the
            // exact opposite of a pad, where a release must not fire again.
            if case .jogTouch(let deck) = action {
                midiJogTouchRelease(engineDeck(deck))
            }
            return
        case .awaitingPickup(let action, let distance):
            // The physical control has not caught the engine value yet: surface
            // the "which way" indicator, move nothing (M2).
            midiPendingPickup[action] = distance
        case .setContinuous(let action, let value):
            midiPendingPickup[action] = nil
            isApplyingMidi = true
            defer { isApplyingMidi = false }
            applyContinuous(action, value)
        case .press(let action):
            midiPendingPickup[action] = nil
            isApplyingMidi = true
            defer { isApplyingMidi = false }
            applyPress(action)
        }
    }

    /// The pending-pickup list for the catch indicator: one row per awaiting
    /// action, naming the control and which way to move it in surface terms
    /// (horizontal for the crossfader, vertical for the faders/knobs).
    public var midiCatchItems: [(label: String, target: String)] {
        midiPendingPickup
            .map { action, distance in
                let direction: String
                if case .crossfader = action {
                    direction = distance > 0 ? "move left" : "move right"
                } else {
                    direction = distance > 0 ? "move down" : "move up"
                }
                return (label: "\(action.displayName) — \(direction) to catch",
                        target: action.target)
            }
            .sorted { $0.target < $1.target }
    }

    /// A finger drove `action` on the touchscreen, so the physical control's
    /// claim on it is stale and must re-pick-up (M2). Guarded by
    /// `isApplyingMidi` so a MIDI-driven setter never resets its own claim.
    private func resetMidiPickup(for action: EngineAction) {
        guard !isApplyingMidi, let profile = midiProfile else { return }
        for binding in profile.bindings where binding.action == action {
            midiTakeover.resetPickup(for: binding.address)
        }
        midiPendingPickup[action] = nil
    }

    /// The current engine-side value of a continuous action — what a relative
    /// encoder's increment is applied to.
    public func currentValue(of action: EngineAction) -> Float {
        switch action {
        case .channelFader(let deck): return deck == .a ? channelA : channelB
        case .crossfader: return crossfader
        case .filter(let deck): return deck == .a ? filterA : filterB
        case .eq(let deck, let band):
            switch (deck, band) {
            case (.a, .low): return eqALow
            case (.a, .mid): return eqAMid
            case (.a, .high): return eqAHigh
            case (.b, .low): return eqBLow
            case (.b, .mid): return eqBMid
            case (.b, .high): return eqBHigh
            }
        default: return 0
        }
    }

    private func applyContinuous(_ action: EngineAction, _ value: Float) {
        switch action {
        case .channelFader(let deck):
            setChannelFader(engineDeck(deck), gain: value)
        case .crossfader:
            setCrossfader(value, curve: crossfaderCurve)
        case .filter(let deck):
            setFilter(engineDeck(deck), knob: value)
        case .eq(let deck, let band):
            let d = engineDeck(deck)
            let low = deck == .a ? eqALow : eqBLow
            let mid = deck == .a ? eqAMid : eqBMid
            let high = deck == .a ? eqAHigh : eqBHigh
            switch band {
            case .low: setEQKnobs(d, low: value, mid: mid, high: high)
            case .mid: setEQKnobs(d, low: low, mid: value, high: high)
            case .high: setEQKnobs(d, low: low, mid: mid, high: value)
            }
        case .tempo(let deck):
            // The tempo fader's engine range is ±8% (ClubGeometry), and the
            // transform hands over a bipolar −1…1 — map, do not pass through.
            setTempo(engineDeck(deck),
                     fraction: Double(value) * ClubGeometry.tempoFaderRange.upperBound)
        case .stemGain(let deck, let stem):
            setStemGain(engineDeck(deck), stem: stem, gain: value)
        case .jog(let deck):
            // A relative encoder's ticks are the platter's rotation. Touched in
            // vinyl mode they scrub; otherwise they bend tempo like the ring
            // (plan dj-midi-alpha M3).
            let d = engineDeck(deck)
            if midiJogHeld[d] == true, jogMode(d) == .vinyl {
                midiJogRadians[d] = (midiJogRadians[d] ?? 0)
                    + Double(value) * Self.midiJogSweepToRadians
                jogTransport(for: d).route(.scrub(radians: midiJogRadians[d] ?? 0))
            } else {
                midiJogNudge(d, delta: Double(value))
            }
        default:
            // A continuous message on a trigger action does nothing rather
            // than firing on every increment — a knob bound to PLAY would
            // otherwise machine-gun the transport.
            return
        }
    }

    private func applyPress(_ action: EngineAction) {
        switch action {
        case .play(let deck):
            let d = engineDeck(deck)
            (deck == .a ? telemetry.deckA.playing : telemetry.deckB.playing) ? pause(d) : play(d)
        case .cue(let deck):
            cue(engineDeck(deck))
        case .sync(let deck):
            let d = engineDeck(deck)
            sync(d, to: d == .a ? .b : .a, barSync: true)
        case .headphoneCue(let deck):
            toggleCue(engineDeck(deck))
        case .echoToggle(let deck):
            setEchoEnabled(engineDeck(deck), enabled: !echoEnabled(engineDeck(deck)))
        case .record:
            toggleRecording()
        case .loopToggle(let deck):
            setLoop(engineDeck(deck), beats: 4)
        case .jogTouch(let deck):
            // The platter's touch sensor: press = hold (touch = hold §40.7.3),
            // release = the `ignoredRelease` case handled in `apply(_:)`.
            midiJogTouchHold(engineDeck(deck))
        case .hotCue:
            // **Deliberately inert, and not silently so.** Hot cues have an
            // engine path (`triggerHotCue`) and a §15 table, but nothing yet
            // reads stored cue points into the workspace — the eight pads from
            // 5.4 are the surface, not the storage. Firing this with a made-up
            // sample would jump the track to zero mid-set, so the binding
            // exists in the vocabulary (a profile can carry it) and does
            // nothing until hot-cue storage lands. `bindableActions` leaves it
            // out of the learn UI so nobody maps a dead pad.
            return
        default:
            return
        }
    }

    private func engineDeck(_ deck: EngineAction.DeckID) -> PerformanceEngine.Deck {
        deck == .a ? .a : .b
    }

    // MARK: - MIDI jog (plan dj-midi-alpha M3)

    /// A full relative-encoder sweep — 127 ticks, the jog transform's ±0.16
    /// range — maps to one full platter revolution, i.e. one beat of scrub at
    /// the deck's tempo. One tick ≈ 1/127 revolution.
    static let midiJogSweepToRadians: Double = 2 * .pi / 0.32
    /// How long a jog encoder may go quiet before the MIDI jog releases the
    /// bend — controllers do not send "I stopped".
    private static let midiJogIdleNanoseconds: UInt64 = 150_000_000

    /// Accumulate a relative-encoder delta into the deck's jog bend (clamped
    /// to the ring's ±16 % ceiling) and push it through the shared transport.
    /// An idle timer releases the bend; a controller never says "I stopped".
    private func midiJogNudge(_ deck: PerformanceEngine.Deck, delta: Double) {
        midiJogReleaseTasks[deck]?.cancel()
        let next = min(max((midiJogBend[deck] ?? 0) + delta,
                           -JogGestureModel.maxBendRate), JogGestureModel.maxBendRate)
        midiJogBend[deck] = next
        jogTransport(for: deck).route(.nudge(rate: next))
        midiJogReleaseTasks[deck] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.midiJogIdleNanoseconds)
            guard !Task.isCancelled else { return }
            self?.midiJogRelease(deck)
        }
    }

    /// The encoder went quiet. If the platter is still held, only the bend is
    /// restored — the hold (and the deck paused behind it) survives; otherwise
    /// the transport fully releases.
    private func midiJogRelease(_ deck: PerformanceEngine.Deck) {
        midiJogBend[deck] = 0
        guard midiJogHeld[deck] != true else {
            jogTransport(for: deck).restoreBend()
            return
        }
        midiJogReleaseTasks[deck] = nil
        jogTransport(for: deck).route(.release)
    }

    private func midiJogTouchHold(_ deck: PerformanceEngine.Deck) {
        midiJogHeld[deck] = true
        midiJogRadians[deck] = 0
        jogTransport(for: deck).route(.hold)
    }

    private func midiJogTouchRelease(_ deck: PerformanceEngine.Deck) {
        midiJogHeld[deck] = false
        midiJogRadians[deck] = nil
        midiJogReleaseTasks[deck]?.cancel()
        midiJogReleaseTasks[deck] = nil
        midiJogBend[deck] = 0
        jogTransport(for: deck).route(.release)
    }

    // MARK: - Cue monitoring (§44.2a, FR-HW-3, plan 6.4)

    /// Which decks are routed to the headphone cue, and in which mode.
    ///
    /// Two separate pieces of state on purpose: a DJ leaves cue *armed* on the
    /// incoming deck for a whole transition, and switching modes must not
    /// silently disarm it.
    @Published public private(set) var cueMode: CueMode = .off
    @Published public private(set) var cuedDecks: Set<PerformanceEngine.Deck> = []

    /// The channels the current output route offers, so a mode that cannot be
    /// delivered is refused rather than approximated (§44.2a). Two until a
    /// route says otherwise.
    @Published public private(set) var outputChannelCount: Int = 2

    public func isCued(_ deck: PerformanceEngine.Deck) -> Bool { cuedDecks.contains(deck) }

    /// Toggle a deck's pre-listen. Engaging cue on a deck while the mode is
    /// `.off` also selects a usable mode — otherwise the button does nothing
    /// visible and the user concludes cue is broken.
    public func toggleCue(_ deck: PerformanceEngine.Deck) {
        let enabled = !cuedDecks.contains(deck)
        if enabled {
            cuedDecks.insert(deck)
            if cueMode == .off { setCueMode(defaultCueMode) }
        } else {
            cuedDecks.remove(deck)
        }
        engine.setHeadphoneCue(deck, enabled: enabled)
    }

    /// The mode chosen when a user cues a deck without having picked one:
    /// split output where the route can carry it, cue-in-place otherwise.
    private var defaultCueMode: CueMode {
        CueMode.splitOutput.isAvailable(outputChannels: outputChannelCount)
            ? .splitOutput : .cueInPlace
    }

    /// Select a cue mode. A mode the current route cannot deliver is **not**
    /// selected — the caller gets `false` and the reason belongs on screen
    /// (§44.2a: the substitution is the failure).
    @discardableResult
    public func setCueMode(_ mode: CueMode) -> Bool {
        guard mode.isAvailable(outputChannels: outputChannelCount) else { return false }
        cueMode = mode
        engine.setCueMode(mode)
        return true
    }

    /// Observe the route's channel count (§44.2, FR-HW-4). A route that loses
    /// channels demotes an unavailable mode rather than leaving it selected and
    /// inert.
    public func updateOutputChannelCount(_ channels: Int) {
        outputChannelCount = max(1, channels)
        if !cueMode.isAvailable(outputChannels: outputChannelCount) {
            setCueMode(defaultCueMode)
        }
    }

    public func setCrossfader(_ position: Float, curve: CrossfaderCurve) {
        detectCrossfader(position)
        engine.setCrossfader(position, curve: curve)
        crossfader = position
        crossfaderCurve = curve
        resetMidiPickup(for: .crossfader)
    }

    // MARK: - Beat FX — the §35A post-fader echo (FR-TRANS-4, plan 5.5)

    /// Whether a deck's echo is currently on.
    public func echoEnabled(_ deck: PerformanceEngine.Deck) -> Bool {
        deck == .a ? echoEnabledA : echoEnabledB
    }

    /// A deck's echo beat length (1/4 … 4, §35A.2).
    public func echoBeats(_ deck: PerformanceEngine.Deck) -> Double {
        deck == .a ? echoBeatsA : echoBeatsB
    }

    /// A deck's echo wet depth (0…1, §35A.2).
    public func echoDepth(_ deck: PerformanceEngine.Deck) -> Float {
        deck == .a ? echoDepthA : echoDepthB
    }

    /// A deck's echo feedback — tail length, 0…0.85 (clamped below unity).
    public func echoFeedback(_ deck: PerformanceEngine.Deck) -> Float {
        deck == .a ? echoFeedbackA : echoFeedbackB
    }

    /// Turn a deck's echo on/off. Disabling stops new input to the line but
    /// the tail keeps ringing until it decays, then bypasses (§35A.2) — this
    /// is what makes Echo Out an exit rather than a cut (FR-TRANS-4).
    public func setEchoEnabled(_ deck: PerformanceEngine.Deck, enabled: Bool) {
        engine.setEchoEnabled(deck, enabled: enabled)
        switch deck {
        case .a: echoEnabledA = enabled
        case .b: echoEnabledB = enabled
        }
    }

    /// Set a deck's echo beat length, clamped into the §35A.2 range (1/4 … 4).
    /// The delay is derived from the master clock, so a tempo change moves the
    /// echo with it.
    public func setEchoBeats(_ deck: PerformanceEngine.Deck, beats: Double) {
        let clamped = min(BeatEcho.maxBeats, max(BeatEcho.minBeats, beats))
        engine.setEchoBeats(deck, beats: clamped)
        switch deck {
        case .a: echoBeatsA = clamped
        case .b: echoBeatsB = clamped
        }
    }

    /// Set a deck's echo wet depth, clamped into 0…1.
    public func setEchoDepth(_ deck: PerformanceEngine.Deck, depth: Float) {
        let clamped = min(BeatEcho.maxDepth, max(0, depth))
        engine.setEchoDepth(deck, depth: clamped)
        switch deck {
        case .a: echoDepthA = clamped
        case .b: echoDepthB = clamped
        }
    }

    /// Set a deck's echo feedback, clamped into 0…0.85 — always below unity so
    /// the tail always decays (§35A.2).
    public func setEchoFeedback(_ deck: PerformanceEngine.Deck, feedback: Float) {
        let clamped = min(BeatEcho.maxFeedback, max(BeatEcho.minFeedback, feedback))
        engine.setEchoFeedback(deck, feedback: clamped)
        switch deck {
        case .a: echoFeedbackA = clamped
        case .b: echoFeedbackB = clamped
        }
    }

    // MARK: - §41.9b tempo fader (rule 4)

    /// A deck's tempo-fader position: the signed fraction off unity in
    /// `ClubGeometry.tempoFaderRange`.
    public func tempo(_ deck: PerformanceEngine.Deck) -> Double {
        deck == .a ? tempoA : tempoB
    }

    /// Move a deck's tempo fader (§41.9b rule 4). The fader sets the deck's
    /// rate directly (`rate = 1 + fraction`), clamped to the ±8% range. A
    /// synced deck's continuous rate tracking may override it, exactly as a
    /// pitch fader on club gear overrides sync while it is moved.
    public func setTempo(_ deck: PerformanceEngine.Deck, fraction: Double) {
        let clamped = min(ClubGeometry.tempoFaderRange.upperBound,
                          max(ClubGeometry.tempoFaderRange.lowerBound, fraction))
        switch deck {
        case .a: tempoA = clamped
        case .b: tempoB = clamped
        }
        engine.setRate(deck, rate: Float(1 + clamped))
        resetMidiPickup(for: .tempo(deck: midiDeckID(deck)))
    }

    // MARK: - Master clock bar:beat readout (§53.11)

    /// The master clock's bar and beat (1-indexed) at an absolute master
    /// sample position: `bar = floor(samples / samplesPerBar) + 1`, `beat`
    /// the offset within the bar. `nil` until a master clock exists (no deck
    /// loaded / no tempo). Pure so the regression driver's bar scheduling
    /// (`waitForBar`) is pinned to the same math the UI renders (§53.11's
    /// `dj.master.bar`).
    public static func masterBarBeat(masterSample: Int64,
                                     bpm: Double,
                                     sampleRate: Double) -> (bar: Int, beat: Int)? {
        guard bpm > 0, sampleRate > 0 else { return nil }
        let samplesPerBeat = sampleRate * 60 / bpm
        let samplesPerBar = 4 * samplesPerBeat
        let bar = Int(Double(masterSample) / samplesPerBar) + 1
        let inBar = Double(masterSample).truncatingRemainder(dividingBy: samplesPerBar)
        let beat = min(4, Int(inBar / samplesPerBeat) + 1)
        return (bar, beat)
    }

    /// The master clock's current bar:beat, rendered by `dj.master.bar`.
    public var masterBarBeat: (bar: Int, beat: Int)? {
        Self.masterBarBeat(masterSample: telemetry.masterSample,
                           bpm: telemetry.masterBPM,
                           sampleRate: engine.sampleRate)
    }

    // MARK: - Compact posture (§42.1, §42.6–42.7)

    /// The deck in focus on the compact solo-deck surface. The swap is a
    /// view-only change: both decks stay live in the engine and swapping or
    /// rotating changes no engine state (FR-ENG-10, §42.1).
    @Published public var focusedDeck: PerformanceEngine.Deck = .a

    /// Swap which deck the compact surface focuses. View-only — no engine
    /// call is made, telemetry is untouched, both decks remain live (§42.1).
    public func swapFocus() {
        focusedDeck = focusedDeck == .a ? .b : .a
        Haptics.confirm()
    }

    /// Whether the browse-while-performing crate sheet is raised (§42.7,
    /// mockup `iphone/05b`). Raising it changes no engine state — the decks
    /// keep playing under the sheet.
    @Published public private(set) var isCrateSheetPresented = false

    public func raiseCrateSheet() {
        isCrateSheetPresented = true
        Haptics.confirm()
        // A live performance can add/import a crate while the workspace is
        // already on screen. Refresh immediately when the user asks to browse;
        // the sheet must never look like Crate did nothing because it is still
        // displaying the queue captured when the decks were opened.
        Task { [weak self] in
            await self?.refreshDeckQueues()
        }
    }

    public func dismissCrateSheet() {
        isCrateSheetPresented = false
    }

    /// The band reserved for the always-visible crossfader bottom bar on the
    /// compact surface. The crate sheet's layout is bounded below by this
    /// band: it may never cover the crossfader (§42.7, mockup `iphone/05b`'s
    /// `bottom: 96px` inset).
    public static let crossfaderBarHeight: CGFloat = 96

    /// The tallest the crate sheet may be inside a `containerHeight`-tall
    /// container: roughly 60% of the height (mockup `iphone/05b`), but never
    /// reaching into the crossfader bar — both decks stay visible above the
    /// sheet and the crossfader stays reachable (§42.7).
    public static func crateSheetMaxHeight(containerHeight: CGFloat) -> CGFloat {
        max(0, min(containerHeight * 0.6, containerHeight - crossfaderBarHeight))
    }

    // MARK: - Compact posture (§42.1, §42.7a)

    /// The two iPhone postures (§42.1): **orientation is the mode switch** —
    /// there is no toggle, no setting, no button. Portrait is the solo-deck
    /// surface (`SoloDeckView`), landscape the twin-deck surface
    /// (`TwinDeckView`). The posture is presentation state on the one shared
    /// session VM (like `focusedDeck`); the `CompactPerformanceView` container
    /// maps the OS orientation to it, and both postures run over the same
    /// `WorkspaceModel` and the same live engine.
    public enum CompactPosture: Sendable, Equatable {
        /// Portrait — one deck in focus, one in a strip (§42.6–42.7).
        case solo
        /// Landscape — both decks resident, a jog each (§42.7a).
        case twin
    }

    /// The compact posture the surface currently renders. View-only state:
    /// rotating changes **no** engine state (FR-ENG-10, AT-TWIN-1).
    @Published public var compactPosture: CompactPosture = .solo

    /// Rotate the compact surface between the solo and twin postures
    /// (§42.1). View-only — no engine call is made, telemetry is untouched,
    /// both decks stay live under the swap (AT-TWIN-1). The container drives
    /// this from the OS orientation.
    public func setPosture(_ posture: CompactPosture) {
        compactPosture = posture
    }

    // MARK: - Beat-phase readout (§42.7a mixer column)

    /// The signed beat-phase error between the two decks in (−0.5, 0.5],
    /// positive when deck A is ahead (beat 0.9 vs 0.1 is a −0.2, not +0.8 —
    /// the minimal circular difference). Pure, so the twin mixer column's
    /// readout is testable off-device (AT-TWIN-1's phase meter).
    public static func beatPhaseError(phaseA: Double, phaseB: Double) -> Double {
        var error = (phaseA - phaseB).truncatingRemainder(dividingBy: 1)
        if error > 0.5 {
            error -= 1
        } else if error <= -0.5 {
            error += 1
        }
        return error
    }

    /// The phase error rendered as signed milliseconds at a tempo: `error`
    /// beats at `bpm` = `error × 60000 / bpm` (the sample rate cancels out of
    /// the samples→ms conversion), the mockup's "locked · ±1.8 ms".
    public static func beatPhaseErrorMillis(error: Double, bpm: Double) -> Double {
        guard bpm > 0 else { return 0 }
        return error * 60_000 / bpm
    }

    /// The current signed phase error between the two decks in milliseconds
    /// at the master tempo — the twin mixer column's centre readout.
    public var beatPhaseErrorMillis: Double {
        let error = Self.beatPhaseError(phaseA: telemetry.deckA.phase,
                                        phaseB: telemetry.deckB.phase)
        return Self.beatPhaseErrorMillis(error: error, bpm: telemetry.masterBPM)
    }

    // MARK: - Twin-deck geometry (§42.7a)

    /// The §42.7a twin-deck horizontal budget (spec arithmetic, verbatim):
    ///
    ///    734 = 30 │ 168 jog A │ 6 │ 54 transport │ 8 │ 202 mixer │ 8 │ 54 transport │ 6 │ 168 jog B │ 30
    ///
    /// Both deck columns (jog + transport) are 228 pt; the mixer column is
    /// 202 pt. Encoded here so the twin view consumes exactly the normative
    /// geometry and the frames are testable off-device.
    public enum TwinGeometry {
        public static let usableWidth: CGFloat = 734
        public static let deckColumnWidth: CGFloat = 228
        public static let mixerColumnWidth: CGFloat = 202
        public static let jogWidth: CGFloat = 168
        public static let transportWidth: CGFloat = 54
        public static let outerMargin: CGFloat = 30
        public static let columnGap: CGFloat = 8
        public static let jogTransportGap: CGFloat = 6
        /// The resident crossfader cap's width — the bottom-edge surface's 1:1
        /// mapping is against the cap's travel over the mixer column (§42.7a).
        public static let crossfaderCapWidth: CGFloat = 22
    }

    // MARK: - Momentary bank drawer (§42.7b, mockup `iphone/05d`)

    /// The four momentary banks on the compact surface (§42.7b). Filter is
    /// deliberately absent — it stays on the screen edge, visible and under a
    /// thumb while the drawer is open.
    public enum TwinBank: String, CaseIterable, Sendable {
        case eq = "EQ"
        case stems = "STEMS"
        case pads = "PADS"
        case cues = "CUES"
    }

    /// The §42.7b drawer state machine: `idle`, **spring-loaded** (a tab held —
    /// the drawer is raised for as long as the thumb holds, and releasing
    /// dismisses it within one frame, restoring the jog under the thumb), or
    /// **pinned** (a tap — hands-free, with a 12 s idle self-dismiss,
    /// AT-TWIN-3). The drawer covers **only** that deck's jog + transport and
    /// nothing else (FR-ENG-12, AT-TWIN-2).
    public enum DrawerState: Equatable, Sendable {
        case idle
        case spring(deck: PerformanceEngine.Deck, bank: TwinBank)
        case pinned(deck: PerformanceEngine.Deck, bank: TwinBank)

        public var deck: PerformanceEngine.Deck? {
            switch self {
            case .idle: return nil
            case .spring(let deck, _): return deck
            case .pinned(let deck, _): return deck
            }
        }

        public var bank: TwinBank? {
            switch self {
            case .idle: return nil
            case .spring(_, let bank): return bank
            case .pinned(_, let bank): return bank
            }
        }

        public var isPinned: Bool {
            if case .pinned = self { return true }
            return false
        }
    }

    /// The drawer's current state on the compact surface. View-only: raising,
    /// pinning and dismissing a drawer changes **no** engine state — the decks
    /// keep playing and every shared control stays live (FR-ENG-12, AT-TWIN-2).
    @Published public private(set) var drawerState: DrawerState = .idle

    /// The bank a deck's tab springs to and pins with (§42.7b). Defaults to
    /// `EQ`; the remembered selection survives a rotate and a dismiss.
    public func selectedBank(_ deck: PerformanceEngine.Deck) -> TwinBank {
        bankByDeck[deck] ?? .eq
    }

    /// Spring the drawer open over a deck's jog + transport (§42.7b). Called
    /// on the bank tab's touch-down; the drawer stays up exactly as long as
    /// the thumb holds it.
    public func springDrawer(deck: PerformanceEngine.Deck) {
        drawerIdleTask?.cancel()
        drawerState = .spring(deck: deck, bank: selectedBank(deck))
    }

    /// Release a held drawer: it dismisses **within one frame**, restoring the
    /// jog under the thumb (AT-TWIN-3). A held drawer cannot leave the surface
    /// in a mode the user has forgotten about.
    public func releaseDrawer() {
        drawerIdleTask?.cancel()
        guard drawerState.deck != nil else { return }
        drawerState = .idle
    }

    /// Pin the raised drawer for hands-free work. The pinned drawer
    /// self-dismisses after `pinnedDrawerIdle` of no touch (AT-TWIN-3).
    public func pinDrawer() {
        drawerIdleTask?.cancel()
        guard let deck = drawerState.deck else { return }
        drawerState = .pinned(deck: deck, bank: selectedBank(deck))
        armDrawerIdle()
        Haptics.confirm()
    }

    /// Dismiss the drawer (a pinned drawer's toggle-off, or the 12 s idle
    /// self-dismiss). View-only — the decks keep playing.
    public func dismissDrawer() {
        drawerIdleTask?.cancel()
        guard drawerState.deck != nil else { return }
        drawerState = .idle
    }

    /// Touch inside the pinned drawer resets its idle clock — the 12 s
    /// self-dismiss is "12 s of no touch" (§42.7b). The drawer's background
    /// reports every touch, so working the EQ knobs keeps the bank up.
    public func noteDrawerActivity() {
        guard drawerState.isPinned else { return }
        armDrawerIdle()
    }

    /// Switch the drawer's bank (the pinned drawer's seg selector). Resets the
    /// idle clock — this is touch.
    public func selectDrawerBank(_ bank: TwinBank) {
        guard let deck = drawerState.deck else { return }
        bankByDeck[deck] = bank
        switch drawerState {
        case .idle: break
        case .spring:
            drawerState = .spring(deck: deck, bank: bank)
        case .pinned:
            drawerState = .pinned(deck: deck, bank: bank)
            armDrawerIdle()
        }
    }

    private func armDrawerIdle() {
        drawerIdleTask?.cancel()
        let duration = pinnedDrawerIdle
        drawerIdleTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self.dismissDrawer()
        }
    }

    /// §42.7b's spring-loading discrimination (AT-TWIN-3): a press shorter
    /// than the tap threshold is a **tap** — it pins the bank for hands-free
    /// work; a longer hold that is released is a **peek** — it dismisses,
    /// restoring the jog under the thumb within one frame. Pure so the timing
    /// rule is testable off-device.
    public static func springReleasePins(holdDuration: TimeInterval,
                                         tapThreshold: TimeInterval = DrawerGeometry.tapThreshold) -> Bool {
        holdDuration < tapThreshold
    }

    /// §42.7b's geometry: the momentary drawer is exactly one deck column wide
    /// and spans the control band height — it may cover that deck's jog +
    /// transport, and nothing else (FR-ENG-12, AT-TWIN-2).
    public enum DrawerGeometry {
        public static let width: CGFloat = TwinGeometry.deckColumnWidth
        public static let height: CGFloat = 206
        /// A press shorter than this is a *tap* (pins the bank); a longer
        /// hold that is released is a *peek* (dismisses, restoring the jog).
        public static let tapThreshold: TimeInterval = 0.35
        /// The §42.7a landscape sensor-housing dead band the content is inset
        /// by on each edge.
        public static let deadBandInset: CGFloat = 59
        /// The §42.7b rule-2 screen-edge slider's width (the outer 24 pt).
        public static let edgeSliderWidth: CGFloat = 24
    }

    /// The drawer's x-range over a deck in the §42.7a usable-width coordinate
    /// space (0 = the left edge of the 734 pt usable width, outside the 59 pt
    /// dead band). The drawer is exactly one deck column wide over that deck's
    /// jog + transport, so it structurally cannot reach the mixer column or
    /// the opposite deck — the crossfader, both waveforms, the beat-phase
    /// meter and the opposite jog stay live and hit-testable (FR-ENG-12,
    /// AT-TWIN-2).
    public static func drawerXRange(deck: PerformanceEngine.Deck) -> Range<CGFloat> {
        switch deck {
        case .a:
            let start = TwinGeometry.outerMargin
            return start..<(start + DrawerGeometry.width)
        case .b:
            let start = TwinGeometry.usableWidth - TwinGeometry.outerMargin - DrawerGeometry.width
            return start..<(start + DrawerGeometry.width)
        }
    }

    /// The mixer column's x-range in the same coordinate space. A drawer may
    /// never intersect it. (The §42.7a budget: outer margin 30 + deck column
    /// 228 + gap 8 → the mixer starts at 266.)
    public static var mixerXRange: Range<CGFloat> {
        let start = TwinGeometry.outerMargin + TwinGeometry.deckColumnWidth + TwinGeometry.columnGap
        return start..<(start + TwinGeometry.mixerColumnWidth)
    }

    /// §42.7a idiom 4: the whole bottom edge is a **1:1 relative crossfader
    /// drag surface** — a drag of `deltaX` pt moves the resident fader cap by
    /// `deltaX` pt. `residentCapTravel` is the resident cap's travel for a full
    /// −1 … +1 sweep; the mapping is linear and clamped at the ends. Pure so
    /// the 1:1 mapping is testable off-device.
    public static func relativeCrossfader(from position: Float,
                                          deltaX: CGFloat,
                                          residentCapTravel: CGFloat) -> Float {
        guard residentCapTravel > 0 else { return position }
        let unitsPerPoint = 2 / residentCapTravel
        return min(1, max(-1, position + Float(deltaX) * Float(unitsPerPoint)))
    }

    // MARK: - Release-to-commit flyout (§42.7b idiom 3, §41.9a)

    /// §42.7b idiom 3: the **release-to-commit flyout** anchored to LOOP. The
    /// §41.9a beat counts; release over a size commits, release outside
    /// cancels — the loop never changes on the way out. CUE keeps its existing
    /// §33.1 press-jump-preview / release-return, which is the same idiom's
    /// cue semantics (hold to preview, release to return; nothing changes on
    /// the way out).
    public enum LoopAction: Equatable {
        case set(Double)
        case exit
    }

    /// The flyout's geometry and release resolution, laid out in the flyout's
    /// own coordinate space (origin = the flyout's top-left, including the
    /// kicker header). The view anchors the flyout over the LOOP button and
    /// renders each chip at exactly its `chipFrame`, so the drag's release
    /// point resolves honestly against what the user sees:
    /// `releasedAction(at:)` returns the commit — `nil` means the finger slid
    /// out and nothing changes.
    public enum LoopFlyout {
        public static let beats: [Double] = [1, 2, 4, 8, 16, 32]
        public static let width: CGFloat = 150
        public static let chipWidth: CGFloat = 44
        public static let chipHeight: CGFloat = 34
        public static let gap: CGFloat = 6
        public static let horizontalPadding: CGFloat = 8
        public static let headerHeight: CGFloat = 26
        public static let topPadding: CGFloat = 8
        public static let beatsPerRow = 3
        public static let exitChipWidth: CGFloat = 96

        static var gridHeight: CGFloat {
            let rows = (beats.count + beatsPerRow - 1) / beatsPerRow
            return CGFloat(rows) * chipHeight + CGFloat(max(0, rows - 1)) * gap
        }

        public static var height: CGFloat {
            headerHeight + topPadding + gridHeight + gap + chipHeight + topPadding
        }

        static func chipFrame(index: Int) -> CGRect {
            let row = index / beatsPerRow
            let col = index % beatsPerRow
            return CGRect(x: horizontalPadding + CGFloat(col) * (chipWidth + gap),
                          y: headerHeight + topPadding + CGFloat(row) * (chipHeight + gap),
                          width: chipWidth, height: chipHeight)
        }

        static var exitChipFrame: CGRect {
            CGRect(x: (width - exitChipWidth) / 2,
                   y: headerHeight + topPadding + gridHeight + gap,
                   width: exitChipWidth, height: chipHeight)
        }

        /// The action a release point commits, `nil` when it slides out.
        /// Nothing changes on the way out — the engine is touched only here.
        public static func releasedAction(at point: CGPoint) -> LoopAction? {
            for (index, beats) in beats.enumerated() where chipFrame(index: index).contains(point) {
                return .set(beats)
            }
            if exitChipFrame.contains(point) { return .exit }
            return nil
        }
    }

    // MARK: - iPad module slot (§41.9a, mockup `ipad/07b`)

    /// The per-deck module slot on the iPad workspace (§41.9a). The lower
    /// third of a deck column offers `JOG · STEMS · PADS · FX`, is remembered
    /// per deck, and **defaults to `STEMS`** so §41.9 is what an existing user
    /// sees unless they ask for something else.
    public enum DeckModuleSlot: String, CaseIterable, Sendable, Equatable {
        case jog = "JOG"
        case stems = "STEMS"
        case pads = "PADS"
        case fx = "FX"
    }

    /// The persisted per-deck choices (§41.9a): the module slot and the jog's
    /// platter mode. Injectable `UserDefaults` keeps the persistence testable
    /// off-device (the VibeSearchModel convention).
    public static let moduleSlotDefaultsPrefix = "workspace.moduleSlot."
    public static let jogModeDefaultsPrefix = "workspace.jogMode."

    /// The module slot a deck currently occupies — the remembered selection,
    /// `STEMS` by default (§41.9a).
    public func moduleSlot(_ deck: PerformanceEngine.Deck) -> DeckModuleSlot {
        deck == .a ? moduleSlotA : moduleSlotB
    }

    /// Switch a deck's module slot (`JOG · STEMS · PADS · FX`). The choice is
    /// remembered per deck and across launches. **View-only**: swapping the
    /// module changes no engine state — the decks keep playing, the mixer and
    /// transport stay live, and only the deck's own lower third re-renders
    /// (AT-TWIN-2).
    public func setModuleSlot(_ slot: DeckModuleSlot, deck: PerformanceEngine.Deck) {
        switch deck {
        case .a: moduleSlotA = slot
        case .b: moduleSlotB = slot
        }
        defaults.set(slot.rawValue, forKey: Self.moduleSlotKey(deck))
        Haptics.confirm()
    }

    /// The deck's jog platter action (§41.9a): vinyl = scratch, CDJ = nudge.
    /// Remembered per deck, defaulting to vinyl.
    public func jogMode(_ deck: PerformanceEngine.Deck) -> JogGestureModel.JogMode {
        deck == .a ? jogModeA : jogModeB
    }

    /// Set the deck's jog platter action. Remembered per deck. **View-only** —
    /// it changes the jog's gesture model, never the engine (FR-ENG-11).
    public func setJogMode(_ mode: JogGestureModel.JogMode, deck: PerformanceEngine.Deck) {
        switch deck {
        case .a: jogModeA = mode
        case .b: jogModeB = mode
        }
        defaults.set(mode == .vinyl ? "vinyl" : "cdj", forKey: Self.jogModeKey(deck))
        Haptics.confirm()
    }

    /// The deck's jog sensitivity, 0.5–2.0 (§40.7.4).
    public func jogSensitivity(_ deck: PerformanceEngine.Deck) -> Double {
        deck == .a ? jogSensitivityA : jogSensitivityB
    }

    /// Set the deck's jog sensitivity, clamped into the §40.7.4 range. **View-
    /// only** — sensitivity scales the jog gesture's displacement; it never
    /// reaches the engine.
    public func setJogSensitivity(_ deck: PerformanceEngine.Deck, value: Double) {
        let clamped = JogGestureModel.clampSensitivity(value)
        switch deck {
        case .a: jogSensitivityA = clamped
        case .b: jogSensitivityB = clamped
        }
    }

    private static func deckName(_ deck: PerformanceEngine.Deck) -> String {
        deck == .a ? "a" : "b"
    }

    private static func moduleSlotKey(_ deck: PerformanceEngine.Deck) -> String {
        moduleSlotDefaultsPrefix + deckName(deck)
    }

    private static func jogModeKey(_ deck: PerformanceEngine.Deck) -> String {
        jogModeDefaultsPrefix + deckName(deck)
    }

    private static func readModuleSlot(defaults: UserDefaults,
                                       deck: PerformanceEngine.Deck) -> DeckModuleSlot {
        let raw = defaults.string(forKey: moduleSlotKey(deck)) ?? ""
        return DeckModuleSlot(rawValue: raw) ?? .stems
    }

    private static func readJogMode(defaults: UserDefaults,
                                    deck: PerformanceEngine.Deck) -> JogGestureModel.JogMode {
        defaults.string(forKey: jogModeKey(deck)) == "cdj" ? .cdj : .vinyl
    }

    /// §41.9a/§41.9b module and club geometry. The jog module is the widest
    /// module — a 248 pt jog flanked by the ± pitch-bend columns — and must fit
    /// its deck column without pushing into the mixer column (AT-TWIN-2: a
    /// module never occludes shared controls; it is a layout member of its own
    /// column, not an overlay). §41.9b widens the mixer column to 320 pt and
    /// narrows each deck column to ~416 pt; the 392 pt jog module still fits
    /// the deck column alone (the module slot's JOG option), and the deck
    /// column's permanent §41.9b jog is the plain 248 pt platter beside the
    /// tempo fader, which also fits (decision 19: the geometry tests are
    /// updated against the new numbers, never weakened).
    public enum ModuleGeometry {
        /// The §41.9a jog diameter: 248 pt ≈ 48 mm at the iPad's 131 pt/in — a
        /// whole-hand control rather than the iPhone's thumb control.
        public static let jogSize: CGFloat = 248
        /// Each ± pitch-bend column's width (mockup `ipad/07b`).
        public static let bendColumnWidth: CGFloat = 58
        /// The jog ↔ bend-column gap (mockup `ipad/07b`'s 14 px).
        public static let bendGap: CGFloat = 14
        /// The jog module's normative total width: jog + two bend columns +
        /// two gaps.
        public static var jogModuleWidth: CGFloat {
            jogSize + 2 * bendColumnWidth + 2 * bendGap
        }
        /// The §41.9b mixer column width (mockup `07`'s `320px` — widened from
        /// M4's 268 so the two channel strips fit side by side).
        public static let mixerColumnWidth: CGFloat = 320
        /// The §41.9b normative deck column width (~416 pt; the mockup grid
        /// `1fr 320px 1fr`'s flexible fraction on a 1180 canvas is 406 pt after
        /// padding, and the 328 pt jog module fits both).
        public static let deckColumnWidth: CGFloat = 416
        /// The §41.9b tempo fader's column width on the deck's outer edge
        /// (rule 4). The fader rides beside the jog module: 416 − 328 − gap ≥
        /// this, so the pair fits the deck column.
        public static let tempoFaderWidth: CGFloat = 58
        /// The workspace's column gap and outer padding (mockup `07`'s 12 px).
        public static let columnGap: CGFloat = 12
        public static let outerPadding: CGFloat = 12

        /// A deck column's width on a `canvas`-wide workspace — the §41.9b
        /// grid `1fr 320px 1fr`. The jog module is a member of its deck column,
        /// so `jogModuleWidth ≤ deckColumnWidth` is what keeps it from ever
        /// reaching the mixer column (AT-TWIN-2).
        public static func deckColumnWidth(canvas: CGFloat) -> CGFloat {
            max(0, (canvas - 2 * outerPadding - mixerColumnWidth - 2 * columnGap) / 2)
        }
    }

    /// The §41.9b club arrangement's normative constants — the things the
    /// layout and the FR-TRANS-2 layout assertions pin down off-device:
    /// per-channel strip order, CUE-left-of-PLAY, the tempo fader's range, and
    /// the eight pads under their mode selector (rule 5).
    public enum ClubGeometry {
        /// §41.9b rule 1: the channel strip's reading order, top to bottom.
        public static let channelStripOrder: [String] =
            ["TRIM", "HI", "MID", "LOW", "FILTER", "FADER", "CUE"]
        /// §41.9b rule 3: CUE sits to the LEFT of PLAY at each deck's inner
        /// base, both ≥ 54 pt. Deck B mirrors horizontally (PLAY nearest the
        /// mixer on both decks — the inner thumb).
        public static let deckTransportOrder: [String] = ["CUE", "PLAY"]
        /// §41.9b rule 4: the tempo fader's range, ±8% — the §31.2 range
        /// "typical in beatmatching" (FR-ENG-6).
        public static let tempoFaderRange: ClosedRange<Double> = -0.08...0.08
        /// §41.9b rule 5: eight performance pads, two rows of four.
        public static let padColumns = 4
        public static let padRows = 2
        public static let padCount = padColumns * padRows
        /// §41.9b rule 5: the pad mode selector, immediately above the pads.
        public static let padModes: [String] = ["HOT CUE", "PAD FX", "BEAT JUMP", "SAMPLER"]
        /// §41.9b rule 7 / §35A: the beat-synced echo's beat lengths. The
        /// engine lands in commit 5.5; until then the Beat FX block renders the
        /// honest unavailable state (the stems convention).
        public static let echoBeats: [Double] = [0.25, 0.5, 1, 2, 4]
    }

    // MARK: - §35B transition → control mapping (AT-TRANS layout half, plan 5.5)

    /// The role a §35B transition needs from a performance surface. The table
    /// is the §35B five (rows) × their control sets (columns), encoded once so
    /// the AT-TRANS layout assertions and the transition coach (5.13) read the
    /// same mapping. `FR-TRANS-1` — all five performable on the default surface
    /// with no configuration — is asserted against these sets.
    public enum TransitionRole: String, CaseIterable, Sendable {
        case lowEQ
        case midEQ
        case highEQ
        case channelFader
        case phraseRibbon
        case filter
        case echo
        case crossfader
        case beatPhase
        case sharedWaveform
    }

    /// The §35B five, each with the controls that perform it (the normative
    /// mapping; "a transition is a test, not a mode").
    public static let transitionRoleSets: [(transition: String, roles: Set<TransitionRole>)] = [
        ("Bass Swap", [.lowEQ, .channelFader, .phraseRibbon]),
        ("Filter Transition", [.filter, .channelFader]),
        ("Echo Out", [.echo, .channelFader]),
        ("Fader Cut", [.crossfader]),
        ("Blend / Mix", [.channelFader, .lowEQ, .midEQ, .highEQ, .beatPhase, .sharedWaveform])
    ]

    /// The controls the §41.9b iPad surface keeps **always visible** — nothing
    /// a transition needs is behind a mode on the tablet (FR-TRANS-1/2).
    public static let tabletAlwaysVisibleRoles: Set<TransitionRole> =
        Set(TransitionRole.allCases)

    /// The controls the §42.7c compact surface keeps **always visible**, never
    /// in a drawer: the transferable core — crossfader, channel faders, edge
    /// filters, CUE-left-of-PLAY, jog, shared waveforms, and the **ECHO button**
    /// (Echo Out is a two-control transition, so echo and the fader must both
    /// be reachable without a drawer, §42.7c).
    public static let compactAlwaysVisibleRoles: Set<TransitionRole> = [
        .channelFader, .filter, .echo, .crossfader, .beatPhase,
        .sharedWaveform, .phraseRibbon
    ]

    /// The controls the compact surface reaches through the §42.7b momentary
    /// bank drawer (EQ — the spring-loading idiom makes Bass Swap performable:
    /// press, kill the low, release, drawer gone within one frame).
    public static let compactDrawerRoles: Set<TransitionRole> = [
        .lowEQ, .midEQ, .highEQ
    ]

    /// Everything the compact surface can reach — always-visible plus drawer.
    public static var compactReachableRoles: Set<TransitionRole> {
        compactAlwaysVisibleRoles.union(compactDrawerRoles)
    }

    // MARK: - §42.7c / §35A compact ECHO release-to-commit flyout

    /// The §42.7c compact **ECHO** treatment: a long-press flyout for beat
    /// length, depth and channel, using the same release-to-commit idiom as
    /// LOOP (§42.7b idiom 3). The flyout's geometry and release resolution are
    /// pure so the commit/cancel decision is pinned off-device — nothing
    /// changes on the way out, the engine is touched only on a release inside a
    /// commit target.
    public enum EchoFlyout {
        public static let beats: [Double] = ClubGeometry.echoBeats
        public static let width: CGFloat = 190
        public static let headerHeight: CGFloat = 24
        public static let topPadding: CGFloat = 6
        public static let channelChipWidth: CGFloat = 44
        public static let channelChipHeight: CGFloat = 26
        public static let channelGap: CGFloat = 6
        public static let beatsRowTop: CGFloat =
            headerHeight + topPadding + channelChipHeight + 6
        public static let chipWidth: CGFloat = 30
        public static let chipHeight: CGFloat = 28
        public static let chipGap: CGFloat = 5
        public static let depthTop: CGFloat = beatsRowTop + chipHeight + 8
        public static let depthHeight: CGFloat = 26
        public static let horizontalPadding: CGFloat = 8
        public static let bottomPadding: CGFloat = 8

        public static var height: CGFloat {
            depthTop + depthHeight + bottomPadding
        }

        /// The two channel chips (A/B) in the flyout's header row.
        public static func channelChipFrame(index: Int) -> CGRect {
            let total = 2 * channelChipWidth + channelGap
            let x0 = (width - total) / 2
            return CGRect(x: x0 + CGFloat(index) * (channelChipWidth + channelGap),
                          y: headerHeight + topPadding,
                          width: channelChipWidth, height: channelChipHeight)
        }

        /// A beat-length chip's frame, centred in the flyout.
        public static func chipFrame(index: Int) -> CGRect {
            let total = CGFloat(beats.count) * chipWidth
                + CGFloat(max(0, beats.count - 1)) * chipGap
            let x0 = (width - total) / 2
            return CGRect(x: x0 + CGFloat(index) * (chipWidth + chipGap),
                          y: beatsRowTop,
                          width: chipWidth, height: chipHeight)
        }

        /// The depth strip's frame (0 at its left edge … 1 at its right).
        public static func depthTrackFrame() -> CGRect {
            CGRect(x: horizontalPadding, y: depthTop,
                   width: width - 2 * horizontalPadding, height: depthHeight)
        }

        /// What a release point commits, `nil` when it slides out (nothing
        /// changes on the way out).
        public enum EchoAction: Equatable {
            /// `0` = deck A, `1` = deck B.
            case channel(Int)
            case beats(Double)
            case depth(Float)
        }

        /// Resolve a release point to the commit it lands on: the channel
        /// chips, a beat chip, the depth track, or `nil` outside all of them.
        public static func releasedAction(at point: CGPoint) -> EchoAction? {
            for index in 0..<2 where channelChipFrame(index: index).contains(point) {
                return .channel(index)
            }
            for (index, beats) in beats.enumerated() where chipFrame(index: index).contains(point) {
                return .beats(beats)
            }
            if depthTrackFrame().contains(point) {
                let track = depthTrackFrame()
                let t = min(1, max(0, (point.x - track.minX) / max(1, track.width)))
                return .depth(Float(t))
            }
            return nil
        }
    }
}
