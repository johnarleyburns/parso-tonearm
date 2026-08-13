import XCTest
@testable import TonearmCore
@testable import TonearmDJ

/// Commit 4.6 — `WorkspaceModel`, the single session VM over the workspace
/// surface (plan 4.6, §41.9). The engine seam is `WorkspaceEngine`; tests
/// inject a recording fake so the model's states, gate and forwarding are
/// exercised deterministically (§47.2), and one end-to-end test drives the
/// atomics → `AsyncStream` telemetry pipeline through a real offline engine.
@MainActor
final class WorkspaceModelTests: XCTestCase {

    private final class FakeWorkspaceEngine: WorkspaceEngine {
        private let stream = EngineTelemetryStream()
        var telemetry: AsyncStream<EngineTelemetry> { stream.stream }
        var current = EngineTelemetry()
        var masterSample: Int64 { current.masterSample }
        var bufferPeriodMillis: Double = 85.3
        var limiterCeiling: Float?
        var sampleRate: Double = 48_000

        private(set) var started = false
        private(set) var stopped = false
        private(set) var played: [PerformanceEngine.Deck] = []
        private(set) var paused: [PerformanceEngine.Deck] = []
        private(set) var synced: [(deck: PerformanceEngine.Deck,
                                   master: PerformanceEngine.Deck,
                                   barSync: Bool)] = []
        private(set) var unsynced: [PerformanceEngine.Deck] = []
        private(set) var eqKnobs: [PerformanceEngine.Deck: (low: Float, mid: Float, high: Float)] = [:]
        private var syncedState: [PerformanceEngine.Deck: Bool] = [:]
        private(set) var rates: [PerformanceEngine.Deck: Double] = [:]

        func start() throws { started = true }
        func stop() { stopped = true }
        func load(_ deck: PerformanceEngine.Deck, source: DeckSource) {}
        func play(_ deck: PerformanceEngine.Deck) { played.append(deck) }
        func pause(_ deck: PerformanceEngine.Deck) { paused.append(deck) }
        func cue(_ deck: PerformanceEngine.Deck) {}
        func releaseCue(_ deck: PerformanceEngine.Deck) {}
        func seek(_ deck: PerformanceEngine.Deck, toSample: Int64, quantized: Bool) {}
        func setCue(_ deck: PerformanceEngine.Deck, atSample: Int64) {}
        func triggerHotCue(_ deck: PerformanceEngine.Deck, atSample: Int64) {}
        func setLoopRange(_ deck: PerformanceEngine.Deck, start: Int64, end: Int64) {}
        func setLoop(_ deck: PerformanceEngine.Deck, beats: Double) {}
        func exitLoop(_ deck: PerformanceEngine.Deck) {}
        func setQuantize(_ on: Bool, resolution: QuantizeResolution) {}
        func setRate(_ deck: PerformanceEngine.Deck, rate: Float) {}
        func setKeyLock(_ deck: PerformanceEngine.Deck, locked: Bool) {}
        func setKeyShift(_ deck: PerformanceEngine.Deck, semitones: Float) {}
        func sync(_ deck: PerformanceEngine.Deck, to master: PerformanceEngine.Deck, barSync: Bool) {
            synced.append((deck, master, barSync))
            syncedState[deck] = true
        }
        func unsync(_ deck: PerformanceEngine.Deck) {
            unsynced.append(deck)
            syncedState[deck] = false
        }
        func isSynced(_ deck: PerformanceEngine.Deck) -> Bool { syncedState[deck] ?? false }
        func deckRate(_ deck: PerformanceEngine.Deck) -> Double { rates[deck] ?? 1.0 }
        func setEQKnobs(_ deck: PerformanceEngine.Deck, low: Float, mid: Float, high: Float) {
            eqKnobs[deck] = (low, mid, high)
        }
        func setFilter(_ deck: PerformanceEngine.Deck, knob: Float) {}
        func setChannelFader(_ deck: PerformanceEngine.Deck, gain: Float) {}
        func setCrossfader(_ position: Float, curve: CrossfaderCurve) {}
        func sampleTelemetry() -> EngineTelemetry { current }
        func pushTelemetry() { stream.push(current) }
    }

    private struct EmptyEntitlementSource: EntitlementSource {
        func currentTransactions() async throws -> [TransactionFact] { [] }
        func transactionUpdates() -> AsyncStream<TransactionFact> { AsyncStream { _ in } }
    }

    private func makeStore(isPro: Bool) -> EntitlementStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceModelTests-\(UUID().uuidString)", isDirectory: true)
        let cacheURL = dir.appendingPathComponent("entitlement-cache.json")
        EntitlementCacheStore(fileURL: cacheURL).save(
            EntitlementCache(isPro: isPro, source: isPro ? .purchased : .none, timestamp: Date()))
        return EntitlementStore(entitlementSource: EmptyEntitlementSource(),
                                cacheStore: EntitlementCacheStore(fileURL: cacheURL))
    }

    // MARK: - Gate (App. T.3, §40.4)

    func testGateLocksTheWorkspaceForFreeUsers() {
        let model = WorkspaceModel(engine: FakeWorkspaceEngine(), store: makeStore(isPro: false))
        XCTAssertFalse(model.isDecksEnabled, "a free user sees the real, dimmed surface with a lock chip")
        XCTAssertFalse(model.isPro)
    }

    func testGateOpensTheWorkspaceForProUsers() {
        let model = WorkspaceModel(engine: FakeWorkspaceEngine(), store: makeStore(isPro: true))
        XCTAssertTrue(model.isDecksEnabled, "Pro users get the decks (§41.15)")
        XCTAssertTrue(model.isPro)
    }

    // MARK: - Lifecycle

    func testBeginStartsEngineAndEndStopsIt() throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)
        XCTAssertFalse(fake.started)
        try model.begin()
        XCTAssertTrue(fake.started, "begin() starts the engine behind the surface")
        model.end()
        XCTAssertTrue(fake.stopped, "end() stops the engine when the workspace disappears")
    }

    // MARK: - Transport / sync forwarding

    func testTransportForwardsToTheEngine() throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)
        try model.begin()
        defer { model.end() }

        model.play(.a)
        model.pause(.a)
        XCTAssertEqual(fake.played, [.a])
        XCTAssertEqual(fake.paused, [.a])
    }

    func testSyncForwardsWithBarOptionAndUnsync() throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)
        try model.begin()
        defer { model.end() }

        model.sync(.b, to: .a, barSync: true)
        XCTAssertEqual(fake.synced.count, 1)
        XCTAssertEqual(fake.synced[0].deck, .b)
        XCTAssertEqual(fake.synced[0].master, .a)
        XCTAssertTrue(fake.synced[0].barSync, "hold-SYNC is the downbeat path (§32.2)")
        XCTAssertTrue(model.isSynced(.b))

        model.unsync(.b)
        XCTAssertEqual(fake.unsynced, [.b])
        XCTAssertFalse(model.isSynced(.b))
    }

    func testEQStateMirrorsTheEngine() throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)
        try model.begin()
        defer { model.end() }

        model.setEQKnobs(.a, low: -1, mid: 0, high: 1)
        XCTAssertEqual(fake.eqKnobs[.a]?.low, -1)
        XCTAssertEqual(fake.eqKnobs[.a]?.mid, 0)
        XCTAssertEqual(fake.eqKnobs[.a]?.high, 1)
        XCTAssertEqual(model.eqALow, -1, "the shared VM owns the knob positions, not a view's lifetime")
        XCTAssertEqual(model.eqAHigh, 1)
        XCTAssertEqual(model.eqBLow, 0, "deck B's EQ is untouched")
    }

    func testChannelFaderStateMirrorsTheEngine() throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)
        try model.begin()
        defer { model.end() }

        XCTAssertEqual(model.channelA, 1.0, "an untouched channel fader sits at unity (§35.4)")
        XCTAssertEqual(model.channelB, 1.0)

        model.setChannelFader(.a, gain: 0.6)
        model.setChannelFader(.b, gain: 0.4)
        XCTAssertEqual(model.channelA, 0.6, "the twin mixer column's fader state lives in the shared VM")
        XCTAssertEqual(model.channelB, 0.4)
    }

    // MARK: - Telemetry pipeline (§40.3)

    func testTelemetryStreamDeliversPumpedValues() async throws {
        let fake = FakeWorkspaceEngine()
        fake.current = EngineTelemetry(
            masterSample: 1234,
            masterBPM: 124,
            downbeatPhase: 0.5,
            deckA: EngineTelemetry.Deck(playheadSample: 500, bpmEffective: 124,
                                        phase: 0.25, level: 0.4, playing: true, synced: false),
            deckB: EngineTelemetry.Deck(playheadSample: 88_000, bpmEffective: 124,
                                        phase: 0.75, level: 0.1, playing: true, synced: true),
            masterLevel: 0.3,
            renderLoad: 0.21)

        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)
        try model.begin()
        defer { model.end() }

        // Let the model's telemetry task reach its `for await` before the first
        // push — an AsyncStream drops a value yielded before any subscriber.
        for _ in 0..<50 { await Task.yield() }
        model.pumpTelemetryNow()
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(model.telemetry.masterSample, 1234)
        XCTAssertEqual(model.telemetry.deckA.playheadSample, 500)
        XCTAssertEqual(model.telemetry.deckA.bpmEffective, 124, accuracy: 1e-9)
        XCTAssertEqual(model.telemetry.deckA.phase, 0.25, accuracy: 1e-9)
        XCTAssertEqual(model.telemetry.deckB.synced, true)
        XCTAssertEqual(model.telemetry.renderLoad, 0.21, accuracy: 1e-9)
    }

    func testRealOfflineEngineSamplesPublishedAtomics() async throws {
        // The model against the §2.5 offline harness: the atomics → telemetry
        // pipeline reads real render output, not a fake's canned value.
        let engine = try PerformanceEngine(configuration: .init(sampleRate: 48_000,
                                                                channelCount: 1,
                                                                ringCapacity: 16))
        let store = makeStore(isPro: true)
        let model = WorkspaceModel(engine: engine, store: store, pump: nil)
        try model.begin()
        defer { model.end() }

        let buffer = OfflineSource(frames: 20_000)
        model.load(.a, source: buffer.source)
        model.play(.a)
        _ = try engine.renderMono(1024)

        for _ in 0..<50 { await Task.yield() }
        model.pumpTelemetryNow()
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(model.telemetry.masterSample, 1024)
        XCTAssertEqual(model.telemetry.deckA.playheadSample, 1024, "frame-exact playhead telemetry")
        XCTAssertEqual(model.telemetry.deckA.bpmEffective, 120, accuracy: 1e-6,
                       "default grid is 120 BPM at unity rate")
        XCTAssertTrue(model.telemetry.deckA.playing)
        XCTAssertFalse(model.telemetry.deckA.synced)
        XCTAssertEqual(model.telemetry.masterBPM, 120, accuracy: 1e-6, "the master clock snapshot")
        XCTAssertEqual(model.telemetry.masterSample, 1024)
    }

    // MARK: - Compact posture (§42.1, §42.6–42.7)

    func testFocusSwapIsViewOnly() throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)
        try model.begin()
        defer { model.end() }

        XCTAssertEqual(model.focusedDeck, .a, "deck A starts in focus")
        model.swapFocus()
        XCTAssertEqual(model.focusedDeck, .b)
        model.swapFocus()
        XCTAssertEqual(model.focusedDeck, .a)

        XCTAssertTrue(fake.played.isEmpty, "swapping focus must not touch transport (FR-ENG-10)")
        XCTAssertTrue(fake.paused.isEmpty)
        XCTAssertTrue(fake.synced.isEmpty)
        XCTAssertTrue(fake.unsynced.isEmpty)
        XCTAssertTrue(fake.eqKnobs.isEmpty, "swapping focus must not touch the mixer")
        XCTAssertEqual(model.telemetry, EngineTelemetry(), "telemetry is untouched by a view-only swap")
        XCTAssertFalse(fake.stopped, "the engine keeps running behind the swap — both decks stay live")
    }

    func testCrateSheetNeverCoversTheCrossfaderBar() throws {
        // §42.7: the browse-while-performing sheet may never cover the
        // crossfader. Assert the pure bound over a spread of container
        // heights — the view consumes exactly this rule.
        for container in stride(from: CGFloat(400), through: CGFloat(1000), by: CGFloat(25)) {
            let maxHeight = WorkspaceModel.crateSheetMaxHeight(containerHeight: container)
            XCTAssertGreaterThanOrEqual(maxHeight, 0,
                "sheet height stays non-negative at container \(container)")
            XCTAssertLessThanOrEqual(maxHeight + WorkspaceModel.crossfaderBarHeight, container,
                "the sheet bottom stays above the crossfader bar at container \(container)")
            XCTAssertLessThanOrEqual(maxHeight, container * 0.6 + 0.001,
                "the sheet is ~60% of the container (mockup `iphone/05b`) at \(container)")
        }
    }

    func testCrateSheetPresentationChangesNoEngineState() throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)
        try model.begin()
        defer { model.end() }

        XCTAssertFalse(model.isCrateSheetPresented)
        model.raiseCrateSheet()
        XCTAssertTrue(model.isCrateSheetPresented)
        model.dismissCrateSheet()
        XCTAssertFalse(model.isCrateSheetPresented)

        XCTAssertTrue(fake.played.isEmpty, "raising the crate sheet changes no engine state")
        XCTAssertTrue(fake.paused.isEmpty)
        XCTAssertEqual(model.focusedDeck, .a, "the sheet does not disturb focus")
    }

    // MARK: - Orientation switch (§42.1, plan 4.9)

    func testRotationIsViewOnly() throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)
        try model.begin()
        defer { model.end() }

        XCTAssertEqual(model.compactPosture, .solo, "portrait is the default posture")
        model.setPosture(.twin)
        XCTAssertEqual(model.compactPosture, .twin)
        model.setPosture(.solo)
        XCTAssertEqual(model.compactPosture, .solo)

        XCTAssertTrue(fake.played.isEmpty, "rotating must not touch transport (FR-ENG-10, AT-TWIN-1)")
        XCTAssertTrue(fake.paused.isEmpty)
        XCTAssertTrue(fake.synced.isEmpty)
        XCTAssertTrue(fake.unsynced.isEmpty)
        XCTAssertTrue(fake.eqKnobs.isEmpty, "rotating must not touch the mixer")
        XCTAssertEqual(model.telemetry, EngineTelemetry(), "telemetry is untouched by a view-only rotation")
        XCTAssertFalse(fake.stopped, "the engine keeps running behind the swap — both decks stay live")
    }

    func testRotationPreservesTransportExactly() async throws {
        // AT-TWIN-1: rotating mid-playback changes **no** engine state. With a
        // deck already playing, a posture swap must leave the engine's call
        // record and the model's telemetry untouched — the swap is the same
        // WorkspaceModel re-rendered, nothing else.
        let fake = FakeWorkspaceEngine()
        fake.current = EngineTelemetry(
            masterSample: 9600,
            masterBPM: 124,
            downbeatPhase: 0.5,
            deckA: EngineTelemetry.Deck(playheadSample: 9600, bpmEffective: 124,
                                        phase: 0.25, level: 0.5, playing: true, synced: false),
            deckB: EngineTelemetry.Deck(playheadSample: 0, bpmEffective: 124,
                                        phase: 0.25, level: 0, playing: false, synced: false),
            masterLevel: 0.5,
            renderLoad: 0.2)
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)
        try model.begin()
        defer { model.end() }
        for _ in 0..<50 { await Task.yield() }
        model.pumpTelemetryNow()
        for _ in 0..<50 { await Task.yield() }

        model.play(.a)
        XCTAssertEqual(fake.played, [.a])

        model.setPosture(.twin)
        model.setPosture(.solo)

        XCTAssertEqual(fake.played, [.a], "rotation adds no transport calls")
        XCTAssertTrue(fake.paused.isEmpty)
        XCTAssertEqual(model.telemetry.deckA.playheadSample, 9600,
                       "the playhead readout is preserved across the rotation")
        XCTAssertEqual(model.telemetry.deckA.playing, true)
        XCTAssertFalse(fake.stopped, "rotation never stop/starts the engine")
    }

    func testBeatPhaseErrorMath() {
        // Pure golden cases for the mixer column's signed phase-error readout.
        XCTAssertEqual(WorkspaceModel.beatPhaseError(phaseA: 0.25, phaseB: 0.25), 0,
                       "equal phases are locked")
        XCTAssertEqual(WorkspaceModel.beatPhaseError(phaseA: 0.6, phaseB: 0.2), 0.4,
                       accuracy: 1e-12, "A ahead by 0.4 beat")
        XCTAssertEqual(WorkspaceModel.beatPhaseError(phaseA: 0.2, phaseB: 0.6), -0.4,
                       accuracy: 1e-12, "B ahead reads negative")
        XCTAssertEqual(WorkspaceModel.beatPhaseError(phaseA: 0.9, phaseB: 0.1), -0.2,
                       accuracy: 1e-12, "wrap-around takes the minimal circular distance")
        XCTAssertEqual(WorkspaceModel.beatPhaseError(phaseA: 0.1, phaseB: 0.9), 0.2,
                       accuracy: 1e-12, "signed the other way across the wrap")
        XCTAssertEqual(WorkspaceModel.beatPhaseError(phaseA: 0.0, phaseB: 1.0), 0.0,
                       accuracy: 1e-12, "a full beat apart is locked on the circle")
    }

    func testBeatPhaseErrorMillisMath() {
        XCTAssertEqual(WorkspaceModel.beatPhaseErrorMillis(error: 0.1, bpm: 120),
                       50, accuracy: 1e-9, "0.1 beat at 120 BPM = 0.1 × 500 ms = 50 ms")
        XCTAssertEqual(WorkspaceModel.beatPhaseErrorMillis(error: -0.1, bpm: 120),
                       -50, accuracy: 1e-9, "signed")
        XCTAssertEqual(WorkspaceModel.beatPhaseErrorMillis(error: 0.0, bpm: 124),
                       0, "locked is 0 ms")
        XCTAssertEqual(WorkspaceModel.beatPhaseErrorMillis(error: 0.25, bpm: 60),
                       250, accuracy: 1e-9, "0.25 beat at 60 BPM = 250 ms")
        XCTAssertEqual(WorkspaceModel.beatPhaseErrorMillis(error: 0.1, bpm: 0),
                       0, "no master clock reads 0")
    }

    func testTwinGeometryMatchesTheSpecBudget() {
        // §42.7a verbatim: 734 = 30 │ 168 jog A │ 6 │ 54 transport │ 8 │ 202
        // mixer │ 8 │ 54 transport │ 6 │ 168 jog B │ 30. The twin view consumes
        // exactly these constants, so the frames are pinned here off-device.
        let leftDeck = WorkspaceModel.TwinGeometry.outerMargin
            + WorkspaceModel.TwinGeometry.jogWidth
            + WorkspaceModel.TwinGeometry.jogTransportGap
            + WorkspaceModel.TwinGeometry.transportWidth
        let rightDeck = WorkspaceModel.TwinGeometry.transportWidth
            + WorkspaceModel.TwinGeometry.jogTransportGap
            + WorkspaceModel.TwinGeometry.jogWidth
            + WorkspaceModel.TwinGeometry.outerMargin
        let total = leftDeck
            + WorkspaceModel.TwinGeometry.columnGap
            + WorkspaceModel.TwinGeometry.mixerColumnWidth
            + WorkspaceModel.TwinGeometry.columnGap
            + rightDeck

        XCTAssertEqual(WorkspaceModel.TwinGeometry.deckColumnWidth, 228,
                       "jog 168 + 6 + transport 54")
        XCTAssertEqual(WorkspaceModel.TwinGeometry.mixerColumnWidth, 202)
        XCTAssertEqual(total, WorkspaceModel.TwinGeometry.usableWidth,
                       "the budget sums to the 734 pt usable width")
        XCTAssertEqual(WorkspaceModel.TwinGeometry.jogWidth + WorkspaceModel.TwinGeometry.jogTransportGap
                       + WorkspaceModel.TwinGeometry.transportWidth,
                       WorkspaceModel.TwinGeometry.deckColumnWidth,
                       "a deck column decomposes exactly")
    }

    // MARK: - Momentary bank drawer (§42.7b, plan 4.10)

    func testSpringReleaseRestoresTheJogInOneFrame() throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)
        try model.begin()
        defer { model.end() }

        model.springDrawer(deck: .a)
        XCTAssertEqual(model.drawerState, .spring(deck: .a, bank: .eq),
                       "holding deck A's tab springs the drawer over its jog + transport")

        // Releasing is a synchronous state transition: the drawer disappears
        // in the very next frame and the jog is back under the thumb
        // (AT-TWIN-3).
        model.releaseDrawer()
        XCTAssertEqual(model.drawerState, .idle,
                       "a held drawer can never leave the surface in a forgotten mode")
        XCTAssertTrue(fake.played.isEmpty && fake.paused.isEmpty && fake.synced.isEmpty,
                      "springing and releasing are view-only — no engine call")
        XCTAssertEqual(model.telemetry, EngineTelemetry(), "telemetry is untouched")
    }

    func testPinnedDrawerSelfDismissesAfterIdle() async throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil,
                                   pinnedDrawerIdle: .milliseconds(60))
        try model.begin()
        defer { model.end() }

        model.springDrawer(deck: .a)
        model.pinDrawer()
        XCTAssertEqual(model.drawerState, .pinned(deck: .a, bank: .eq))

        for _ in 0..<250 {
            if model.drawerState == .idle { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.drawerState, .idle,
                       "a pinned drawer self-dismisses after the idle period (AT-TWIN-3)")
        XCTAssertFalse(fake.stopped, "the self-dismiss is view-only — the engine keeps playing")
    }

    func testPinnedDrawerDoesNotDismissBeforeIdle() async throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil,
                                   pinnedDrawerIdle: .milliseconds(400))
        try model.begin()
        defer { model.end() }

        model.springDrawer(deck: .b)
        model.pinDrawer()
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.drawerState, .pinned(deck: .b, bank: .eq),
                       "well before the idle period the pinned drawer stays up")
    }

    func testTouchInsidePinnedDrawerResetsItsIdleClock() async throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil,
                                   pinnedDrawerIdle: .milliseconds(200))
        try model.begin()
        defer { model.end() }

        model.springDrawer(deck: .a)
        model.pinDrawer()

        // Keep touching inside the drawer past its 200 ms idle — each touch
        // re-arms the clock, so it stays pinned (§42.7b's "12 s of no touch").
        for _ in 0..<6 {
            try await Task.sleep(for: .milliseconds(50))
            model.noteDrawerActivity()
        }
        XCTAssertEqual(model.drawerState, .pinned(deck: .a, bank: .eq),
                       "touch inside the pinned drawer keeps it up past the idle period")

        for _ in 0..<80 {
            if model.drawerState == .idle { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.drawerState, .idle,
                       "once the touch stops, the idle self-dismiss fires (AT-TWIN-3)")
    }

    func testSpringReleasePinsOnShortPressOnly() {
        // §42.7b spring-loading discrimination: a press shorter than the tap
        // threshold is a *tap* (pins the bank for hands-free work); a longer
        // hold that is released is a *peek* (dismisses, restoring the jog).
        XCTAssertTrue(WorkspaceModel.springReleasePins(holdDuration: 0.1))
        XCTAssertTrue(WorkspaceModel.springReleasePins(holdDuration: 0.34))
        XCTAssertFalse(WorkspaceModel.springReleasePins(holdDuration: 0.36))
        XCTAssertFalse(WorkspaceModel.springReleasePins(holdDuration: 1.0))
        XCTAssertFalse(WorkspaceModel.springReleasePins(holdDuration: 0.35),
                       "at the threshold it is a tap — strictly shorter than")
        XCTAssertEqual(WorkspaceModel.DrawerGeometry.tapThreshold, 0.35, accuracy: 1e-9)
    }

    func testDrawerNeverCoversSharedControls() {
        // §42.7b rule 1 + FR-ENG-12 / AT-TWIN-2: the drawer is exactly one deck
        // column wide over that deck's jog + transport — it structurally cannot
        // reach the mixer column, either waveform, the beat-phase meter or the
        // opposite deck's jog.
        XCTAssertEqual(WorkspaceModel.DrawerGeometry.width,
                       WorkspaceModel.TwinGeometry.deckColumnWidth,
                       "a drawer is exactly one deck column wide (228 pt)")
        XCTAssertEqual(WorkspaceModel.DrawerGeometry.height, 206,
                       "the drawer spans the control band only")

        let drawerA = WorkspaceModel.drawerXRange(deck: .a)
        let drawerB = WorkspaceModel.drawerXRange(deck: .b)
        let mixer = WorkspaceModel.mixerXRange

        XCTAssertLessThanOrEqual(drawerA.upperBound, mixer.lowerBound,
                                 "deck A's drawer never reaches the mixer column")
        XCTAssertGreaterThanOrEqual(drawerB.lowerBound, mixer.upperBound,
                                    "deck B's drawer never reaches the mixer column")
        XCTAssertLessThanOrEqual(drawerA.upperBound, drawerB.lowerBound,
                                 "a drawer never reaches the opposite deck")
        XCTAssertLessThanOrEqual(drawerB.upperBound, WorkspaceModel.TwinGeometry.usableWidth,
                                 "the drawer fits the usable width")

        // §42.7b rule 2: the screen-edge filter slider is never occluded — its
        // outer 24 pt sits entirely inside the dead band, and the drawer's
        // nearest edge is the dead band + the §42.7a outer margin beyond it.
        XCTAssertGreaterThanOrEqual(WorkspaceModel.DrawerGeometry.deadBandInset,
                                    WorkspaceModel.DrawerGeometry.edgeSliderWidth,
                                    "the edge slider's 24 pt fits the 59 pt dead band")
        XCTAssertLessThan(WorkspaceModel.DrawerGeometry.edgeSliderWidth,
                          WorkspaceModel.DrawerGeometry.deadBandInset
                              + WorkspaceModel.TwinGeometry.outerMargin,
                          "the drawer's nearest edge clears the edge slider")
    }

    func testDrawerInteractionChangesNoEngineState() throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)
        try model.begin()
        defer { model.end() }

        XCTAssertEqual(model.drawerState, .idle)
        model.springDrawer(deck: .a)
        XCTAssertEqual(model.drawerState, .spring(deck: .a, bank: .eq))
        model.pinDrawer()
        XCTAssertEqual(model.drawerState, .pinned(deck: .a, bank: .eq))
        model.selectDrawerBank(.cues)
        XCTAssertEqual(model.drawerState, .pinned(deck: .a, bank: .cues))
        model.dismissDrawer()
        XCTAssertEqual(model.drawerState, .idle)

        XCTAssertTrue(fake.played.isEmpty)
        XCTAssertTrue(fake.paused.isEmpty)
        XCTAssertTrue(fake.synced.isEmpty)
        XCTAssertTrue(fake.unsynced.isEmpty)
        XCTAssertTrue(fake.eqKnobs.isEmpty,
                      "raising, pinning, switching and dismissing a drawer change no engine state (FR-ENG-12)")
        XCTAssertEqual(model.telemetry, EngineTelemetry(),
                       "telemetry is untouched by the drawer state machine")
    }

    func testSpringingOneDeckReplacesAnotherPinnedDrawer() throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)
        try model.begin()
        defer { model.end() }

        model.springDrawer(deck: .a)
        model.pinDrawer()
        XCTAssertEqual(model.drawerState, .pinned(deck: .a, bank: .eq))

        model.springDrawer(deck: .b)
        XCTAssertEqual(model.drawerState, .spring(deck: .b, bank: .eq),
                       "holding deck B's tab springs deck B's drawer over the pinned one")
        model.pinDrawer()
        XCTAssertEqual(model.drawerState, .pinned(deck: .b, bank: .eq))
        XCTAssertTrue(fake.played.isEmpty && fake.eqKnobs.isEmpty,
                      "springing a second deck is view-only")
    }

    func testDrawerRemembersTheSelectedBankPerDeck() throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)
        try model.begin()
        defer { model.end() }

        XCTAssertEqual(model.selectedBank(.a), .eq, "EQ is the default bank (§42.7b)")
        model.springDrawer(deck: .a)
        model.selectDrawerBank(.pads)
        XCTAssertEqual(model.selectedBank(.a), .pads)
        model.dismissDrawer()
        model.springDrawer(deck: .a)
        XCTAssertEqual(model.drawerState, .spring(deck: .a, bank: .pads),
                       "the remembered bank survives a dismiss")
        XCTAssertEqual(model.selectedBank(.b), .eq, "deck B's bank is untouched")
    }

    // MARK: - §42.7b idiom 3: release-to-commit flyout

    func testLoopFlyoutReleaseResolvesToTheChip() {
        // Release over a size to set it, release outside to cancel — nothing
        // changes on the way out. The resolution is pure, so the commit/cancel
        // decision is pinned off-device.
        let four = WorkspaceModel.LoopFlyout.chipFrame(index: 2)
        XCTAssertEqual(WorkspaceModel.LoopFlyout.releasedAction(at: CGPoint(x: four.midX, y: four.midY)),
                       .set(4))
        let one = WorkspaceModel.LoopFlyout.chipFrame(index: 0)
        XCTAssertEqual(WorkspaceModel.LoopFlyout.releasedAction(at: CGPoint(x: one.midX, y: one.midY)),
                       .set(1))
        let thirtyTwo = WorkspaceModel.LoopFlyout.chipFrame(index: 5)
        XCTAssertEqual(WorkspaceModel.LoopFlyout.releasedAction(at: CGPoint(x: thirtyTwo.midX, y: thirtyTwo.midY)),
                       .set(32))
        let exit = WorkspaceModel.LoopFlyout.exitChipFrame
        XCTAssertEqual(WorkspaceModel.LoopFlyout.releasedAction(at: CGPoint(x: exit.midX, y: exit.midY)),
                       .exit)

        // Sliding out — the button below the flyout, to its side, off its top —
        // cancels: nil, so the engine is never touched.
        XCTAssertNil(WorkspaceModel.LoopFlyout.releasedAction(
            at: CGPoint(x: four.midX, y: WorkspaceModel.LoopFlyout.height + 30)))
        XCTAssertNil(WorkspaceModel.LoopFlyout.releasedAction(
            at: CGPoint(x: WorkspaceModel.LoopFlyout.width + 30, y: four.midY)))
        XCTAssertNil(WorkspaceModel.LoopFlyout.releasedAction(
            at: CGPoint(x: four.midX, y: -30)))
        XCTAssertNil(WorkspaceModel.LoopFlyout.releasedAction(
            at: CGPoint(x: four.midX, y: four.maxY + 2)),
            "the gap between chips cancels")
    }

    func testLoopFlyoutBeatCountsAreThe41Point9aSet() {
        XCTAssertEqual(WorkspaceModel.LoopFlyout.beats, [1, 2, 4, 8, 16, 32],
                       "the §41.9a/§42.7b loop flyout beat counts, in order")
    }

    // MARK: - §42.7a idiom 4: bottom-edge relative crossfader

    func testRelativeCrossfaderIsOneToOne() {
        // The whole bottom edge drags 1:1: the resident cap's travel (mixer
        // column 202 − cap 22 = 180 pt) sweeps −1 … +1, so +90 pt is a full
        // sweep and +45 pt is half.
        let travel = WorkspaceModel.TwinGeometry.mixerColumnWidth
            - WorkspaceModel.TwinGeometry.crossfaderCapWidth
        XCTAssertEqual(travel, 180)
        XCTAssertEqual(WorkspaceModel.relativeCrossfader(from: 0, deltaX: 90, residentCapTravel: travel),
                       1, accuracy: 1e-6, "a full travel drag sweeps to +1")
        XCTAssertEqual(WorkspaceModel.relativeCrossfader(from: 0, deltaX: -90, residentCapTravel: travel),
                       -1, accuracy: 1e-6, "and to −1")
        XCTAssertEqual(WorkspaceModel.relativeCrossfader(from: 0, deltaX: 45, residentCapTravel: travel),
                       0.5, accuracy: 1e-6, "half a travel is half a sweep")
        XCTAssertEqual(WorkspaceModel.relativeCrossfader(from: 0.5, deltaX: 45, residentCapTravel: travel),
                       1, accuracy: 1e-6, "clamped at the +1 end")
        XCTAssertEqual(WorkspaceModel.relativeCrossfader(from: -0.5, deltaX: -45, residentCapTravel: travel),
                       -1, accuracy: 1e-6, "clamped at the −1 end")
        XCTAssertEqual(WorkspaceModel.relativeCrossfader(from: 0.2, deltaX: 0, residentCapTravel: travel),
                       0.2, accuracy: 1e-6, "a stationary drag changes nothing")
        XCTAssertEqual(WorkspaceModel.relativeCrossfader(from: 0.2, deltaX: 5, residentCapTravel: 0),
                       0.2, accuracy: 1e-6, "no travel means no mapping")
    }

    // MARK: - iPad module slot (§41.9a, plan 4.11)

    func testModuleSlotDefaultsToStems() {
        let model = WorkspaceModel(engine: FakeWorkspaceEngine(), store: makeStore(isPro: true),
                                   pump: nil, defaults: makeIsolatedDefaults())
        XCTAssertEqual(model.moduleSlot(.a), .stems, "the slot defaults to STEMS (§41.9a)")
        XCTAssertEqual(model.moduleSlot(.b), .stems)
        XCTAssertEqual(model.moduleSlotA, .stems)
        XCTAssertEqual(model.moduleSlotB, .stems)
    }

    func testModuleSlotIsRememberedPerDeckAndPersists() {
        let defaults = makeIsolatedDefaults()
        let first = WorkspaceModel(engine: FakeWorkspaceEngine(), store: makeStore(isPro: true),
                                   pump: nil, defaults: defaults)
        first.setModuleSlot(.jog, deck: .a)
        XCTAssertEqual(first.moduleSlot(.a), .jog)
        XCTAssertEqual(first.moduleSlot(.b), .stems, "deck B's slot is untouched")

        // A fresh model over the same defaults remembers deck A's choice —
        // the §41.9a "remembered per deck" contract.
        let second = WorkspaceModel(engine: FakeWorkspaceEngine(), store: makeStore(isPro: true),
                                    pump: nil, defaults: defaults)
        XCTAssertEqual(second.moduleSlot(.a), .jog, "the per-deck slot persists across model instances")
        XCTAssertEqual(second.moduleSlot(.b), .stems)
    }

    func testJogModeDefaultsToVinylAndPersistsPerDeck() {
        let defaults = makeIsolatedDefaults()
        let first = WorkspaceModel(engine: FakeWorkspaceEngine(), store: makeStore(isPro: true),
                                   pump: nil, defaults: defaults)
        XCTAssertEqual(first.jogMode(.a), .vinyl, "vinyl (scratch) is the default platter action")
        first.setJogMode(.cdj, deck: .b)
        XCTAssertEqual(first.jogMode(.b), .cdj)
        XCTAssertEqual(first.jogMode(.a), .vinyl, "deck A's mode is untouched")

        let second = WorkspaceModel(engine: FakeWorkspaceEngine(), store: makeStore(isPro: true),
                                    pump: nil, defaults: defaults)
        XCTAssertEqual(second.jogMode(.b), .cdj, "the jog mode persists per deck")
        XCTAssertEqual(second.jogMode(.a), .vinyl)
    }

    func testModuleSlotSwapChangesNoEngineState() throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil,
                                   defaults: makeIsolatedDefaults())
        try model.begin()
        defer { model.end() }

        model.setModuleSlot(.jog, deck: .a)
        model.setModuleSlot(.pads, deck: .b)
        model.setModuleSlot(.fx, deck: .a)
        model.setModuleSlot(.stems, deck: .a)
        model.setJogMode(.cdj, deck: .a)
        model.setJogSensitivity(.a, value: 1.4)
        model.setJogSensitivity(.b, value: 0.3)

        XCTAssertTrue(fake.played.isEmpty, "swapping modules, modes and sensitivity is view-only (AT-TWIN-2)")
        XCTAssertTrue(fake.paused.isEmpty)
        XCTAssertTrue(fake.synced.isEmpty)
        XCTAssertTrue(fake.unsynced.isEmpty)
        XCTAssertTrue(fake.eqKnobs.isEmpty, "the mixer is untouched by a module swap")
        XCTAssertEqual(model.telemetry, EngineTelemetry(), "telemetry is untouched by a module swap")
        XCTAssertFalse(fake.stopped, "the engine keeps running under the swap — both decks stay live")
    }

    func testJogSensitivityClampsToTheRange() {
        let model = WorkspaceModel(engine: FakeWorkspaceEngine(), store: makeStore(isPro: true),
                                   pump: nil, defaults: makeIsolatedDefaults())
        XCTAssertEqual(model.jogSensitivity(.a), 1.0, "unity default (§40.7.4)")
        model.setJogSensitivity(.a, value: 3.0)
        XCTAssertEqual(model.jogSensitivity(.a), 2.0, "clamped to the §40.7.4 maximum")
        model.setJogSensitivity(.a, value: 0.1)
        XCTAssertEqual(model.jogSensitivity(.a), 0.5, "clamped to the §40.7.4 minimum")
        model.setJogSensitivity(.a, value: 1.6)
        XCTAssertEqual(model.jogSensitivity(.a), 1.6, accuracy: 1e-12)
        XCTAssertEqual(model.jogSensitivity(.b), 1.0, "deck B is untouched")
        XCTAssertEqual(model.jogSensitivityA, model.jogSensitivity(.a))
    }

    func testModuleSlotNeverOccludesSharedControls() {
        // AT-TWIN-2: the module slot is a layout member of its own deck column
        // (never an overlay), so the widest module — the 248 pt jog with its
        // ± bend columns — must fit the §41.9 `1fr 268px 1fr` deck column on
        // the 1180 pt canvas. That is what structurally keeps a module from
        // ever reaching the mixer column or the opposite deck.
        XCTAssertEqual(WorkspaceModel.ModuleGeometry.jogSize, 248, "the §41.9a jog diameter")
        XCTAssertEqual(WorkspaceModel.ModuleGeometry.mixerColumnWidth, 268)
        XCTAssertEqual(WorkspaceModel.ModuleGeometry.jogModuleWidth,
                       248 + 2 * 58 + 2 * 14, "jog + two bend columns + two gaps")

        let canvas: CGFloat = 1180
        let column = WorkspaceModel.ModuleGeometry.deckColumnWidth(canvas: canvas)
        XCTAssertEqual(column, (canvas - 2 * 12 - 268 - 2 * 12) / 2, accuracy: 1e-9,
                       "the §41.9 grid math: 1fr 268px 1fr over a 1180 canvas")
        XCTAssertLessThanOrEqual(WorkspaceModel.ModuleGeometry.jogModuleWidth, column,
                                 "the jog module fits its deck column and cannot reach the mixer (AT-TWIN-2)")
        XCTAssertGreaterThanOrEqual(column, WorkspaceModel.ModuleGeometry.jogSize,
                                    "a deck column is comfortably wider than the jog itself")
    }

    // MARK: - Helpers

    /// An isolated `UserDefaults` domain per call — the module-slot persistence
    /// tests must never read or write the process's real defaults (§41.9a).
    private func makeIsolatedDefaults() -> UserDefaults {
        let suite = "WorkspaceModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private final class OfflineSource {
        let buffer: UnsafeMutablePointer<Float>
        let source: DeckSource
        init(frames: Int) {
            buffer = .allocate(capacity: frames)
            for i in 0..<frames { buffer[i] = Float(i) * 0.001 }
            source = DeckSource(pcm: UnsafeRawPointer(buffer), frameCount: Int64(frames),
                                channelCount: 1, sampleRate: 48_000,
                                grid: DeckGrid(bpm: 120, sampleRate: 48_000))
        }
        deinit { buffer.deallocate() }
    }
}
