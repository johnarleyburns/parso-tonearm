import XCTest
import Combine
@testable import TonearmCore
@testable import TonearmDJ

/// M5 commit 5.13 — the §41.18 transition coach (FR-TRANS-6, mockup
/// `ipad/16-transitions.html`, plan §5.13). Model-level tests per the plan:
///
/// - the **control set each transition names matches §35B's table** — the
///   coach reads the same `transitionRoleSets` the AT-TRANS layout assertions
///   use, so it cannot teach a transition the surface cannot perform;
/// - the **highlight set names the real controls** (§41.18's "highlighted in
///   place") — the §53.11 identifiers the surfaces actually carry, not
///   illustration labels;
/// - the **panel changes no engine state** — the 4.10 drawer precedent:
///   presenting, selecting and dismissing the coach leaves a recording engine
///   untouched;
/// - it is **free tier** — no entitlement seam (FR-TRANS-6 is `[F]`).
@MainActor
final class TransitionCoachTests: XCTestCase {

    // MARK: - The §35B five (control set matches the table)

    func testCoachTeachesExactlyTheSection35BFive() {
        XCTAssertEqual(TransitionCoachModel.allLessons.map(\.id),
                       ["Bass Swap", "Filter Transition", "Echo Out", "Fader Cut",
                        "Blend / Mix"],
                       "the coach teaches exactly the §35B five, in table order")
    }

    func testEachLessonControlSetMatchesTheSection35BTable() {
        // The coach's lessons and the §35B role table must stay identical —
        // a lesson that drifts from the table would teach a control the
        // transition doesn't use (or miss one it needs).
        XCTAssertEqual(TransitionCoachModel.allLessons.count,
                       WorkspaceModel.transitionRoleSets.count)
        for lesson in TransitionCoachModel.allLessons {
            let row = WorkspaceModel.transitionRoleSets.first { $0.transition == lesson.id }
            XCTAssertNotNil(row, "\(lesson.id) must be a §35B row")
            XCTAssertEqual(lesson.roles, row?.roles,
                           "\(lesson.id)'s control set must match §35B's table")
        }
    }

    func testEverySection35BRoleIsTaughtBySomeLesson() {
        // Every role the §35B table names is covered by at least one lesson —
        // the coach can't leave a transition's control untaught.
        let taught = Set(TransitionCoachModel.allLessons.flatMap(\.roles))
        XCTAssertEqual(taught, Set(WorkspaceModel.TransitionRole.allCases),
                       "the five lessons together teach every role the transitions use")
    }

    func testEveryTransitionIsTaughtWithCopy() {
        // §41.18: for each transition a description, when to reach for it, and
        // a control walkthrough — the three pieces of teaching copy.
        for lesson in TransitionCoachModel.allLessons {
            XCTAssertFalse(lesson.summary.isEmpty, "\(lesson.id) needs a description")
            XCTAssertFalse(lesson.whenToUse.isEmpty, "\(lesson.id) needs a 'when to reach for it'")
            XCTAssertFalse(lesson.steps.isEmpty, "\(lesson.id) needs a control walkthrough")
        }
    }

    // MARK: - Highlighting the real controls in place (§41.18)

    func testHighlightSetNamesOnlyRealSurfaceIdentifiers() {
        // "Highlighted in place" made structural: a lesson's highlight set is
        // the §53.11 identifiers the surfaces actually carry — every entry is
        // a `dj.*` identifier, and the per-deck roles light *both* decks.
        for lesson in TransitionCoachModel.allLessons {
            XCTAssertFalse(lesson.controlIdentifiers.isEmpty,
                           "\(lesson.id) must name at least one real control")
            for identifier in lesson.controlIdentifiers {
                XCTAssertTrue(identifier.hasPrefix("dj."),
                              "\(lesson.id) names \(identifier) — must be a §53.11 identifier")
            }
        }
    }

    func testBassSwapHighlightsBothLowEQAndBothFadersAndThePhrase() {
        let bassSwap = TransitionCoachModel.allLessons[0]
        let ids = bassSwap.controlIdentifiers
        XCTAssertTrue(ids.contains("dj.deck.a.eq.low"))
        XCTAssertTrue(ids.contains("dj.deck.b.eq.low"),
                      "a per-deck role lights both decks' controls")
        XCTAssertTrue(ids.contains("dj.deck.a.fader"))
        XCTAssertTrue(ids.contains("dj.deck.b.fader"))
        XCTAssertTrue(ids.contains("dj.phrase"),
                      "the phrase ribbon is highlighted so the boundary is findable")
    }

    func testFilterTransitionHighlightsBothFilterKnobs() {
        let filter = TransitionCoachModel.allLessons[1]
        let ids = filter.controlIdentifiers
        XCTAssertTrue(ids.contains("dj.deck.a.filter"))
        XCTAssertTrue(ids.contains("dj.deck.b.filter"))
        XCTAssertTrue(ids.contains("dj.deck.a.fader"))
    }

    func testEchoOutHighlightsTheEchoAndTheChannelFaders() {
        let echoOut = TransitionCoachModel.allLessons[2]
        let ids = echoOut.controlIdentifiers
        XCTAssertTrue(ids.contains("dj.fx.echo"))
        XCTAssertTrue(ids.contains("dj.deck.a.fader"))
        XCTAssertTrue(ids.contains("dj.deck.b.fader"))
        XCTAssertFalse(ids.contains("dj.mixer.crossfader"),
                       "Echo Out is a fader cut with a tail, not a crossfader")
    }

    func testFaderCutHighlightsTheCrossfader() {
        let cut = TransitionCoachModel.allLessons[3]
        XCTAssertEqual(cut.controlIdentifiers, ["dj.mixer.crossfader"],
                       "Fader Cut is the crossfader's transition")
    }

    func testBlendHighlightsEQWaveformsAndBeatPhase() {
        let blend = TransitionCoachModel.allLessons[4]
        let ids = blend.controlIdentifiers
        XCTAssertTrue(ids.contains("dj.waveform"))
        XCTAssertTrue(ids.contains("dj.master.phase"))
        XCTAssertTrue(ids.contains("dj.deck.a.eq.mid"))
        XCTAssertTrue(ids.contains("dj.deck.b.eq.mid"))
        XCTAssertTrue(ids.contains("dj.deck.a.eq.low"))
        XCTAssertTrue(ids.contains("dj.deck.b.eq.high"))
        XCTAssertTrue(ids.contains("dj.deck.a.fader"))
    }

    // MARK: - Free tier (FR-TRANS-6 [F])

    func testCoachIsFreeTierWithNoEntitlementSeam() {
        // FR-TRANS-6 is free — teaching, not performing. The model holds no
        // store and no engine: it cannot be gated, and opening it cannot
        // depend on or change a purchase. The free workspace surface presents
        // it identically to Pro.
        let coach = TransitionCoachModel()
        coach.present()
        coach.select(2)
        XCTAssertTrue(coach.isPresented)
        XCTAssertEqual(coach.selectedLesson.id, "Echo Out")
        coach.dismiss()
        XCTAssertFalse(coach.isPresented)
    }

    // MARK: - The panel changes no engine state (the 4.10 drawer precedent)

    func testCoachStateChangesTouchNoEngineState() throws {
        // The 4.10 drawer precedent applied to the coach: a recording engine
        // behind the workspace records every call it receives. Presenting,
        // selecting and dismissing the coach must add none.
        let engine = RecordingEngine()
        let model = WorkspaceModel(engine: engine,
                                   store: makeStore(isPro: true),
                                   pump: nil)
        try model.begin()
        defer { model.end() }
        let baseline = engine.calls.count

        let coach = TransitionCoachModel()
        coach.present()
        coach.select(1)
        coach.select(3)
        coach.select(4)
        coach.dismiss()
        coach.present()
        coach.select(2)

        XCTAssertEqual(engine.calls.count, baseline,
                       "the coach's presentation, selection and dismissal touch no engine state")
        XCTAssertTrue(engine.calls.isEmpty == false, "the engine is live behind the surface")
    }

    func testSelectIsClampedToTheFiveLessons() {
        let coach = TransitionCoachModel()
        coach.select(-1)
        XCTAssertEqual(coach.selectedLesson.id, "Bass Swap",
                       "out-of-range selection is ignored — selection stays on the last valid one")
        coach.select(3)
        XCTAssertEqual(coach.selectedLesson.id, "Fader Cut")
        coach.select(99)
        XCTAssertEqual(coach.selectedLesson.id, "Fader Cut",
                       "out-of-range selection is ignored — selection stays on the last valid one")
    }

    func testHighlightedIdentifiersFollowTheSelection() {
        let coach = TransitionCoachModel()
        XCTAssertEqual(coach.highlightedIdentifiers, ["dj.deck.a.eq.low", "dj.deck.b.eq.low",
                                                      "dj.deck.a.fader", "dj.deck.b.fader",
                                                      "dj.phrase"],
                       "the default selection (Bass Swap) lights its controls")
        coach.select(3)
        XCTAssertEqual(coach.highlightedIdentifiers, ["dj.mixer.crossfader"],
                       "selection drives the highlight set")
    }

    // MARK: - Recording fake (the 4.10 precedent's engine)

    /// A `WorkspaceEngine` that records every call — a present coach must add
    /// none. `@unchecked Sendable` because the caller (the test) is the only
    /// user and is MainActor-confined, exactly like `WorkspaceModelTests`'
    /// fake.
    private final class RecordingEngine: WorkspaceEngine, @unchecked Sendable {
        private(set) var calls: [String] = []
        var masterSample: Int64 { 0 }
        var telemetry: AsyncStream<EngineTelemetry> { EngineTelemetryStream().stream }
        var bufferPeriodMillis: Double { 8 }
        var limiterCeiling: Float? { nil }
        var sampleRate: Double { 48_000 }

        func deckRate(_ deck: Deck) -> Double { calls.append("deckRate"); return 1 }
        func start() throws { calls.append("start") }
        func stop() { calls.append("stop") }
        func load(_ deck: Deck, source: DeckSource) { calls.append("load") }
        func play(_ deck: Deck) { calls.append("play") }
        func pause(_ deck: Deck) { calls.append("pause") }
        func cue(_ deck: Deck) { calls.append("cue") }
        func releaseCue(_ deck: Deck) { calls.append("releaseCue") }
        func seek(_ deck: Deck, toSample: Int64, quantized: Bool) { calls.append("seek") }
        func setCue(_ deck: Deck, atSample: Int64) { calls.append("setCue") }
        func triggerHotCue(_ deck: Deck, atSample: Int64) { calls.append("triggerHotCue") }
        func setLoopRange(_ deck: Deck, start: Int64, end: Int64) { calls.append("setLoopRange") }
        func setLoop(_ deck: Deck, beats: Double) { calls.append("setLoop") }
        func exitLoop(_ deck: Deck) { calls.append("exitLoop") }
        func setQuantize(_ on: Bool, resolution: QuantizeResolution) { calls.append("setQuantize") }
        func setRate(_ deck: Deck, rate: Float) { calls.append("setRate") }
        func setKeyLock(_ deck: Deck, locked: Bool) { calls.append("setKeyLock") }
        func setKeyShift(_ deck: Deck, semitones: Float) { calls.append("setKeyShift") }
        func sync(_ deck: Deck, to master: Deck, barSync: Bool) { calls.append("sync") }
        func unsync(_ deck: Deck) { calls.append("unsync") }
        func isSynced(_ deck: Deck) -> Bool { calls.append("isSynced"); return false }
        func setEQKnobs(_ deck: Deck, low: Float, mid: Float, high: Float) { calls.append("setEQ") }
        func setFilter(_ deck: Deck, knob: Float) { calls.append("setFilter") }
        func setChannelFader(_ deck: Deck, gain: Float) { calls.append("setChannelFader") }
        func setCrossfader(_ position: Float, curve: CrossfaderCurve) { calls.append("setCrossfader") }
        func setEchoEnabled(_ deck: Deck, enabled: Bool) { calls.append("setEchoEnabled") }
        func setEchoBeats(_ deck: Deck, beats: Double) { calls.append("setEchoBeats") }
        func setEchoDepth(_ deck: Deck, depth: Float) { calls.append("setEchoDepth") }
        func setEchoFeedback(_ deck: Deck, feedback: Float) { calls.append("setEchoFeedback") }
        func armStemSet(_ deck: Deck, stemSet: StemSet?) { calls.append("armStemSet") }
        func setStemGain(_ deck: Deck, stem: StemKind, gain: Float) { calls.append("setStemGain") }
        func setStemMute(_ deck: Deck, stem: StemKind, muted: Bool) { calls.append("setStemMute") }
        func setStemSolo(_ deck: Deck, stem: StemKind, soloed: Bool) { calls.append("setStemSolo") }
        func startRecording() async throws -> URL { calls.append("startRecording"); return .init(fileURLWithPath: "/tmp") }
        func stopRecording() async throws -> RecordingEncoder.RecordingOutput? { calls.append("stopRecording"); return nil }
        var isRecording: Bool { calls.append("isRecording"); return false }
        func interruptRecordingForInterruption() async throws { calls.append("interrupt") }
        func resumeRecordingFromInterruption() async throws { calls.append("resume") }
        func sampleTelemetry() -> EngineTelemetry { calls.append("sampleTelemetry"); return EngineTelemetry() }
        func pushTelemetry() { calls.append("pushTelemetry") }
    }

    // MARK: - Entitlement store helper

    private struct EmptyEntitlementSource: EntitlementSource {
        func currentTransactions() async throws -> [TransactionFact] { [] }
        func transactionUpdates() -> AsyncStream<TransactionFact> { AsyncStream { _ in } }
    }

    private func makeStore(isPro: Bool) -> EntitlementStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransitionCoachTests-\(UUID().uuidString)", isDirectory: true)
        let cacheURL = dir.appendingPathComponent("entitlement-cache.json")
        EntitlementCacheStore(fileURL: cacheURL).save(
            EntitlementCache(isPro: isPro, source: isPro ? .purchased : .none, timestamp: Date()))
        return EntitlementStore(entitlementSource: EmptyEntitlementSource(),
                                cacheStore: EntitlementCacheStore(fileURL: cacheURL))
    }
}
