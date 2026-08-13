import Combine
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
    private let store: EntitlementStore
    private let pump: TelemetryPump?
    private var telemetryTask: Task<Void, Never>?
    private var anyDeckPlaying = false

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
    @Published public var crossfader: Float = 0
    @Published public var crossfaderCurve: CrossfaderCurve = .constantPower

    public init(engine: any WorkspaceEngine,
                store: EntitlementStore,
                pump: TelemetryPump? = nil) {
        self.engine = engine
        self.store = store
        self.isPro = store.isPro
        // The pump's tick drives the engine's atomics → stream directly, so
        // the closure never captures `self` (a display link would otherwise
        // outlive the model during init).
        self.pump = pump ?? TelemetryPump { [weak engine] in engine?.pushTelemetry() }
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
}
