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

    // MARK: - Helpers

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
