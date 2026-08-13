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
    func sampleTelemetry() -> EngineTelemetry
    func pushTelemetry()
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
    private let pump: TelemetryPump?
    private var telemetryTask: Task<Void, Never>?
    private var anyDeckPlaying = false

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

    public init(engine: any WorkspaceEngine,
                store: EntitlementStore,
                pump: TelemetryPump? = nil,
                pinnedDrawerIdle: Duration = .seconds(12),
                defaults: UserDefaults = .standard,
                library: (any DeckLibraryServicing)? = nil) {
        self.engine = engine
        self.store = store
        self.injectedLibrary = library
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
    /// The view calls this on appear and `end()` on disappear.
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
    }

    public func end() {
        telemetryTask?.cancel()
        telemetryTask = nil
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

    private func apply(_ value: EngineTelemetry) {
        telemetry = value
        let playing = value.deckA.playing || value.deckB.playing
        if playing != anyDeckPlaying {
            anyDeckPlaying = playing
            IdleTimerScope.update(anyDeckPlaying: playing)
        }
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

    /// The deck's current load state — the crate rows render it.
    public func loadState(for deck: PerformanceEngine.Deck) -> DeckLoadState {
        deck == .a ? loadStateA : loadStateB
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
    /// touched **only** on a successful load.
    public func load(_ deck: PerformanceEngine.Deck, trackID: Int64) async {
        setLoadState(.loading(trackID: trackID), for: deck)
        switch await library.load(trackID: trackID) {
        case .loaded(let box):
            engine.load(deck, source: box.source)
            sourceBoxes[deck] = box
            setLoadState(.loaded(trackID: trackID), for: deck)
        case .refused(let readiness):
            let reason = Self.unavailableReason(readiness)
            setLoadState(.refused(trackID: trackID, reason: reason), for: deck)
        case .failed(let failure):
            setLoadState(.failed(trackID: trackID, message: failure.message), for: deck)
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
        engine.setEQKnobs(deck, low: low, mid: mid, high: high)
        switch deck {
        case .a:
            eqALow = low; eqAMid = mid; eqAHigh = high
        case .b:
            eqBLow = low; eqBMid = mid; eqBHigh = high
        }
    }

    public func setFilter(_ deck: PerformanceEngine.Deck, knob: Float) {
        engine.setFilter(deck, knob: knob)
        switch deck {
        case .a: filterA = knob
        case .b: filterB = knob
        }
    }

    public func setChannelFader(_ deck: PerformanceEngine.Deck, gain: Float) {
        engine.setChannelFader(deck, gain: gain)
        switch deck {
        case .a: channelA = gain
        case .b: channelB = gain
        }
    }

    public func setCrossfader(_ position: Float, curve: CrossfaderCurve) {
        engine.setCrossfader(position, curve: curve)
        crossfader = position
        crossfaderCurve = curve
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

    /// §41.9a's module geometry. The jog module is the widest module — a 248 pt
    /// jog flanked by the ± pitch-bend columns — and must fit its deck column
    /// without pushing into the mixer column (AT-TWIN-2: a module never
    /// occludes shared controls; it is a layout member of its own column, not
    /// an overlay).
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
        /// The §41.9a mixer column width (the iPad centre column, mockup `07`).
        public static let mixerColumnWidth: CGFloat = 268
        /// The workspace's column gap and outer padding (mockup `07`'s 12 px).
        public static let columnGap: CGFloat = 12
        public static let outerPadding: CGFloat = 12

        /// A deck column's width on a `canvas`-wide workspace — the §41.9
        /// grid `1fr 268px 1fr`. The module slot is a member of its deck
        /// column, so `jogModuleWidth ≤ deckColumnWidth` is what keeps the jog
        /// module from ever reaching the mixer column (AT-TWIN-2).
        public static func deckColumnWidth(canvas: CGFloat) -> CGFloat {
            max(0, (canvas - 2 * outerPadding - mixerColumnWidth - 2 * columnGap) / 2)
        }
    }
}
