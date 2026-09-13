import Combine
import CoreGraphics
import Foundation
import TonearmCore

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
    let session: AudioSessionCoordinator?
    /// The §37.3 recording journal + recovery service (plan 5.11): the record
    /// toggle's `begin`/`finalize` write the `mix`/`mix_asset` rows, and
    /// `reconcile` runs on workspace appear to salvage crashed recordings.
    /// Injectable so the model's wiring is testable with a fake; nil in the
    /// model-level tests that predate the journal.
    let recordingService: (any RecordingJournaling)?
    /// The library → deck seam (plan 5.1, decision 16): the per-deck queues
    /// (§41.9c, FR-ENG-13) and the one gesture that loads a track to a deck
    /// through the FR-LIB-8 gate and the decode path. Injectable so the model's
    /// queue state and load forwarding are testable with a fake; the real
    /// `DeckLoader()` (defaults: core `LibraryStore.shared` +
    /// `DJLibraryStore.shared`) is resolved lazily so a model that never
    /// touches a queue costs no database I/O.
    public var library: any DeckLibraryServicing {
        injectedLibrary ?? DeckLoader()
    }
    private let injectedLibrary: (any DeckLibraryServicing)?
    let crateImporter: any PlaylistCrateImporting
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
    var loadedTrackIDs: [Deck: Int64] = [:]
    /// The thermal state the waveform models were last built under, so a
    /// crossing into/out of `.serious` rebuilds them (one level coarser,
    /// §26A.7).
    var lastWaveformThermal: WaveformThermal?
    private let pump: TelemetryPump?
    private var telemetryTask: Task<Void, Never>?
    private var anyDeckPlaying = false
    /// The §34A.4 session-response consumer (plan 5.11): flushes the recording
    /// segment on `.began`, opens a new one on `.ended` — never auto-plays.
    var interruptionTask: Task<Void, Never>?

    /// Where the per-deck module-slot / jog-mode choices are remembered
    /// (§41.9a, plan 4.11). Injectable so tests isolate the persistence.
    let defaults: UserDefaults
    /// How long a pinned bank drawer stays up without touch before it
    /// self-dismisses (§42.7b, AT-TWIN-3). Injectable so the model test runs
    /// fast instead of sleeping 12 s.
    let pinnedDrawerIdle: Duration
    var drawerIdleTask: Task<Void, Never>?
    /// The per-deck remembered bank the drawer springs to (§42.7b).
    var bankByDeck: [Deck: TwinBank] = [:]

    @Published public var telemetry = EngineTelemetry()
    @Published public private(set) var isPro: Bool

    /// Recording session state (plan 5.10, decision 14): `isRecording` mirrors
    /// whether the engine's tap + encoder are live, and `recordingElapsed` is
    /// the recorded duration in seconds. Session VM state, not a view's — the
    /// record/elapsed chip is shared across every performance surface.
    @Published public internal(set) var isRecording = false
    @Published public internal(set) var recordingElapsed: Double = 0

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
    var midiProfile: ControllerProfile?
    var midiTask: Task<Void, Never>?
    var midiAssemblerTask: Task<Void, Never>?
    /// The `HardwareService` backing the attached controller. Held so it
    /// outlives the assembly call that attached it (plan dj-midi-alpha M1) and
    /// is released on `detachMidi()`.
    var midiHardware: HardwareService?
    /// The router's pickup memory (plan dj-midi-alpha M2) — owned here, one per
    /// attachment, so a finger driving an action on the touchscreen can reset
    /// the physical control's claim on it.
    var midiTakeover = TakeoverState()
    var midiAssembler = MidiValueAssembler()
    /// True while a routed MIDI intent is being applied, so the touchscreen
    /// setters it goes through do not reset their own pickup claims.
    var isApplyingMidi = false
    /// Actions whose MIDI binding is awaiting pickup (M2): the UI shows a small
    /// catch indicator naming the control and which way to move it. `distance`
    /// is signed — positive = move down/left to catch.
    @Published public internal(set) var midiPendingPickup: [EngineAction: Float] = [:]

    // MARK: - Jog transports (plan dj-midi-alpha M3, FR-ENG-11)

    /// **One** transport per deck, owned by the model, so a finger nudge and a
    /// MIDI nudge share the same `bendBaseRate` bookkeeping — two transports
    /// would restore the wrong rate after a bend.
    private var jogTransportA: JogTransport?
    private var jogTransportB: JogTransport?
    /// The accumulated MIDI jog bend (relative-encoder deltas, clamped to the
    /// ring's ±16 % ceiling) and the per-deck idle-release tasks.
    var midiJogBend: [Deck: Double] = [:]
    var midiJogReleaseTasks: [Deck: Task<Void, Never>] = [:]
    /// Whether a jogTouch is currently held (the platter's touch sensor), and
    /// the accumulated scrub radians while held in vinyl mode.
    var midiJogHeld: [Deck: Bool] = [:]
    var midiJogRadians: [Deck: Double] = [:]

    /// The per-deck jog transport, created lazily on first use (finger or
    /// MIDI) so an idle surface costs nothing.
    func jogTransport(for deck: Deck) -> JogTransport {
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
    var recordingStartSample: Int64 = 0

    /// The finished mix the review listen opens from (FR-REC-6, plan 5.12):
    /// set when recording stops and the §37.3 journal finalizes, cleared by
    /// `dismissFinishedMix()` once the finish sheet is dismissed. The
    /// performance surfaces present `RecordingFinishView` off this.
    @Published public internal(set) var finishedMix: DJMix?
    /// The §37.4 timeline being accumulated while recording (plan 5.12): a deck
    /// starting to play logs "this track, on this deck, at this offset". Cleared
    /// when a recording starts, handed to `finalize` when it stops.
    var recordingTimeline = MixTimeline()
    /// The per-deck playing state the timeline's rising-edge detector reads.
    /// Reset when a recording starts so a deck already playing at record time
    /// logs its current track at ~0:00 (mockup `ipad/09`'s "0:00 … opened").
    var wasDeckAPlaying = false
    var wasDeckBPlaying = false
    /// The recorded transition gestures (dj-regression-suite §7, hook 5.11):
    /// control moves that the workspace recognises as a DJ Blakey transition,
    /// stamped with their recording-relative sample and handed to the journal
    /// at `finalize` so `verify-mix.py` can cross-check each claim against the
    /// audio. Reset when a recording starts. Only ever filled while recording.
    var transitionEvents: [RecordingJournalEvent] = []

    /// Each deck's §26A render model — the analysis-driven waveform. `nil`
    /// until the deck loads an analysed track, or for an unanalysed track
    /// (the honest empty state, §26A.1). Built off the main actor when the
    /// track loads and when the thermal state crosses the §26A.7 shed.
    @Published public internal(set) var waveformA: WaveformRenderModel?
    @Published public internal(set) var waveformB: WaveformRenderModel?

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
    @Published public internal(set) var stemStatusA: DeckStemStatus = .unavailable
    @Published public internal(set) var stemStatusB: DeckStemStatus = .unavailable
    /// The per-deck stem controls — the four voices' gains and the mute/solo
    /// sets, mirrored here like the mixer knobs so every surface reads and
    /// writes the same session state. Forwarding is clamped and never touches
    /// the engine when the deck's stems are not prepared.
    @Published public internal(set) var stemControlsA = StemControlState()
    @Published public internal(set) var stemControlsB = StemControlState()

    /// The iPad module slot each deck occupies (§41.9a) — the per-deck
    /// remembered `JOG · STEMS · PADS · FX` choice, **default `STEMS`** so §41.9
    /// is what an existing user sees unless they ask for something else. The
    /// published values let the slot's seg highlight follow the selection.
    @Published public internal(set) var moduleSlotA: DeckModuleSlot
    @Published public internal(set) var moduleSlotB: DeckModuleSlot
    /// The per-deck jog platter action (§41.9a): vinyl (scratch) or CDJ
    /// (nudge), shown inside the platter so the mode is never a guess.
    @Published public internal(set) var jogModeA: JogGestureModel.JogMode
    @Published public internal(set) var jogModeB: JogGestureModel.JogMode
    /// The per-deck jog sensitivity, 0.5–2.0 (§40.7.4) — the mixer column's
    /// faders own these (§41.9a). Session state like the mixer controls.
    @Published public var jogSensitivityA: Double = 1.0
    @Published public var jogSensitivityB: Double = 1.0

    /// The selectable per-deck queues (§41.9c): the whole library plus every
    /// saved playlist. Refresh via `refreshDeckQueues()`.
    @Published public internal(set) var availableQueues: [DeckQueueSource] = []
    /// Deck A's queue — its source and rows (FR-ENG-13: the two decks may point
    /// at **different** sources at once).
    @Published public internal(set) var queueA = DeckQueue(source: .allTracks, rows: [])
    /// Deck B's queue.
    @Published public internal(set) var queueB = DeckQueue(source: .allTracks, rows: [])
    @Published public internal(set) var importedCrateA: DeckQueueSource?
    @Published public internal(set) var importedCrateB: DeckQueueSource?
    @Published public internal(set) var crateImportError: String?
    @Published public internal(set) var isImportingCrate = false
    /// The per-deck load state of the `load(_:trackID:)` one-gesture path —
    /// idle / loading / loaded, or the honest FR-LIB-8 refusal or decode
    /// failure as a message. View-only readers render it, never block on it.
    @Published public internal(set) var loadStateA: DeckLoadState = .idle
    @Published public internal(set) var loadStateB: DeckLoadState = .idle
    /// The §12.2 ownership-transfer boxes: the model keeps each deck's decoded
    /// PCM alive until the deck is reloaded. Dropping the box on reload frees
    /// the previous source — the offline harness is synchronous, so the engine
    /// has already retired it.
    var sourceBoxes: [Deck: DeckSourceBox] = [:]
    /// The §12.2 ownership-transfer boxes for armed stem sets: the model keeps
    /// each deck's prepared set alive until the deck reloads. Dropping the box
    /// disarms nothing by itself — `resolveStems` disarms first.
    var stemSetBoxes: [Deck: StemSetBox] = [:]

    // MARK: - Properties whose methods live in extension files
    //
    // Swift extensions cannot declare stored instance properties, so every
    // stored property touched by a method in WorkspaceModel+*.swift must be
    // declared here in the primary type, even though its behavior lives
    // elsewhere. Access is bumped from `private` to `internal` (and
    // `private(set)` to `internal(set)`) only where a same-module extension
    // file genuinely needs it — the public API of `WorkspaceModel` itself is
    // unchanged.

    /// §26A.3's gesture-detection state (see WorkspaceModel+Recording.swift).
    var gestures: [String: (origin: Float, touched: Date, fired: Bool)] = [:]
    /// The Filter Transition's engaged/bypass latch, per deck (see
    /// WorkspaceModel+Recording.swift).
    var filterEngagedA = false
    var filterEngagedB = false

    /// §44.2a cue-monitoring state (see WorkspaceModel+Mixer.swift).
    @Published public internal(set) var cueMode: CueMode = .off
    @Published public internal(set) var cuedDecks: Set<Deck> = []
    @Published public internal(set) var outputChannelCount: Int = 2

    /// §42.1 compact-posture state (see WorkspaceModel+CompactPosture.swift).
    @Published public var focusedDeck: Deck = .a
    @Published public internal(set) var isCrateSheetPresented = false
    @Published public var compactPosture: CompactPosture = .solo
    /// §42.7b momentary drawer state (see WorkspaceModel+CompactPosture.swift).
    @Published public internal(set) var drawerState: DrawerState = .idle

    /// `Deck` → the short id used in the recording journal (shared by
    /// WorkspaceModel+Recording.swift, +Mixer.swift and +Library.swift).
    func deckID(_ deck: Deck) -> String {
        deck == .a ? "a" : "b"
    }

    /// `Deck` → the MIDI vocabulary's `EngineAction.DeckID` (same two decks,
    /// two type systems; M2's pickup resets need the action type). Shared by
    /// WorkspaceModel+Mixer.swift and +Library.swift.
    func midiDeckID(_ deck: Deck) -> EngineAction.DeckID {
        deck == .a ? .a : .b
    }

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
    private func recordTimelineEvent(for deck: Deck) {
        guard let trackID = loadedTrackIDs[deck] else { return }
        recordingTimeline.record(trackID: trackID,
                                 deck: deck == .a ? "A" : "B",
                                 startOffsetSec: recordingElapsed)
    }

    // MARK: - Transport / loading

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
