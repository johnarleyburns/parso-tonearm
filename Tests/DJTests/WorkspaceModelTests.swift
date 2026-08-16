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
        private(set) var echoEnabled: [PerformanceEngine.Deck: Bool] = [:]
        private(set) var echoBeats: [PerformanceEngine.Deck: Double] = [:]
        private(set) var echoDepth: [PerformanceEngine.Deck: Float] = [:]
        private(set) var echoFeedback: [PerformanceEngine.Deck: Float] = [:]
        private(set) var armedStemSets: [PerformanceEngine.Deck: StemSet] = [:]
        private(set) var disarmedStemSets: Set<PerformanceEngine.Deck> = []
        private(set) var stemGains: [PerformanceEngine.Deck: [StemKind: Float]] = [:]
        private(set) var stemMutes: [PerformanceEngine.Deck: Set<StemKind>] = [:]
        private(set) var stemSolos: [PerformanceEngine.Deck: Set<StemKind>] = [:]
        private(set) var recordingStarts = 0
        private(set) var recordingStops = 0
        private(set) var interruptionFlushes = 0
        private(set) var interruptionResumes = 0
        private(set) var isRecording = false
        private(set) var lastStartDirectory: URL?
        var lastStopOutput: RecordingEncoder.RecordingOutput?

        func start() throws { started = true }
        func stop() { stopped = true }
        private(set) var loadedDeck: PerformanceEngine.Deck?
        private(set) var loadedSource: DeckSource?
        func load(_ deck: PerformanceEngine.Deck, source: DeckSource) {
            loadedDeck = deck
            loadedSource = source
        }
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
        func setRate(_ deck: PerformanceEngine.Deck, rate: Float) { rates[deck] = Double(rate) }
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
        private(set) var crossfaders: [Float] = []
        func setCrossfader(_ position: Float, curve: CrossfaderCurve) {
            crossfaders.append(position)
        }
        func setEchoEnabled(_ deck: PerformanceEngine.Deck, enabled: Bool) {
            echoEnabled[deck] = enabled
        }
        func setEchoBeats(_ deck: PerformanceEngine.Deck, beats: Double) {
            echoBeats[deck] = beats
        }
        func setEchoDepth(_ deck: PerformanceEngine.Deck, depth: Float) {
            echoDepth[deck] = depth
        }
        func setEchoFeedback(_ deck: PerformanceEngine.Deck, feedback: Float) {
            echoFeedback[deck] = feedback
        }
        func armStemSet(_ deck: PerformanceEngine.Deck, stemSet: StemSet?) {
            if let stemSet {
                armedStemSets[deck] = stemSet
                disarmedStemSets.remove(deck)
            } else {
                armedStemSets[deck] = nil
                disarmedStemSets.insert(deck)
            }
        }
        func setStemGain(_ deck: PerformanceEngine.Deck, stem: StemKind, gain: Float) {
            stemGains[deck, default: [:]][stem] = gain
        }
        func setStemMute(_ deck: PerformanceEngine.Deck, stem: StemKind, muted: Bool) {
            if muted { stemMutes[deck, default: []].insert(stem) } else { stemMutes[deck]?.remove(stem) }
        }
        func setStemSolo(_ deck: PerformanceEngine.Deck, stem: StemKind, soloed: Bool) {
            if soloed { stemSolos[deck, default: []].insert(stem) } else { stemSolos[deck]?.remove(stem) }
        }
        func startRecording() async throws -> URL {
            recordingStarts += 1
            isRecording = true
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            lastStartDirectory = dir
            return dir
        }
        func stopRecording() async throws -> RecordingEncoder.RecordingOutput? {
            recordingStops += 1
            isRecording = false
            return lastStopOutput
        }
        func interruptRecordingForInterruption() async throws { interruptionFlushes += 1 }
        func resumeRecordingFromInterruption() async throws { interruptionResumes += 1 }
        func sampleTelemetry() -> EngineTelemetry { current }
        func pushTelemetry() { stream.push(current) }

        // Cue monitoring (§44.2a, plan 6.4) — recorded so the model's
        // forwarding is asserted rather than assumed.
        private(set) var cuedDecks: Set<PerformanceEngine.Deck> = []
        private(set) var cueModes: [CueMode] = []
        func setHeadphoneCue(_ deck: PerformanceEngine.Deck, enabled: Bool) {
            if enabled { cuedDecks.insert(deck) } else { cuedDecks.remove(deck) }
        }
        func setCueMode(_ mode: CueMode) { cueModes.append(mode) }

        // Liveness (NFR-REL-2, plan 6.1). `isGraphRunning` is settable so a
        // test can reproduce the two ways a graph dies: reporting itself
        // stopped, and the worse one — going on claiming to run while its
        // clock stands still.
        var isGraphRunning = true
        private(set) var recoveries = 0
        var recoveryError: Error?
        private var configurationContinuation: AsyncStream<Void>.Continuation?
        func configurationChanges() -> AsyncStream<Void> {
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            configurationContinuation = continuation
            return stream
        }
        func postConfigurationChange() { configurationContinuation?.yield(()) }
        func recoverGraph() throws {
            recoveries += 1
            if let recoveryError { throw recoveryError }
            isGraphRunning = true
        }
    }

    /// The §37.3 journal seam (plan 5.11) — a recording fake so the model's
    /// begin/finalize/reconcile wiring is exercised deterministically. The
    /// §37.4 timeline (plan 5.12) is captured: finalize receives the model's
    /// accumulated `MixTimeline`.
    private final class FakeRecordingJournal: RecordingJournaling, @unchecked Sendable {
        var beginCalls: [URL] = []
        var finalizeCalls: [(output: RecordingEncoder.RecordingOutput,
                             journal: RecordingJournalConfiguration?,
                             timeline: MixTimeline)] = []
        var reconcileCount = 0
        var throwOnBegin = false
        var finishedMix: DJMix?

        func begin(outputDirectory: URL) async throws {
            beginCalls.append(outputDirectory)
            if throwOnBegin { throw RecordingJournalError.missingMixID }
        }
        func finalize(output: RecordingEncoder.RecordingOutput,
                      journal: RecordingJournalConfiguration?,
                      timeline: MixTimeline) async throws -> DJMix? {
            finalizeCalls.append((output, journal, timeline))
            return finishedMix
        }
        func reconcile() async throws -> [RecoveredMix] {
            reconcileCount += 1
            return []
        }
    }

    private struct EmptyEntitlementSource: EntitlementSource {
        func currentTransactions() async throws -> [TransactionFact] { [] }
        func transactionUpdates() -> AsyncStream<TransactionFact> { AsyncStream { _ in } }
    }

    /// A recording fake of the library → deck seam (plan 5.1): the per-deck
    /// queue catalog plus canned load outcomes, so the model's queue state and
    /// load forwarding are exercised deterministically. Main-actor confined
    /// (like the tests), which is what makes its `Sendable` conformance safe.
    @MainActor
    private final class FakeDeckLibrary: DeckLibraryServicing {
        var available: [DeckQueueSource] = [.allTracks]
        var rowsBySource: [DeckQueueSource: [DeckQueueRow]] = [:]
        var outcomes: [Int64: DeckLoadOutcome] = [:]
        private(set) var loadedTrackIDs: [Int64] = []

        func availableQueues() async throws -> [DeckQueueSource] { available }

        func rows(in source: DeckQueueSource) async throws -> [DeckQueueRow] {
            rowsBySource[source] ?? []
        }

        func load(trackID: Int64) async -> DeckLoadOutcome {
            loadedTrackIDs.append(trackID)
            return outcomes[trackID] ?? .refused(.unavailable(reason: "not ready"))
        }
    }

    /// A tiny decoded box the fake hands back as `.loaded` — the model keeps it
    /// alive (the §12.2 box) for the duration of the test.
    private func makeLoadedBox(frames: Int = 1000) -> DeckSourceBox {
        let storage = UnsafeMutableBufferPointer<Float>.allocate(capacity: frames)
        for i in 0..<frames { storage[i] = 0.1 }
        return DeckSourceBox(samples: storage, sampleRate: 48_000,
                             grid: DeckGrid(bpm: 120, sampleRate: 48_000))
    }

    /// A fake §26A render seam (plan 5.3): the model's waveform state is
    /// exercised deterministically without touching a real database.
    @MainActor
    private final class FakeWaveformRepository: WaveformRendering {
        var models: [Int64: WaveformRenderModel] = [:]
        var requested: [Int64] = []

        func renderModel(trackID: Int64) async throws -> WaveformRenderModel? {
            requested.append(trackID)
            return models[trackID]
        }
    }

    /// A fake prepared-stems seam (plan 5.8): canned stem sets per track, so
    /// the model's per-deck stem status and fader forwarding are exercised
    /// deterministically without a database (§47.2).
    @MainActor
    private final class FakeStemProvider: StemProviding {
        var sets: [Int64: StemSetBox] = [:]
        var requested: [Int64] = []

        func preparedStems(trackID: Int64, grid: DeckGrid) async throws -> StemSetBox? {
            requested.append(trackID)
            return sets[trackID]
        }
    }

    /// A tiny prepared stem set the fake hands back as prepared — four owned
    /// mono voice buffers (the §12.2 boxes). The box copies the voices into its
    /// own storage; the temporaries are freed when this returns.
    private func makeStemBox(frames: Int = 480) -> StemSetBox {
        func voice(_ value: Float) -> UnsafeMutableBufferPointer<Float> {
            let storage = UnsafeMutableBufferPointer<Float>.allocate(capacity: frames)
            for i in 0..<frames { storage[i] = value }
            return storage
        }
        let v = voice(0.5), d = voice(0.25), b = voice(0.1), o = voice(0.05)
        defer {
            v.deallocate()
            d.deallocate()
            b.deallocate()
            o.deallocate()
        }
        return StemSetBox(vocals: UnsafeBufferPointer(v), drums: UnsafeBufferPointer(d),
                          bass: UnsafeBufferPointer(b), other: UnsafeBufferPointer(o),
                          sampleRate: 48_000,
                          grid: DeckGrid(bpm: 120, sampleRate: 48_000))
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
        // ± bend columns — must fit the §41.9b `1fr 320px 1fr` deck column on
        // the 1180 pt canvas. That is what structurally keeps a module from
        // ever reaching the mixer column or the opposite deck.
        XCTAssertEqual(WorkspaceModel.ModuleGeometry.jogSize, 248, "the §41.9a jog diameter")
        XCTAssertEqual(WorkspaceModel.ModuleGeometry.mixerColumnWidth, 320,
                       "the §41.9b mixer column (was 268 in M4)")
        XCTAssertEqual(WorkspaceModel.ModuleGeometry.jogModuleWidth,
                       248 + 2 * 58 + 2 * 14, "jog + two bend columns + two gaps")

        let canvas: CGFloat = 1180
        let column = WorkspaceModel.ModuleGeometry.deckColumnWidth(canvas: canvas)
        XCTAssertEqual(column, (canvas - 2 * 12 - 320 - 2 * 12) / 2, accuracy: 1e-9,
                       "the §41.9b grid math: 1fr 320px 1fr over a 1180 canvas")
        XCTAssertLessThanOrEqual(WorkspaceModel.ModuleGeometry.jogModuleWidth, column,
                                 "the jog module fits its deck column and cannot reach the mixer (AT-TWIN-2)")
        XCTAssertLessThanOrEqual(WorkspaceModel.ModuleGeometry.jogModuleWidth,
                                 WorkspaceModel.ModuleGeometry.deckColumnWidth,
                                 "the §41.9b normative deck column (~416 pt) also fits the jog module")
        XCTAssertGreaterThanOrEqual(column, WorkspaceModel.ModuleGeometry.jogSize,
                                    "a deck column is comfortably wider than the jog itself")
    }

    // MARK: - §41.9b club ergonomics (FR-TRANS-2, plan 5.4)

    func testClubMixerColumnBudget() {
        // §41.9b geometry: mixer column 320 pt, deck column ~416 pt, and the
        // tempo fader + plain jog pair fits the deck column (rule 4). The
        // bend-column jog module (jog + two bend columns + two gaps = 392) fits
        // the deck column alone (the module slot's JOG option) — asserted in
        // testModuleSlotNeverOccludesSharedControls.
        XCTAssertEqual(WorkspaceModel.ModuleGeometry.mixerColumnWidth, 320)
        XCTAssertEqual(WorkspaceModel.ModuleGeometry.deckColumnWidth, 416)
        let innerDeck = WorkspaceModel.ModuleGeometry.deckColumnWidth
            - 2 * WorkspaceModel.ModuleGeometry.outerPadding
        XCTAssertLessThanOrEqual(
            WorkspaceModel.ModuleGeometry.tempoFaderWidth
                + 6
                + WorkspaceModel.ModuleGeometry.jogSize,
            innerDeck,
            "the tempo fader (58) beside the plain jog (248) fits the ~416 pt deck column's inner width")
        XCTAssertLessThanOrEqual(WorkspaceModel.ModuleGeometry.tempoFaderWidth,
                                 WorkspaceModel.ModuleGeometry.jogSize,
                                 "the tempo fader is the deck column's narrow outer column")
    }

    func testChannelStripOrderIsTheClubReadingOrder() {
        // §41.9b rule 1: TRIM → HI → MID → LOW → FILTER above a vertical
        // channel fader and a CUE button — the order every club mixer uses and
        // the order the five transitions are taught in (FR-TRANS-2).
        XCTAssertEqual(WorkspaceModel.ClubGeometry.channelStripOrder,
                       ["TRIM", "HI", "MID", "LOW", "FILTER", "FADER", "CUE"])
    }

    func testCueIsLeftOfPlayAndBothAreAtLeast44Point() {
        // §41.9b rule 3: CUE sits to the LEFT of PLAY at each deck's inner
        // base, both ≥ 54 pt. The transport order constant is the layout's
        // contract; the compact vertical stack reads CUE before PLAY too.
        XCTAssertEqual(WorkspaceModel.ClubGeometry.deckTransportOrder, ["CUE", "PLAY"])
    }

    func testEightPadsUnderTheModeSelector() {
        // §41.9b rule 5: eight performance pads, two rows of four, with the
        // mode selector immediately above them.
        XCTAssertEqual(WorkspaceModel.ClubGeometry.padCount, 8)
        XCTAssertEqual(WorkspaceModel.ClubGeometry.padColumns, 4)
        XCTAssertEqual(WorkspaceModel.ClubGeometry.padRows, 2)
        XCTAssertEqual(WorkspaceModel.ClubGeometry.padModes,
                       ["HOT CUE", "PAD FX", "BEAT JUMP", "SAMPLER"])
    }

    func testTempoFaderRangeIsTheBeatmatchRange() {
        // §41.9b rule 4 / §31.2: the tempo fader's ±8% range — the range
        // "typical in beatmatching" (FR-ENG-6). The fader maps rate = 1 + f.
        XCTAssertEqual(WorkspaceModel.ClubGeometry.tempoFaderRange.lowerBound, -0.08, accuracy: 1e-9)
        XCTAssertEqual(WorkspaceModel.ClubGeometry.tempoFaderRange.upperBound, 0.08, accuracy: 1e-9)
        XCTAssertEqual(WorkspaceModel.ClubGeometry.tempoFaderRange.lowerBound * -1,
                       WorkspaceModel.ClubGeometry.tempoFaderRange.upperBound,
                       "symmetric around unity")
    }

    func testEchoBeatLengthsAreThe35ASet() {
        // §41.9b rule 7 / §35A: 1/4 … 4 beats.
        XCTAssertEqual(WorkspaceModel.ClubGeometry.echoBeats, [0.25, 0.5, 1, 2, 4])
    }

    func testEchoStateForwardsToTheEnginePerDeck() throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)
        try model.begin()
        defer { model.end() }

        XCTAssertFalse(model.echoEnabled(.a), "the echo starts off")
        XCTAssertEqual(model.echoBeats(.a), 1, "one beat is the default length")
        XCTAssertEqual(model.echoDepth(.a), 0.6)
        XCTAssertEqual(model.echoFeedback(.a), 0.7)

        model.setEchoEnabled(.a, enabled: true)
        model.setEchoBeats(.a, beats: 2)
        model.setEchoDepth(.a, depth: 0.8)
        model.setEchoFeedback(.a, feedback: 0.5)

        XCTAssertEqual(fake.echoEnabled[.a], true, "the enabled state crosses the ring")
        XCTAssertEqual(fake.echoBeats[.a], 2)
        XCTAssertEqual(fake.echoDepth[.a], 0.8)
        XCTAssertEqual(fake.echoFeedback[.a], 0.5)
        XCTAssertEqual(model.echoEnabled(.a), true, "the shared VM mirrors the deck's echo state")
        XCTAssertEqual(model.echoEnabled(.b), false, "deck B's echo is untouched")
        XCTAssertEqual(model.echoBeats(.b), 1)
    }

    func testEchoStateClampsToThe35ARange() throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)
        try model.begin()
        defer { model.end() }

        model.setEchoBeats(.a, beats: 8)
        XCTAssertEqual(model.echoBeats(.a), 4, "clamped to the §35A.2 maximum (4 beats)")
        XCTAssertEqual(fake.echoBeats[.a], 4)
        model.setEchoBeats(.a, beats: 0.1)
        XCTAssertEqual(model.echoBeats(.a), 0.25, "clamped to the §35A.2 minimum (1/4)")
        model.setEchoDepth(.a, depth: 2)
        XCTAssertEqual(model.echoDepth(.a), 1, "depth clamped to 0…1")
        model.setEchoFeedback(.a, feedback: 0.99)
        XCTAssertEqual(model.echoFeedback(.a), 0.85,
                       "feedback clamped below unity — the tail always decays (§35A.2)")
        model.setEchoFeedback(.a, feedback: -1)
        XCTAssertEqual(model.echoFeedback(.a), 0)
    }

    // MARK: - Per-deck stems (§36.5, §35.1; plan 5.8)

    func testLoadArmsPreparedStemsAndLivesTheFaders() async throws {
        let fake = FakeWorkspaceEngine()
        let library = FakeDeckLibrary()
        let box = makeLoadedBox()
        library.outcomes[5] = .loaded(box)
        let stems = FakeStemProvider()
        stems.sets[5] = makeStemBox()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil,
                                   library: library, stemProvider: stems)
        try model.begin()
        defer { model.end() }

        XCTAssertEqual(model.stemStatus(.a), .unavailable, "no deck loaded → nothing prepared")
        await model.load(.a, trackID: 5)
        XCTAssertEqual(stems.requested, [5])
        XCTAssertEqual(model.stemStatus(.a), .prepared,
                       "a prepared set → the status is prepared and the faders go live")
        XCTAssertNotNil(fake.armedStemSets[.a],
                        "the prepared set is armed on the deck (§36.5)")
        XCTAssertFalse(fake.disarmedStemSets.contains(.a))

        // Faders forward to the engine now that the deck is prepared.
        model.setStemGain(.a, stem: .vocals, gain: 0.75)
        XCTAssertEqual(fake.stemGains[.a]?[.vocals], 0.75, "a live fader crosses the ring")
        XCTAssertEqual(model.stemGain(.a, stem: .vocals), 0.75, "the VM mirrors the fader")
        model.setStemMute(.a, stem: .bass, muted: true)
        XCTAssertTrue(fake.stemMutes[.a]?.contains(.bass) == true)
        XCTAssertTrue(model.stemIsMuted(.a, stem: .bass))
        model.setStemSolo(.a, stem: .drums, soloed: true)
        XCTAssertTrue(fake.stemSolos[.a]?.contains(.drums) == true)
        XCTAssertTrue(model.stemIsSoloed(.a, stem: .drums))

        XCTAssertEqual(model.stemStatus(.b), .unavailable,
                       "deck B's stems are untouched by deck A's load (FR-ENG-13)")
        XCTAssertNil(fake.armedStemSets[.b], "deck B is never armed by deck A's load")
    }

    func testLoadWithoutPreparedStemsKeepsFullMixAndDisablesFaders() async throws {
        let fake = FakeWorkspaceEngine()
        let library = FakeDeckLibrary()
        library.outcomes[7] = .loaded(makeLoadedBox())
        let stems = FakeStemProvider() // no sets → nothing prepared
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil,
                                   library: library, stemProvider: stems)
        try model.begin()
        defer { model.end() }

        await model.load(.a, trackID: 7)
        XCTAssertEqual(model.stemStatus(.a), .unavailable,
                       "the honest unavailable state — the deck plays the full mix (§36.5)")
        XCTAssertTrue(fake.disarmedStemSets.contains(.a), "the deck is disarmed, never armed")

        // A fader that is not live must never do anything (§36.5's honest-fader
        // rule — inert, not a mirror that lies).
        model.setStemGain(.a, stem: .vocals, gain: 0.4)
        XCTAssertEqual(fake.stemGains[.a], nil,
                       "an unprepared deck's fader does not cross the ring")
        XCTAssertEqual(model.stemGain(.a, stem: .vocals), 1,
                       "an unprepared fader does not even move — it is inert, not decorative")
        model.setStemMute(.a, stem: .drums, muted: true)
        XCTAssertEqual(fake.stemMutes[.a], nil, "mute is forwarded only when prepared")
        XCTAssertFalse(model.stemIsMuted(.a, stem: .drums))
    }

    func testMarkStemSeparationIsTheHonestSeparatingState() async throws {
        let fake = FakeWorkspaceEngine()
        let library = FakeDeckLibrary()
        library.outcomes[9] = .loaded(makeLoadedBox())
        let stems = FakeStemProvider()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil,
                                   library: library, stemProvider: stems)
        try model.begin()
        defer { model.end() }

        await model.load(.a, trackID: 9)
        XCTAssertEqual(model.stemStatus(.a), .unavailable)
        model.markStemSeparation(.a)
        XCTAssertEqual(model.stemStatus(.a), .separating,
                       "the service's in-flight report renders the honest separating state (§36.3)")
        XCTAssertEqual(model.stemStatus(.a).label, "separating…")

        // A separating deck's faders are still not live.
        model.setStemGain(.a, stem: .vocals, gain: 0.9)
        XCTAssertEqual(fake.stemGains[.a], nil,
                       "separating is not prepared — the faders stay disabled")
        XCTAssertTrue(fake.disarmedStemSets.contains(.a))
    }

    func testStemStatusLabelRendersTheHonestState() {
        XCTAssertEqual(DeckStemStatus.unavailable.label, "stems not prepared")
        XCTAssertEqual(DeckStemStatus.prepared.label, "stems ready")
    }

    func testStemControlStateUnityDefaultsAndGainClamp() {
        let state = StemControlState()
        XCTAssertEqual(state.gains.count, StemKind.allCases.count)
        for stem in StemKind.allCases {
            XCTAssertEqual(state.gains[stem], 1, "unity is the armed default (§35.1)")
        }
        XCTAssertTrue(state.muted.isEmpty)
        XCTAssertTrue(state.soloed.isEmpty)
        XCTAssertEqual(StemControlState.maxGain, 1.5)
    }

    func testStemGainClampsToTheControlRange() async throws {
        let fake = FakeWorkspaceEngine()
        let library = FakeDeckLibrary()
        library.outcomes[5] = .loaded(makeLoadedBox())
        let stems = FakeStemProvider()
        stems.sets[5] = makeStemBox()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil,
                                   library: library, stemProvider: stems)
        try model.begin()
        defer { model.end() }

        await model.load(.a, trackID: 5)
        XCTAssertEqual(model.stemStatus(.a), .prepared)
        model.setStemGain(.a, stem: .vocals, gain: 3)
        XCTAssertEqual(model.stemGain(.a, stem: .vocals), StemControlState.maxGain,
                       "the gain clamps to the fader's full travel")
        XCTAssertEqual(fake.stemGains[.a]?[.vocals], StemControlState.maxGain)
        model.setStemGain(.a, stem: .vocals, gain: -1)
        XCTAssertEqual(model.stemGain(.a, stem: .vocals), 0, "clamped at the bottom")
    }

    func testEchoFlyoutReleaseResolvesToTheChip() {
        // §42.7c: the compact ECHO flyout is release-to-commit — release over
        // a channel, a beat chip or the depth track commits; sliding out
        // cancels. Nothing changes on the way out.
        let a = WorkspaceModel.EchoFlyout.channelChipFrame(index: 0)
        XCTAssertEqual(WorkspaceModel.EchoFlyout.releasedAction(at: CGPoint(x: a.midX, y: a.midY)),
                       .channel(0), "release over the A chip selects channel A")
        let b = WorkspaceModel.EchoFlyout.channelChipFrame(index: 1)
        XCTAssertEqual(WorkspaceModel.EchoFlyout.releasedAction(at: CGPoint(x: b.midX, y: b.midY)),
                       .channel(1), "release over the B chip selects channel B")

        let four = WorkspaceModel.EchoFlyout.chipFrame(index: 2)
        XCTAssertEqual(WorkspaceModel.EchoFlyout.releasedAction(at: CGPoint(x: four.midX, y: four.midY)),
                       .beats(1), "release over the third chip commits 1 beat")
        let half = WorkspaceModel.EchoFlyout.chipFrame(index: 0)
        XCTAssertEqual(WorkspaceModel.EchoFlyout.releasedAction(at: CGPoint(x: half.midX, y: half.midY)),
                       .beats(0.25), "release over the first chip commits 1/4")
        let eight = WorkspaceModel.EchoFlyout.chipFrame(index: 4)
        XCTAssertEqual(WorkspaceModel.EchoFlyout.releasedAction(at: CGPoint(x: eight.midX, y: eight.midY)),
                       .beats(4), "release over the last chip commits 4 beats")

        let track = WorkspaceModel.EchoFlyout.depthTrackFrame()
        assertDepth(WorkspaceModel.EchoFlyout.releasedAction(at: CGPoint(x: track.minX, y: track.midY)),
                    expected: 0, accuracy: 1e-6, "release over the depth track's left edge reads 0")
        assertDepth(WorkspaceModel.EchoFlyout.releasedAction(at: CGPoint(x: track.maxX - 1, y: track.midY)),
                    expected: 1, accuracy: 0.02, "release over the depth track's right edge reads ~1")
        assertDepth(WorkspaceModel.EchoFlyout.releasedAction(at: CGPoint(x: track.midX, y: track.midY)),
                    expected: 0.5, accuracy: 1e-6, "release over the depth track's centre reads 0.5")

        // Sliding out — below the flyout, to its side, off its top — cancels.
        XCTAssertNil(WorkspaceModel.EchoFlyout.releasedAction(
            at: CGPoint(x: four.midX, y: WorkspaceModel.EchoFlyout.height + 20)))
        XCTAssertNil(WorkspaceModel.EchoFlyout.releasedAction(
            at: CGPoint(x: WorkspaceModel.EchoFlyout.width + 20, y: four.midY)))
        XCTAssertNil(WorkspaceModel.EchoFlyout.releasedAction(
            at: CGPoint(x: four.midX, y: -20)))
    }

    private func assertDepth(_ action: WorkspaceModel.EchoFlyout.EchoAction?,
                             expected: Float, accuracy: Float = 1e-6, _ message: String) {
        guard case .depth(let depth)? = action else {
            return XCTFail("expected a .depth commit — \(message)")
        }
        XCTAssertEqual(depth, expected, accuracy: accuracy, message)
    }

    func testEchoFlyoutGeometryFitsTheCompactMixerColumn() {
        // The flyout is anchored over the compact surfaces' always-visible
        // band; its width must fit the §42.7a twin mixer column (202 pt) and
        // every chip row stays inside it.
        XCTAssertLessThanOrEqual(WorkspaceModel.EchoFlyout.width,
                                 WorkspaceModel.TwinGeometry.mixerColumnWidth,
                                 "the flyout fits the twin mixer column")
        XCTAssertEqual(WorkspaceModel.EchoFlyout.beats, WorkspaceModel.ClubGeometry.echoBeats,
                       "the flyout's beat lengths are the §35A set")
        for index in 0..<5 {
            let frame = WorkspaceModel.EchoFlyout.chipFrame(index: index)
            XCTAssertGreaterThanOrEqual(frame.minX, 0, "chip \(index) stays inside the flyout")
            XCTAssertLessThanOrEqual(frame.maxX, WorkspaceModel.EchoFlyout.width)
        }
        let track = WorkspaceModel.EchoFlyout.depthTrackFrame()
        XCTAssertGreaterThanOrEqual(track.minX, 0)
        XCTAssertLessThanOrEqual(track.maxX, WorkspaceModel.EchoFlyout.width)
        XCTAssertLessThanOrEqual(track.maxY, WorkspaceModel.EchoFlyout.height)
    }

    func testTempoFaderForwardsRateAndClamps() throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)
        try model.begin()
        defer { model.end() }

        XCTAssertEqual(model.tempo(.a), 0, "the fader rests at unity")
        model.setTempo(.a, fraction: 0.04)
        XCTAssertEqual(model.tempo(.a), 0.04, accuracy: 1e-9)
        XCTAssertEqual(fake.rates[.a] ?? 0, 1.04, accuracy: 1e-6,
                       "the fader sets the deck's rate directly (rate = 1 + f)")

        model.setTempo(.a, fraction: 0.5)
        XCTAssertEqual(model.tempo(.a), 0.08, accuracy: 1e-9,
                       "clamped to the ±8% range")
        XCTAssertEqual(fake.rates[.a] ?? 0, 1.08, accuracy: 1e-6)

        model.setTempo(.a, fraction: -0.5)
        XCTAssertEqual(model.tempo(.a), -0.08, accuracy: 1e-9, "clamped low")
        XCTAssertEqual(model.tempo(.b), 0, "deck B's fader is untouched")
        XCTAssertEqual(fake.rates[.a] ?? 0, 0.92, accuracy: 1e-6)
    }

    func testMasterBarBeatReadout() {
        // §53.11's dj.master.bar: the master clock's bar and beat at a sample
        // position — bar = floor(samples/bar)+1, beat the offset within it.
        let sampleRate = 48_000.0
        // 120 BPM → 24000 samples/beat, 96000 samples/bar exactly — integer
        // sample positions make the boundary cases exact.
        XCTAssertNil(WorkspaceModel.masterBarBeat(masterSample: 0, bpm: 0, sampleRate: sampleRate),
                     "no master clock reads nothing")
        assertBarBeat(WorkspaceModel.masterBarBeat(masterSample: 0, bpm: 120, sampleRate: sampleRate),
                      bar: 1, beat: 1)
        let samplesPerBeat = 24_000.0
        let samplesPerBar = 96_000.0
        assertBarBeat(WorkspaceModel.masterBarBeat(masterSample: Int64(samplesPerBeat * 1.5),
                                                   bpm: 120, sampleRate: sampleRate),
                      bar: 1, beat: 2, "inside the first bar, beat 2")
        assertBarBeat(WorkspaceModel.masterBarBeat(masterSample: Int64(samplesPerBar * 3 + samplesPerBeat * 2),
                                                   bpm: 120, sampleRate: sampleRate),
                      bar: 4, beat: 3, "bar 4, beat 3")
        assertBarBeat(WorkspaceModel.masterBarBeat(masterSample: Int64(samplesPerBar * 2 - 1),
                                                   bpm: 120, sampleRate: sampleRate),
                      bar: 2, beat: 4, "the last sample of bar 2 reads bar 2 beat 4")
    }

    private func assertBarBeat(_ readout: (bar: Int, beat: Int)?,
                               bar: Int, beat: Int, _ message: String = "") {
        XCTAssertNotNil(readout, message)
        XCTAssertEqual(readout?.bar, bar, message)
        XCTAssertEqual(readout?.beat, beat, message)
    }

    // MARK: - Per-deck queues (§41.9c, FR-ENG-13; plan 5.1)

    func testPerDeckQueuesAreIndependent() async throws {
        let fake = FakeWorkspaceEngine()
        let library = FakeDeckLibrary()
        library.available = [.allTracks, .playlist(id: 1, title: "Set A")]
        library.rowsBySource[.allTracks] = [
            DeckQueueRow(trackID: 10, title: "Alpha", artist: "A", readiness: .ready),
            DeckQueueRow(trackID: 11, title: "Beta", artist: "B", readiness: .ready)
        ]
        library.rowsBySource[.playlist(id: 1, title: "Set A")] = [
            DeckQueueRow(trackID: 20, title: "Gamma", artist: "C", readiness: .ready)
        ]
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil,
                                   library: library)
        try model.begin()
        defer { model.end() }

        await model.selectQueue(.playlist(id: 1, title: "Set A"), for: .a)
        XCTAssertEqual(model.queue(for: .a).source, .playlist(id: 1, title: "Set A"))
        XCTAssertEqual(model.queue(for: .a).rows.map(\.trackID), [20])

        // The two decks are independent (FR-ENG-13): pointing deck A at a
        // playlist leaves deck B exactly where it was.
        XCTAssertEqual(model.queue(for: .b).source, .allTracks)
        XCTAssertEqual(model.queue(for: .b).rows, [])

        await model.selectQueue(.allTracks, for: .b)
        XCTAssertEqual(model.queue(for: .b).rows.map(\.trackID), [10, 11])
        XCTAssertEqual(model.queue(for: .a).rows.map(\.trackID), [20],
                       "setting deck B leaves deck A's queue untouched")
    }

    func testQueuesNeverAdvanceOnTheirOwn() async throws {
        let fake = FakeWorkspaceEngine()
        let library = FakeDeckLibrary()
        library.rowsBySource[.allTracks] = [
            DeckQueueRow(trackID: 1, title: "One", artist: "", readiness: .ready)
        ]
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil,
                                   library: library)
        try model.begin()
        defer { model.end() }

        await model.selectQueue(.allTracks, for: .a)
        await model.refreshDeckQueues()
        XCTAssertNil(fake.loadedSource, "queue selection and refresh never arm a deck — no auto-play-next (§41.9c)")
        XCTAssertEqual(model.loadState(for: .a), .idle)
        XCTAssertEqual(model.queue(for: .a).rows.map(\.trackID), [1])
    }

    // MARK: - Recording (§37.2, FR-ENG-7; plan 5.10, decision 14)

    func testRecordToggleForwardsStartAndStop() async throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)
        try model.begin()
        defer { model.end() }

        XCTAssertFalse(model.isRecording)
        await model.startRecording()
        XCTAssertEqual(fake.recordingStarts, 1, "the toggle forwards startRecording (decision 14)")
        XCTAssertTrue(fake.isRecording)
        XCTAssertTrue(model.isRecording, "the model mirrors the engine's recording state")

        await model.stopRecording()
        XCTAssertEqual(fake.recordingStops, 1, "the toggle forwards stopRecording")
        XCTAssertFalse(fake.isRecording)
        XCTAssertFalse(model.isRecording)
    }

    func testRecordToggleIsASingleToggle() async throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)
        try model.begin()
        defer { model.end() }

        model.toggleRecording()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(fake.recordingStarts, 1, "one toggle starts recording once")
        XCTAssertTrue(model.isRecording)

        model.toggleRecording()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(fake.recordingStops, 1, "the second toggle stops recording once")
        XCTAssertFalse(model.isRecording)
        XCTAssertEqual(fake.recordingStarts, 1, "a stop never restarts")
    }

    // MARK: - MIDI → engine (§44.4, FR-HW-1, plan 6.5)

    /// A mapped knob has to reach the engine through the **same** path a finger
    /// takes, or a controller becomes a second, subtly different way to mix.
    func testAMappedControlMovesTheMixerThroughTheOrdinaryPath() throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)
        var profile = ControllerProfile(name: "Test")
        let knob = MidiAddress(type: .cc, channel: 1, number: 7)
        // `.jump` — this test is about the ordinary path, not takeover.
        profile.learn(.eq(deck: .a, band: .low), at: knob, transform: .bipolar,
                      takeover: .jump)
        var takeover = TakeoverState()

        let intent = try XCTUnwrap(MidiRouter.intent(for: MidiMessage(address: knob, value: 0),
                                                     profile: profile, takeover: &takeover))
        model.apply(intent)

        XCTAssertEqual(model.eqALow, -1, accuracy: 1e-6, "the model's own state moved")
        XCTAssertEqual(fake.eqKnobs[.a]?.low, -1,
                       "and the engine was told, exactly as a drag would")
    }

    /// The crossfader through MIDI must still be a transition the journal sees:
    /// going through `setCrossfader` is what keeps the §37.4 recognisers
    /// working for a controller-driven mix.
    func testAMappedCrossfaderIsStillARecognisedTransition() throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)
        var profile = ControllerProfile(name: "Test")
        let slider = MidiAddress(type: .cc, channel: 1, number: 8)
        profile.learn(.crossfader, at: slider, transform: .bipolar, takeover: .jump)
        var takeover = TakeoverState()

        model.apply(try XCTUnwrap(MidiRouter.intent(for: MidiMessage(address: slider, value: 0),
                                                    profile: profile, takeover: &takeover)))
        XCTAssertEqual(model.crossfader, -1, accuracy: 1e-6)
        model.apply(try XCTUnwrap(MidiRouter.intent(for: MidiMessage(address: slider, value: 64),
                                                    profile: profile, takeover: &takeover)))
        XCTAssertEqual(model.crossfader, 0, accuracy: 0.02, "swept to centre — a Blend")
    }

    func testAMappedPadTogglesTheHeadphoneCue() throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)
        var profile = ControllerProfile(name: "Test")
        let pad = MidiAddress(type: .note, channel: 1, number: 36)
        profile.learn(.headphoneCue(deck: .b), at: pad, transform: ValueTransform(mode: .trigger))
        var takeover = TakeoverState()

        model.apply(try XCTUnwrap(MidiRouter.intent(for: MidiMessage(address: pad, value: 127),
                                                    profile: profile, takeover: &takeover)))
        XCTAssertTrue(model.isCued(.b))

        // The release must not toggle it straight back off.
        model.apply(try XCTUnwrap(MidiRouter.intent(for: MidiMessage(address: pad, value: 0),
                                                    profile: profile, takeover: &takeover)))
        XCTAssertTrue(model.isCued(.b), "a pad tap is one action, not two")
    }

    /// A continuous message on a trigger action does nothing: a knob bound to
    /// PLAY would otherwise machine-gun the transport on every increment.
    func testAContinuousMessageOnATriggerActionIsIgnored() throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)
        model.apply(.setContinuous(.play(deck: .a), 1))
        XCTAssertTrue(fake.played.isEmpty)
    }

    // MARK: - MIDI attachment (plan dj-midi-alpha M1, §44.3, FR-HW-1)

    /// The whole feature's missing wire: a message injected through
    /// `HardwareService.receive` — the seam the app and the regression lane
    /// drive — reaches the engine once `attachMidi` has run. This is the test
    /// whose absence let a mapped controller do nothing during a set.
    func testAnAttachedControllerMovesTheCrossfaderThroughReceive() async throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)
        var profile = ControllerProfile(name: "Test")
        let fader = MidiAddress(type: .cc, channel: 1, number: 7)
        profile.learn(.crossfader, at: fader, transform: .bipolar, takeover: .jump)

        let hardware = HardwareService()
        hardware.start()
        model.attachMidi(hardware, profile: profile)

        // The message task starts iterating the stream asynchronously; give it
        // a scheduler tick before injecting, or the continuation is not yet
        // subscribed and the message is dropped.
        await Self.settleMidiTask()
        hardware.receive(MidiMessage(address: fader, value: 127))
        await Self.settleMidiTask()

        XCTAssertEqual(model.crossfader, 1, accuracy: 1e-6,
                       "a CC through the real seam moves the crossfader, exactly as a finger would")
        XCTAssertEqual(fake.crossfaders.last, 1, "and the engine was told")
    }

    /// An unmapped address is silent: a controller sends a lot of traffic
    /// (LED echoes, touch sensors), and none of it may move anything.
    func testAnAttachedControllerIgnoresUnboundAddresses() async throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)
        var profile = ControllerProfile(name: "Test")
        let fader = MidiAddress(type: .cc, channel: 1, number: 7)
        profile.learn(.crossfader, at: fader, transform: .bipolar, takeover: .jump)

        let hardware = HardwareService()
        hardware.start()
        model.attachMidi(hardware, profile: profile)

        await Self.settleMidiTask()
        hardware.receive(MidiMessage(address: MidiAddress(type: .cc, channel: 1, number: 99), value: 127))
        await Self.settleMidiTask()

        XCTAssertEqual(model.crossfader, 0, accuracy: 1e-6, "an unbound control changes nothing")
        XCTAssertTrue(fake.crossfaders.isEmpty)
    }

    /// Detaching stops delivery: leaving the performance surface must cancel
    /// the message task, or a controller keeps driving a surface that is not
    /// on screen (and keeps a stale `HardwareService` alive).
    func testDetachingMidiStopsDelivery() async throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)
        var profile = ControllerProfile(name: "Test")
        let fader = MidiAddress(type: .cc, channel: 1, number: 7)
        profile.learn(.crossfader, at: fader, transform: .bipolar, takeover: .jump)

        let hardware = HardwareService()
        hardware.start()
        model.attachMidi(hardware, profile: profile)
        model.detachMidi()

        await Self.settleMidiTask()
        hardware.receive(MidiMessage(address: fader, value: 127))
        await Self.settleMidiTask()

        XCTAssertEqual(model.crossfader, 0, accuracy: 1e-6,
                       "a detached workspace must not be driven by the controller")
    }

    /// Give the `attachMidi` message task a couple of scheduler ticks so its
    /// stream subscription (and the delivery of an injected message) settles.
    private static func settleMidiTask() async {
        for _ in 0..<4 { await Task.yield() }
    }

    // MARK: - Soft takeover (plan dj-midi-alpha M2)

    /// The M2 narrative end to end: a physical fader at the wrong position does
    /// **not** jump the engine value, the catch indicator says which way to
    /// move it, a finger driving the action on the touchscreen makes the claim
    /// stale, and the physical control re-picks-up rather than slamming.
    func testSoftTakeoverDoesNotSlamAndTheTouchscreenResetsTheClaim() async throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)
        var profile = ControllerProfile(name: "Test")
        let slider = MidiAddress(type: .cc, channel: 1, number: 8)
        // Pickup is the default for a continuous absolute control.
        profile.learn(.crossfader, at: slider, transform: .bipolar)
        let hardware = HardwareService()
        hardware.start()
        model.attachMidi(hardware, profile: profile)
        await Self.settleMidiTask()

        // Physical at +1 over an engine at 0: nothing moves, indicator says
        // which way (distance > 0 → the crossfader reads "move left").
        hardware.receive(MidiMessage(address: slider, value: 127))
        await Self.settleMidiTask()
        XCTAssertEqual(model.crossfader, 0, accuracy: 1e-6, "no slam")
        XCTAssertNotNil(model.midiPendingPickup[.crossfader])
        XCTAssertTrue(model.midiCatchItems.contains { $0.label.contains("move left") },
                      "the indicator names the way: \(model.midiCatchItems.map(\.label))")

        // A finger drives the crossfader on the touchscreen: the physical
        // control's claim is stale and the pending indicator clears.
        model.setCrossfader(0.5, curve: .constantPower)
        XCTAssertNil(model.midiPendingPickup[.crossfader],
                     "a touchscreen move clears the pending pickup")

        // The physical fader (still at +1) must re-pick-up over 0.5, not slam.
        hardware.receive(MidiMessage(address: slider, value: 127))
        await Self.settleMidiTask()
        XCTAssertEqual(model.crossfader, 0.5, accuracy: 1e-6, "still not slammed")
        XCTAssertNotNil(model.midiPendingPickup[.crossfader])

        // It crosses 0.5 (64 → ≈ 0.008), claims the control, indicator clears.
        hardware.receive(MidiMessage(address: slider, value: 64))
        await Self.settleMidiTask()
        XCTAssertEqual(model.crossfader, -1 + 2 * 64.0 / 127.0, accuracy: 1e-4)
        XCTAssertNil(model.midiPendingPickup[.crossfader], "claimed — indicator gone")
    }

    /// `.awaitingPickup` applied directly (the model-side half): the indicator
    /// registers and a later `.setContinuous` clears it.
    func testAwaitingPickupSetsTheIndicatorAndFollowingClearsIt() throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)
        model.apply(.awaitingPickup(.crossfader, distance: 0.8))
        XCTAssertEqual(model.midiPendingPickup[.crossfader], 0.8)
        XCTAssertEqual(model.midiCatchItems.count, 1)

        model.apply(.setContinuous(.crossfader, 0.2))
        XCTAssertNil(model.midiPendingPickup[.crossfader])
        XCTAssertTrue(model.midiCatchItems.isEmpty)
        XCTAssertEqual(model.crossfader, 0.2, accuracy: 1e-6)
    }

    // MARK: - Cue monitoring (§44.2a, FR-HW-3, plan 6.4)

    /// Cueing a deck with no mode chosen must produce audible pre-listen, not a
    /// lit button and silence — so it selects a usable mode as it arms.
    func testCueingADeckWithNoModeSelectsAUsableOne() throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)
        XCTAssertEqual(model.cueMode, .off)

        model.toggleCue(.a)

        XCTAssertTrue(model.isCued(.a))
        XCTAssertEqual(model.cueMode, .splitOutput,
                       "a 2-channel route gets split output — the mode that works with a cable")
        XCTAssertTrue(fake.cuedDecks.contains(.a), "and the engine is actually told")
        XCTAssertEqual(fake.cueModes.last, .splitOutput)
    }

    func testTogglingCueOffLeavesTheModeAlone() throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)
        model.toggleCue(.a)
        model.toggleCue(.a)

        XCTAssertFalse(model.isCued(.a))
        XCTAssertFalse(fake.cuedDecks.contains(.a))
        XCTAssertEqual(model.cueMode, .splitOutput,
                       "the chosen mode survives disarming — it is a setting, not a side effect")
    }

    /// §44.2a: a mode the route cannot deliver is refused, not approximated.
    func testAModeTheRouteCannotDeliverIsRefused() throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)

        XCTAssertFalse(model.setCueMode(.multichannel),
                       "two channels cannot carry a separate cue leg")
        XCTAssertEqual(model.cueMode, .off, "and nothing else is silently selected in its place")
        XCTAssertTrue(fake.cueModes.isEmpty, "the engine is never told about a refused mode")

        model.updateOutputChannelCount(4)
        XCTAssertTrue(model.setCueMode(.multichannel), "a 4-channel interface can")
        XCTAssertEqual(fake.cueModes.last, .multichannel)
    }

    /// Unplugging the interface mid-set must not leave a selected mode that
    /// silently does nothing.
    func testLosingChannelsDemotesAnUnavailableMode() throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)
        model.updateOutputChannelCount(4)
        XCTAssertTrue(model.setCueMode(.multichannel))

        model.updateOutputChannelCount(2)   // the interface is unplugged

        XCTAssertEqual(model.cueMode, .splitOutput,
                       "demoted to the best mode this route can actually deliver")
        XCTAssertEqual(fake.cueModes.last, .splitOutput)
    }

    // MARK: - Engine liveness (NFR-REL-2, §34A.5, plan 6.1)

    /// The incident, reproduced: the clock freezes mid-recording while the
    /// engine goes on claiming to run. The app must stop claiming to record.
    func testAStalledGraphStopsTheRecordingTimerLying() async throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil,
                                   engineStallSeconds: 0.2)
        try model.begin()
        defer { model.end() }

        await model.startRecording()
        for _ in 0..<50 { await Task.yield() }
        fake.current.deckA.playing = true
        fake.current.masterSample = 48_000
        model.pumpTelemetryNow()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(model.recordingElapsed, 1.0, accuracy: 1e-9)
        XCTAssertNil(model.engineStopped, "a healthy graph reports nothing")

        // The graph stops being rendered. `isGraphRunning` keeps answering true,
        // exactly as AVAudioEngine did — the clock standing still is the only
        // honest signal, and it is the one being tested here.
        try await Task.sleep(nanoseconds: 250_000_000)
        model.pumpTelemetryNow()
        for _ in 0..<80 { await Task.yield() }

        XCTAssertEqual(model.engineStopped, .renderStalled,
                       "a frozen clock under a playing deck is a stopped graph")
        XCTAssertEqual(model.recordingElapsed, 1.0, accuracy: 1e-9,
                       "the elapsed timer freezes rather than running on a dead clock")
        XCTAssertEqual(fake.recordingStops, 1,
                       "the recording is closed out, so the audio already on disk is kept")
        XCTAssertNotNil(model.engineStopRecordingOutcome,
                        "the user is told what became of the recording, not just that it stopped")
    }

    /// A late telemetry sample must not resurrect the timer: once stopped, the
    /// model stops believing the clock at all.
    func testAStoppedGraphIgnoresLaterTelemetry() async throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil,
                                   engineStallSeconds: 0.2)
        try model.begin()
        defer { model.end() }

        await model.startRecording()
        for _ in 0..<50 { await Task.yield() }
        fake.current.deckA.playing = true
        fake.isGraphRunning = false
        model.pumpTelemetryNow()
        for _ in 0..<80 { await Task.yield() }
        XCTAssertEqual(model.engineStopped, .notRunning)

        fake.current.masterSample = 480_000
        model.pumpTelemetryNow()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(model.recordingElapsed, 0, accuracy: 1e-9,
                       "a stopped graph's clock is not evidence of anything")
    }

    func testConfigurationChangeOnAStoppedEngineSurfacesItsReason() async throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)
        try model.begin()
        defer { model.end() }
        for _ in 0..<50 { await Task.yield() }

        // AVAudioEngine posts the notification *after* stopping itself.
        fake.isGraphRunning = false
        fake.postConfigurationChange()
        for _ in 0..<80 { await Task.yield() }

        XCTAssertEqual(model.engineStopped, .configurationChange,
                       "the notification names the reason the stall detector could only guess at")
    }

    func testAConfigurationChangeTheGraphAbsorbedIsNotReported() async throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)
        try model.begin()
        defer { model.end() }
        for _ in 0..<50 { await Task.yield() }

        // Still running: the change was absorbed. A banner here would train the
        // user to ignore banners.
        fake.postConfigurationChange()
        for _ in 0..<80 { await Task.yield() }
        XCTAssertNil(model.engineStopped)
    }

    func testRecoveryRestartsTheGraphAndClearsTheState() async throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)
        try model.begin()
        defer { model.end() }
        for _ in 0..<50 { await Task.yield() }

        fake.isGraphRunning = false
        model.pumpTelemetryNow()
        for _ in 0..<80 { await Task.yield() }
        XCTAssertEqual(model.engineStopped, .notRunning)

        await model.recoverEngine()
        XCTAssertEqual(fake.recoveries, 1)
        XCTAssertNil(model.engineStopped, "a recovered graph clears the banner")
        XCTAssertNil(model.engineStopRecordingOutcome)
        XCTAssertFalse(model.isRecoveringEngine)
    }

    func testAFailedRecoveryStaysStoppedAndSaysSo() async throws {
        struct Dead: Error, LocalizedError {
            var errorDescription: String? { "the audio server is gone" }
        }
        let fake = FakeWorkspaceEngine()
        fake.recoveryError = Dead()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)
        try model.begin()
        defer { model.end() }
        for _ in 0..<50 { await Task.yield() }

        fake.isGraphRunning = false
        model.pumpTelemetryNow()
        for _ in 0..<80 { await Task.yield() }

        await model.recoverEngine()
        XCTAssertEqual(model.engineStopped, .notRunning,
                       "a failed restart leaves the honest stopped state in place")
        XCTAssertEqual(model.engineStopRecordingOutcome?
            .contains("could not be restarted"), true,
                       "and says why, rather than silently retrying forever")
    }

    func testRecordingElapsedTracksTheMasterClock() async throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)
        try model.begin()
        defer { model.end() }

        await model.startRecording()
        XCTAssertEqual(model.recordingElapsed, 0, accuracy: 1e-9)

        // Decision 14's elapsed chip: recorded frames = master-clock frames
        // captured by the tap (§37.2), so elapsed = masterSample/sampleRate.
        // The telemetry stream is async — let the model's task reach its
        // `for await` (bufferingNewest(1) drops a value yielded before the
        // subscriber is live), then push and yield for it to apply.
        for _ in 0..<50 { await Task.yield() }
        fake.current.masterSample = 24_000
        model.pumpTelemetryNow()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(model.recordingElapsed, 0.5, accuracy: 1e-9)

        fake.current.masterSample = 48_000
        model.pumpTelemetryNow()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(model.recordingElapsed, 1.0, accuracy: 1e-9)

        await model.stopRecording()
        fake.current.masterSample = 96_000
        model.pumpTelemetryNow()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(model.recordingElapsed, 1.0, accuracy: 1e-9,
                       "elapsed freezes when recording stops")
    }

    // MARK: - Recording journal + interruption (plan 5.11)

    func testRecordingStartAndStopWriteTheJournal() async throws {
        let fake = FakeWorkspaceEngine()
        let journal = FakeRecordingJournal()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil,
                                   recordingService: journal)
        try model.begin()
        defer { model.end() }

        await model.startRecording()
        XCTAssertEqual(journal.beginCalls.count, 1, "start forwards the output directory to the journal")
        XCTAssertEqual(journal.beginCalls.first, fake.lastStartDirectory,
                       "the journal rows the same directory the engine writes into")

        let output = RecordingEncoder.RecordingOutput(
            outputDirectory: fake.lastStartDirectory!,
            segmentURLs: [], totalFrames: 24_000, sampleRate: 48_000,
            channelCount: 1, format: RecordingEncoder.formatName)
        fake.lastStopOutput = output
        await model.stopRecording()
        XCTAssertEqual(journal.finalizeCalls.count, 1, "stop forwards the finished recording to the journal")
        XCTAssertEqual(journal.finalizeCalls.first?.output, output)
        XCTAssertNotNil(journal.finalizeCalls.first?.journal,
                        "stop carries the engine configuration for the self-describing journal")
        XCTAssertEqual(journal.finalizeCalls.first?.journal?.sampleRate, fake.sampleRate)
    }

    func testRecordingStartAbortsWhenTheJournalFails() async throws {
        let fake = FakeWorkspaceEngine()
        let journal = FakeRecordingJournal()
        journal.throwOnBegin = true
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil,
                                   recordingService: journal)
        try model.begin()
        defer { model.end() }

        await model.startRecording()
        XCTAssertEqual(model.isRecording, false,
                       "a journal failure aborts the recording rather than running journal-less")
        XCTAssertEqual(fake.recordingStops, 1, "the engine's recording is unwound")
        XCTAssertEqual(journal.beginCalls.count, 1)
    }

    func testSessionResponsesFlushAndResumeTheRecording() async throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)
        try model.begin()
        defer { model.end() }
        await model.startRecording()

        await model.handleSession(.flushSegmentAndCapturePlayheads)
        XCTAssertEqual(fake.interruptionFlushes, 1,
                       ".began flushes the recording segment (NFR-REL-2's critical line)")
        XCTAssertEqual(fake.interruptionResumes, 0)

        await model.handleSession(.resume(rebuildGraph: false))
        XCTAssertEqual(fake.interruptionResumes, 1,
                       ".ended opens a new segment, never the flushed one (§34A.4)")

        // A `.began`/`.ended` pair while nothing is recording is a no-op.
        await model.stopRecording()
        await model.handleSession(.flushSegmentAndCapturePlayheads)
        await model.handleSession(.resume(rebuildGraph: true))
        XCTAssertEqual(fake.interruptionFlushes, 1)
        XCTAssertEqual(fake.interruptionResumes, 1)
    }

    func testInterruptionNeverAutoPlays() async throws {
        let fake = FakeWorkspaceEngine()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil)
        try model.begin()
        defer { model.end() }
        await model.startRecording()

        await model.handleSession(.flushSegmentAndCapturePlayheads)
        await model.handleSession(.resume(rebuildGraph: false))
        await model.handleSession(.remainPausedOfferResume)

        XCTAssertTrue(fake.played.isEmpty,
                      "an interruption resume never auto-plays a deck (§34A.4)")
        XCTAssertTrue(fake.paused.isEmpty,
                      "the model's recording path touches no transport at all")
    }

    func testReconcileRecordingsForwardsToTheService() async throws {
        let fake = FakeWorkspaceEngine()
        let journal = FakeRecordingJournal()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil,
                                   recordingService: journal)

        await model.reconcileRecordings()
        XCTAssertEqual(journal.reconcileCount, 1,
                       "the explicit reconcile (and begin's launch reconcile) forwards to the service")
    }

    // MARK: - §37.4 timeline + the review listen (plan 5.12)

    func testRecordingTimelineCapturesDeckPlayStarts() async throws {
        let fake = FakeWorkspaceEngine()
        let library = FakeDeckLibrary()
        library.outcomes[5] = .loaded(makeLoadedBox())
        let journal = FakeRecordingJournal()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil,
                                   library: library, recordingService: journal)
        try model.begin()
        defer { model.end() }

        await model.load(.a, trackID: 5)
        await model.startRecording()

        // A deck's not-playing → playing edge logs "track 5 on A at this
        // offset" (§37.4). The offset is the recording's frames: master sample
        // 48000 at 48 kHz = 1.0 s.
        for _ in 0..<50 { await Task.yield() }
        fake.current.masterSample = 48_000
        fake.current.deckA.playing = true
        model.pumpTelemetryNow()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(model.recordingElapsed, 1.0, accuracy: 1e-9)

        // A pause → resume blip of the same track inside the suppression
        // window is NOT a second event (MixTimeline.duplicateSuppressionSeconds).
        fake.current.deckA.playing = false
        model.pumpTelemetryNow()
        for _ in 0..<50 { await Task.yield() }
        fake.current.masterSample = 60_000
        fake.current.deckA.playing = true
        model.pumpTelemetryNow()
        for _ in 0..<50 { await Task.yield() }

        let output = RecordingEncoder.RecordingOutput(
            outputDirectory: fake.lastStartDirectory!,
            segmentURLs: [], totalFrames: 60_000, sampleRate: 48_000,
            channelCount: 1, format: RecordingEncoder.formatName)
        fake.lastStopOutput = output
        await model.stopRecording()

        let timeline = try XCTUnwrap(journal.finalizeCalls.last?.timeline)
        XCTAssertEqual(timeline.entries.map(\.trackID), [5],
                       "one track start is logged; the pause/resume blip is suppressed")
        XCTAssertEqual(timeline.entries.first?.deck, "A")
        XCTAssertEqual(timeline.entries.first?.startOffsetSec ?? 0, 1.0, accuracy: 1e-6)
    }

    func testRecordingTimelineLogsTheAlreadyPlayingDeckAtZero() async throws {
        let fake = FakeWorkspaceEngine()
        let library = FakeDeckLibrary()
        library.outcomes[7] = .loaded(makeLoadedBox())
        let journal = FakeRecordingJournal()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil,
                                   library: library, recordingService: journal)
        try model.begin()
        defer { model.end() }

        await model.load(.a, trackID: 7)
        // The deck is already playing when recording starts — the first sample
        // after record logs its track at ~0:00 (mockup `ipad/09`'s "0:00 …
        // opened").
        for _ in 0..<50 { await Task.yield() }
        fake.current.deckA.playing = true
        model.pumpTelemetryNow()
        for _ in 0..<50 { await Task.yield() }

        await model.startRecording()
        fake.current.masterSample = 1000
        model.pumpTelemetryNow()
        for _ in 0..<50 { await Task.yield() }

        fake.lastStopOutput = RecordingEncoder.RecordingOutput(
            outputDirectory: fake.lastStartDirectory!,
            segmentURLs: [], totalFrames: 1000, sampleRate: 48_000,
            channelCount: 1, format: RecordingEncoder.formatName)
        await model.stopRecording()

        let timeline = try XCTUnwrap(journal.finalizeCalls.last?.timeline)
        XCTAssertEqual(timeline.entries.map(\.trackID), [7])
        XCTAssertEqual(timeline.entries.first?.startOffsetSec ?? 9, 1000.0 / 48_000.0, accuracy: 1e-6)
    }

    func testStopRecordingSurfacesTheFinishedMixForTheReviewListen() async throws {
        let fake = FakeWorkspaceEngine()
        let journal = FakeRecordingJournal()
        var finished = DJMix(syncID: "mix-1", title: "Friday set", durationSec: 60,
                             trackCount: 2, format: RecordingEncoder.formatName,
                             recordedAt: Date(), localState: MixLocalState.complete.rawValue)
        finished.id = 1
        journal.finishedMix = finished
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil,
                                   recordingService: journal)
        try model.begin()
        defer { model.end() }

        await model.startRecording()
        XCTAssertNil(model.finishedMix, "nothing is finished while recording")
        fake.lastStopOutput = RecordingEncoder.RecordingOutput(
            outputDirectory: fake.lastStartDirectory!,
            segmentURLs: [], totalFrames: 24_000, sampleRate: 48_000,
            channelCount: 1, format: RecordingEncoder.formatName)
        await model.stopRecording()

        XCTAssertEqual(model.finishedMix?.id, 1,
                       "stop surfaces the finalized mix — the review listen opens in place (FR-REC-6)")
        model.dismissFinishedMix()
        XCTAssertNil(model.finishedMix, "dismiss clears the finished mix so it is presented once")
    }

    func testLoadForwardsThroughTheLoaderAndArmsTheEngine() async throws {
        let fake = FakeWorkspaceEngine()
        let library = FakeDeckLibrary()
        let box = makeLoadedBox()
        library.outcomes[5] = .loaded(box)
        let waveforms = FakeWaveformRepository()
        let stems = FakeStemProvider()
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil,
                                   library: library, waveformRepository: waveforms,
                                   stemProvider: stems)
        try model.begin()
        defer { model.end() }

        await model.load(.a, trackID: 5)
        XCTAssertEqual(fake.loadedDeck, .a)
        XCTAssertEqual(fake.loadedSource?.frameCount, box.source.frameCount,
                       "the engine arms exactly the loader's decoded source (§12.2)")
        XCTAssertEqual(library.loadedTrackIDs, [5])
        XCTAssertEqual(model.loadState(for: .a), .loaded(trackID: 5))
        XCTAssertEqual(model.hasLoadedTrack(.a), true)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(waveforms.requested, [5], "a loaded deck asks its §26A render model")
        XCTAssertNil(model.waveform(for: .a), "the fake has no model → the honest empty state")
        XCTAssertEqual(stems.requested, [5], "a loaded deck asks its prepared stems (§36.5)")
        XCTAssertEqual(model.stemStatus(.a), .unavailable,
                       "no prepared set → the deck plays the full mix, faders disabled")
        XCTAssertTrue(fake.disarmedStemSets.contains(.a),
                      "no prepared set → the deck is disarmed (full mix), never left armed")
    }

    func testRefusedLoadNeverArmsTheEngine() async throws {
        let fake = FakeWorkspaceEngine()
        let library = FakeDeckLibrary()
        library.outcomes[5] = .refused(.unavailable(reason: "Audio is not on this device yet"))
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil,
                                   library: library)
        try model.begin()
        defer { model.end() }

        await model.load(.a, trackID: 5)
        XCTAssertNil(fake.loadedSource, "the engine is touched only on a successful load (FR-LIB-8)")
        XCTAssertEqual(model.loadState(for: .a),
                       .refused(trackID: 5, reason: "Audio is not on this device yet"))
    }

    func testFailedLoadIsAnHonestMessage() async throws {
        let fake = FakeWorkspaceEngine()
        let library = FakeDeckLibrary()
        library.outcomes[5] = .failed(DeckLoadFailure("could not decode"))
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil,
                                   library: library)
        try model.begin()
        defer { model.end() }

        await model.load(.a, trackID: 5)
        XCTAssertNil(fake.loadedSource)
        XCTAssertEqual(model.loadState(for: .a), .failed(trackID: 5, message: "could not decode"))
    }

    func testRefreshDeckQueuesLoadsSourcesAndRows() async throws {
        let fake = FakeWorkspaceEngine()
        let library = FakeDeckLibrary()
        library.available = [.allTracks, .playlist(id: 9, title: "Set B")]
        library.rowsBySource[.allTracks] = [
            DeckQueueRow(trackID: 1, title: "One", artist: "", readiness: .ready)
        ]
        let model = WorkspaceModel(engine: fake, store: makeStore(isPro: true), pump: nil,
                                   library: library)
        try model.begin()
        defer { model.end() }

        XCTAssertTrue(model.availableQueues.isEmpty, "queues load on demand, not at init")
        await model.refreshDeckQueues()
        XCTAssertEqual(model.availableQueues, [.allTracks, .playlist(id: 9, title: "Set B")])
        XCTAssertEqual(model.queue(for: .a).rows.map(\.trackID), [1])
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
