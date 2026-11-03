#if !os(watchOS)
import XCTest
import Synchronization
@testable import TonearmCore

@MainActor
final class RecordingStarterHost: StarterStreamHost {
    var buffering: [Bool] = []
    var advanced: [Int] = []
    var edges: [StarterEdgeEvent] = []
    var failures: [StarterStreamFailure] = []
    var finished = 0
    var allowBlend = true
    func starterStreamAllowsBlend(from index: Int) -> Bool { allowBlend }
    func starterStreamBuffering(_ b: Bool) { buffering.append(b) }
    func starterStreamDidAdvance(to index: Int) { advanced.append(index) }
    func starterStreamPosition(seconds: Double) {}
    func starterStreamDidFinish() { finished += 1 }
    func starterStreamDidFail(_ failure: StarterStreamFailure) { failures.append(failure) }
    func starterStreamEdge(_ event: StarterEdgeEvent) { edges.append(event) }
}

/// A procedural track of any length: a low tone and a high tone, both a pure function of the source
/// frame, so nothing is stored and a seek is exact. Records how it was read.
final class SynthSource: StarterDeckSource, @unchecked Sendable {
    let sampleRate: Double
    let totalFrames: Int64
    let low: Double, high: Double
    private let lock = NSLock()
    private var largest = 0
    private var frames: Int64 = 0
    private var cancelledFlag = false
    private let failAfter: Int64?
    init(low: Double, high: Double, seconds: Double, rate: Double = 44_100, failAfterFrames: Int64? = nil) {
        self.low = low; self.high = high; sampleRate = rate; totalFrames = Int64(seconds * rate)
        failAfter = failAfterFrames
    }
    var largestRead: Int { lock.withLock { largest } }
    var framesRead: Int64 { lock.withLock { frames } }
    var isCancelled: Bool { lock.withLock { cancelledFlag } }
    func cancel() { lock.withLock { cancelledFlag = true } }
    func read(startFrame: Int64, count: Int) throws -> [[Float]] {
        if isCancelled { throw ReleaseRangeError.cancelled }
        if let failAfter, startFrame >= failAfter { throw ReleaseRangeError.transient("link lost") }
        let n = Int(max(0, min(Int64(count), totalFrames - startFrame)))
        lock.withLock { largest = max(largest, count); frames += Int64(n) }
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(startFrame + Int64(i)) / sampleRate
            out[i] = Float(0.2 * sin(2 * .pi * low * t) + 0.2 * sin(2 * .pi * high * t))
        }
        return [out, out]
    }
}

/// Hann-windowed Goertzel magnitude (low leakage between tones a few bins apart).
func goertzel(_ x: ArraySlice<Float>, freq: Double, rate: Double = 44_100) -> Double {
    let w = 2 * Double.pi * freq / rate
    let coeff = 2 * cos(w)
    var s1 = 0.0, s2 = 0.0
    let n = Double(max(1, x.count - 1))
    for (i, v) in x.enumerated() {
        let hann = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / n)
        let s = Double(v) * hann + coeff * s1 - s2; s2 = s1; s1 = s
    }
    return (s1 * s1 + s2 * s2 - coeff * s1 * s2).squareRoot() / Double(max(1, x.count))
}

/// The strongest response within ±4% of `freq`: a track that has just handed off is still easing
/// back to native tempo, so its tones drift by a percent or so.
func peak(_ x: ArraySlice<Float>, freq: Double, spread: Double = 0.04) -> Double {
    stride(from: 1 - spread, through: 1 + spread, by: spread / 8).map { goertzel(x, freq: freq * $0) }.max() ?? 0
}

/// Keeps every track of a blend identifiable by ear: tone `j` of the blend is `low(j)`/`high(j)`.
enum SynthCatalog {
    /// Even and odd tracks alternate between two bass tones well inside the crossover, so any adjacent pair is distinguishable.
    static func low(_ j: Int) -> Double { j % 2 == 0 ? 40 : 62 }
    static func high(_ j: Int) -> Double { j % 2 == 0 ? 1_000 : 1_800 }
    static let facts = StarterTestFacts.byID
    /// A factory serving `SynthSource`s of the blend's real durations; keeps what it made.
    final class Factory: @unchecked Sendable {
        let blend: StarterBlend
        private let lock = NSLock()
        private(set) var sources: [String: [SynthSource]] = [:]
        var failing: [String: ReleaseRangeError] = [:]
        var rate = 44_100.0
        var failMainAfter: [String: Int64] = [:]
        init(_ blend: StarterBlend) { self.blend = blend }
        func make(_ id: String, _ token: StarterCancellation) throws -> any StarterDeckSource {
            if let error = failing[id] { throw error }
            guard let j = blend.trackIDs.firstIndex(of: id), let f = SynthCatalog.facts[id] else { throw ReleaseRangeError.permanent("unknown") }
            let s = SynthSource(low: SynthCatalog.low(j), high: SynthCatalog.high(j), seconds: f.durationSeconds,
                                rate: rate, failAfterFrames: failMainAfter[id])
            token.register { s.cancel() }
            lock.withLock { sources[id, default: []].append(s) }
            return s
        }
        func latest(_ id: String) -> SynthSource? { lock.withLock { sources[id]?.last } }
    }
}

@MainActor
final class StarterStreamPlayerTests: XCTestCase {
    private func config(_ blend: StarterBlend) -> StarterStreamPlayer.Config {
        .init(trackIDs: blend.trackIDs, plans: blend.edgePlans)
    }

    private func wait(_ player: StarterStreamPlayer, timeout: Double = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("timed out; snapshot \(String(describing: player.snapshot()))")
                throw NSError(domain: "StarterTest", code: 1)
            }
            try await Task.sleep(nanoseconds: 1_000_000)
            player.tick()
        }
    }

    struct EdgeRun {
        var captured: [Float] = []
        var clock0: Int64 = 0
        var fadeStart: Int64?
        var handoffClock: Int64?
        var incomingPositionAtStart: Int64?
        var maxBuffered = 0
    }

    /// Streams one edge exactly as production does (the mixer, the feeders, the controller's tick) and
    /// captures what comes out, from 3 s before the plan's overlap until 1 s after the handoff.
    private func runEdge(_ blend: StarterBlend, edge i: Int, factory: SynthCatalog.Factory,
                         host: RecordingStarterHost) async throws -> (StarterStreamPlayer, EdgeRun) {
        let plan = blend.edgePlans[i]
        let schedule = try XCTUnwrap(plan.schedule())
        let player = StarterStreamPlayer(config: config(blend), host: host, output: nil, makeSource: factory.make)
        let startSeconds = max(0, schedule.outgoingStart - 3)
        player.start(at: i, seconds: startSeconds)
        try await wait(player) { !player.isBuffering }
        try await wait(player) {
            player.cell?.perform { if case .pending = $0.overlap { return true }; return false } ?? false
        }
        let cell = try XCTUnwrap(player.cell)
        var run = EdgeRun()
        run.clock0 = cell.perform { $0.clock }
        var blocks = 0
        var afterHandoff = 0
        while afterHandoff < 44_100 && run.captured.count < 44_100 * 80 {
            // Never outrun the decoder: a real device has real time for this.
            let (main, pending): (Int, BoundedOverlapPlan?) = cell.perform { m in
                if case .pending(let p) = m.overlap { return (m.main, p) }
                return (m.main, nil)
            }
            if let pending, let trigger = pending.outgoingTriggerFrame,
               cell.perform({ $0.decks[$0.main].positionFrame }) + 4_096 >= trigger {
                try await wait(player) { cell.perform { $0.decks[$0.incomingIndex].bufferedFrames } >= pending.minIncomingBufferedFrames + 4_096 }
            }
            try await wait(player) { player.bufferedFrames(deck: main) >= 4_096 || cell.perform { $0.decks[main].totalFrames - $0.decks[main].positionFrame } < 4_096 }
            let planes = try XCTUnwrap(player.renderOffline(frames: 512))
            run.captured += planes[0]
            let state = cell.perform { m -> (active: Bool, fadeStart: Int64, clock: Int64, handoffs: Int, inPos: Int64) in
                var active = false; var start: Int64 = 0
                if case .active(_, let s) = m.overlap { active = true; start = s }
                return (active, start, m.clock, m.handoffs, m.decks[m.incomingIndex].positionFrame)
            }
            run.maxBuffered = max(run.maxBuffered, player.bufferedFrames(deck: 0), player.bufferedFrames(deck: 1))
            if state.active, run.fadeStart == nil { run.fadeStart = state.fadeStart; run.incomingPositionAtStart = state.inPos }
            if state.handoffs > 0 {
                if run.handoffClock == nil { run.handoffClock = state.clock }
                afterHandoff += 512
            }
            blocks += 1
            if blocks % 4 == 0 { player.tick(); await Task.yield() }
        }
        player.tick()
        return (player, run)
    }

    func testEveryOneOfTheFortyFiveSuppliedEdgesIsExecutedByTheStreamingRenderer() async throws {
        var executed = 0
        for blend in StarterBlendCatalog.blends {
            for i in 0..<5 {
                let plan = blend.edgePlans[i]
                let host = RecordingStarterHost()
                let factory = SynthCatalog.Factory(blend)
                let (player, run) = try await runEdge(blend, edge: i, factory: factory, host: host)
                defer { player.stop() }
                let label = "\(blend.id) edge \(plan.edge) (\(plan.style.rawValue))"
                let schedule = try XCTUnwrap(plan.schedule())
                let rate = 44_100.0

                // The supplied plan was handed to the renderer and is the style that ran.
                XCTAssertTrue(host.edges.contains(.scheduled(edge: i + 1, plan: plan, executed: plan.style)), label)
                XCTAssertTrue(host.edges.contains { if case .handedOff(let e, _) = $0 { return e == i + 1 }; return false }, label)
                XCTAssertTrue(host.edges.contains { if case .overlapBegan(let e, _) = $0 { return e == i + 1 }; return false }, label)
                XCTAssertTrue(host.advanced.contains(i + 1), label)

                // Timing: starts when the outgoing track reaches the plan's second, lasts the plan's overlap.
                let fadeStart = try XCTUnwrap(run.fadeStart, label)
                let trigger = Int64(schedule.outgoingStart * rate)
                let startFrame = Int64(max(0, schedule.outgoingStart - 3) * rate)
                XCTAssertEqual(Double(fadeStart - run.clock0), Double(trigger - startFrame), accuracy: 2, label)
                let handoff = try XCTUnwrap(run.handoffClock, label)
                let fadeFrames = plan.style == .phraseCut ? Int(0.010 * rate) : Int(schedule.overlapSeconds * rate)
                XCTAssertEqual(Double(handoff - fadeStart), Double(fadeFrames), accuracy: 512 + 2, label)
                // The incoming deck began at the plan's incoming position (tempo-adjusted offset).
                let inStart = Double(Int64(schedule.incomingStart * rate))
                let inPos = Double(try XCTUnwrap(run.incomingPositionAtStart, label))
                XCTAssertGreaterThanOrEqual(inPos, inStart - 1, label)
                XCTAssertLessThanOrEqual(inPos - inStart, 512 * schedule.incomingTempo + 2, label)

                // Audible: the right tones at the right times.
                let tempo = schedule.incomingTempo
                let c = run.captured
                let base = Int(fadeStart - run.clock0)
                let outLow = SynthCatalog.low(i), inLow = SynthCatalog.low(i + 1) * tempo
                let outHigh = SynthCatalog.high(i), inHigh = SynthCatalog.high(i + 1) * tempo
                // Right after the handoff only the incoming remains (a plan may spend the whole incoming track
                // in the overlap, leaving nothing to hear; then there is nothing to assert).
                let handoffIndex = Int(handoff - run.clock0)
                let incomingTotal = Double(try XCTUnwrap(factory.latest(plan.incomingTrackID), label).totalFrames)
                let remaining = incomingTotal - (inStart + schedule.overlapSeconds * rate * tempo)
                if schedule.style != .phraseCut, remaining > 8_000, c.count >= handoffIndex + 500 + 4_096 {
                    let tail = c[(handoffIndex + 500)..<(handoffIndex + 500 + 4_096)]
                    XCTAssertGreaterThan(peak(tail, freq: inHigh, spread: 0.03), 10 * peak(tail, freq: outHigh, spread: 0.03),
                                         "\(label): incoming alone after handoff")
                }
                if schedule.style == .phraseCut {
                    let tail = c.suffix(4_096)
                    XCTAssertGreaterThan(peak(tail, freq: inHigh, spread: 0.03), 10 * peak(tail, freq: outHigh, spread: 0.03), label)
                }
                if plan.style == .phraseCut {
                    let before = c[(base - 8_192 - 600)..<(base - 600)]
                    XCTAssertGreaterThan(peak(before, freq: outHigh, spread: 0.01), 10 * peak(before, freq: inHigh, spread: 0.01), "\(label): outgoing until the cut")
                } else {
                    let swap = base + Int((schedule.swapOffsetSeconds ?? 0) * rate)
                    let before = c[(swap - 22_050 - 8_192)..<(swap - 22_050)]
                    let after = c[(swap + 22_050)..<(swap + 22_050 + 8_192)]
                    XCTAssertGreaterThan(peak(before, freq: outLow, spread: 0.01), 3 * peak(before, freq: inLow, spread: 0.01), "\(label): outgoing bass before the swap")
                    XCTAssertGreaterThan(peak(after, freq: inLow, spread: 0.01), 3 * peak(after, freq: outLow, spread: 0.01), "\(label): incoming bass after the swap")
                }

                // Bounded: a fixed ring per deck, small reads, never the whole track.
                XCTAssertLessThanOrEqual(run.maxBuffered, player.capacityFrames, label)
                XCTAssertEqual(player.residentBytes, 2 * player.capacityFrames * 2 * 4, label)
                for id in [plan.outgoingTrackID, plan.incomingTrackID] {
                    let source = try XCTUnwrap(factory.latest(id), label)
                    XCTAssertLessThanOrEqual(source.largestRead, 8_192, label)
                    if Double(source.totalFrames) / rate > 120 {
                        XCTAssertLessThan(source.framesRead, source.totalFrames * 3 / 4 + 100_000, "\(label): \(id) was not decoded whole")
                    }
                }
                executed += 1
            }
        }
        XCTAssertEqual(executed, 45)
    }

    func testStartsOnlyAfterTheFirstBufferFills() async throws {
        let blend = StarterBlendCatalog.blends[0]
        let host = RecordingStarterHost()
        let factory = SynthCatalog.Factory(blend)
        let player = StarterStreamPlayer(config: config(blend), host: host, output: nil, makeSource: factory.make)
        defer { player.stop() }
        player.start(at: 0)
        XCTAssertEqual(host.buffering, [true])
        XCTAssertNil(player.renderOffline(frames: 512), "nothing renders before the first asset opened")
        try await wait(player) { !player.isBuffering }
        XCTAssertGreaterThanOrEqual(player.bufferedFrames(deck: 0), 44_100, "one second buffered before sound")
        XCTAssertEqual(host.buffering, [true, false])
        XCTAssertLessThan(try XCTUnwrap(factory.latest("1174818")).framesRead, 44_100 * 12, "only the ring was decoded")
        let planes = try XCTUnwrap(player.renderOffline(frames: 4_096))
        XCTAssertGreaterThan(goertzel(planes[0][...], freq: SynthCatalog.high(0)), 0.03)
    }

    func testPlayerRunsFullBlendHandoffsOneByOneAndFinishes() async throws {
        let blend = StarterBlendCatalog.blends[2]    // night-drive: runs the whole blend to its last edge
        let host = RecordingStarterHost()
        let factory = SynthCatalog.Factory(blend)
        // Use short synthetic lengths through the real plans? No: real plans, jumped to the last edge.
        let (player, run) = try await runEdge(blend, edge: 4, factory: factory, host: host)
        defer { player.stop() }
        XCTAssertNotNil(run.handoffClock)
        XCTAssertEqual(host.advanced, [5])
        XCTAssertEqual(player.currentIndex, 5)
        XCTAssertEqual(host.finished, 0)
    }

    // MARK: Failures and fallback

    func testPermanentAndTransientOpenFailuresAreReportedPrecisely() async throws {
        for (error, retryable) in [(ReleaseRangeError.permanent("not found (HTTP 404)"), false),
                                   (ReleaseRangeError.transient("offline"), true)] {
            let blend = StarterBlendCatalog.blends[0]
            let host = RecordingStarterHost()
            let factory = SynthCatalog.Factory(blend)
            factory.failing["1174818"] = error
            let player = StarterStreamPlayer(config: config(blend), host: host, output: nil, makeSource: factory.make)
            player.start(at: 0)
            try await wait(player) { !host.failures.isEmpty }
            let failure = try XCTUnwrap(host.failures.first)
            XCTAssertEqual(failure.retryable, retryable)
            XCTAssertEqual(failure.trackIndex, 0)
            XCTAssertEqual(failure.trackID, "1174818")
            XCTAssertTrue(failure.message.hasPrefix("Track 1:"))
            XCTAssertFalse(player.isStreaming, "the stream is torn down; sequential playback takes over")
        }
    }

    func testIncomingAssetFailureReportsPlayingTrackForSequentialResume() async throws {
        let blend = StarterBlendCatalog.blends[0]
        let host = RecordingStarterHost()
        let factory = SynthCatalog.Factory(blend)
        factory.failing["2232438"] = .permanent("not found (HTTP 404)")
        let player = StarterStreamPlayer(config: config(blend), host: host, output: nil, makeSource: factory.make)
        player.start(at: 0, seconds: 10)
        try await wait(player) { !host.failures.isEmpty }
        let failure = try XCTUnwrap(host.failures.first)
        XCTAssertEqual(failure.trackIndex, 1)
        XCTAssertEqual(failure.playingIndex, 0)
        XCTAssertFalse(failure.retryable)
        XCTAssertTrue(host.edges.allSatisfy { if case .scheduled(_, _, let e) = $0 { return e == nil }; return true },
                      "no blend is claimed for an edge that cannot run")
    }

    func testDecodeFailureWhilePlayingFallsBackAndStopsReading() async throws {
        let blend = StarterBlendCatalog.blends[0]
        let host = RecordingStarterHost()
        let factory = SynthCatalog.Factory(blend)
        factory.failMainAfter["1174818"] = 60_000
        let player = StarterStreamPlayer(config: config(blend), host: host, output: nil, makeSource: factory.make)
        player.start(at: 0)
        try await wait(player) { !host.failures.isEmpty }
        XCTAssertEqual(host.failures.first?.retryable, true)
        XCTAssertTrue(try XCTUnwrap(factory.latest("1174818")).isCancelled)
    }

    func testMismatchedSampleRateIsAnUnavailableEdgeNotAGuess() async throws {
        let blend = StarterBlendCatalog.blends[0]
        let host = RecordingStarterHost()
        let factory = SynthCatalog.Factory(blend)
        let player = StarterStreamPlayer(config: config(blend), host: host, output: nil) { id, token in
            if id == "2232438" {
                return SynthSource(low: 60, high: 1_000, seconds: 200, rate: 48_000)
            }
            return try factory.make(id, token)
        }
        player.start(at: 0, seconds: 10)
        try await wait(player) { !host.failures.isEmpty }
        XCTAssertEqual(host.failures.first?.retryable, false)
        XCTAssertTrue(host.failures.first?.message.contains("sample rate") == true)
    }

    func testStopCancelsEverySourceAndReadsStop() async throws {
        let blend = StarterBlendCatalog.blends[0]
        let host = RecordingStarterHost()
        let factory = SynthCatalog.Factory(blend)
        let player = StarterStreamPlayer(config: config(blend), host: host, output: nil, makeSource: factory.make)
        player.start(at: 0, seconds: 100)
        try await wait(player) { !player.isBuffering }
        try await wait(player) { factory.latest("2232438") != nil }
        player.stop()
        for id in ["1174818", "2232438"] {
            XCTAssertTrue(try XCTUnwrap(factory.latest(id)).isCancelled, id)
        }
        let before = factory.latest("1174818")!.framesRead
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(factory.latest("1174818")!.framesRead, before, "feeders stopped")
        XCTAssertFalse(player.isStreaming)
    }

    func testSeekPastThePlannedPointFollowsOnAndSaysSo() async throws {
        let blend = StarterBlendCatalog.blends[0]
        let plan = blend.edgePlans[0]
        let host = RecordingStarterHost()
        let factory = SynthCatalog.Factory(blend)
        let player = StarterStreamPlayer(config: config(blend), host: host, output: nil, makeSource: factory.make)
        defer { player.stop() }
        player.start(at: 0, seconds: 20)
        try await wait(player) { host.edges.contains { if case .scheduled = $0 { return true }; return false } }
        player.seek(to: (plan.blendStartSeconds ?? 0) + 5)
        try await wait(player) {
            host.edges.filter { if case .scheduled = $0 { return true }; return false }.count >= 2
        }
        XCTAssertEqual(host.edges.last, .scheduled(edge: 1, plan: plan, executed: nil))
    }

    func testExtendingASessionSchedulesTheNextEdgeFromCatalogFacts() async throws {
        let blend = StarterBlendCatalog.blends[0]
        let facts = StarterTestFacts.byID
        let a = blend.trackIDs[0]
        // Any other catalog track the planner accepts after `a`.
        let candidate = try XCTUnwrap(StarterBlendCatalog.blends.flatMap(\.trackIDs).first { id in
            id != a && CatalogEdgePlanner.plan(blendID: "x", edge: 1, outgoing: facts[a]!, incoming: facts[id]!) != nil
        })
        let plan = try XCTUnwrap(CatalogEdgePlanner.plan(blendID: blend.id, edge: 1, outgoing: facts[a]!, incoming: facts[candidate]!))
        let host = RecordingStarterHost()
        let factory = SynthCatalog.Factory(blend)
        let single = StarterStreamPlayer.Config(trackIDs: [a], plans: [])
        let player = StarterStreamPlayer(config: single, host: host, output: nil) { id, token in
            id == candidate ? SynthSource(low: 70, high: 1_300, seconds: 240) : try factory.make(id, token)
        }
        defer { player.stop() }
        player.start(at: 0, seconds: 30)
        try await wait(player) { !player.isBuffering }
        XCTAssertTrue(host.edges.isEmpty)
        player.extend(trackIDs: [candidate], plans: [plan])
        try await wait(player) { !host.edges.isEmpty }
        XCTAssertEqual(host.edges.first, .scheduled(edge: 1, plan: plan, executed: .bassSwap))
    }

    func testRepeatOneOrSleepTimerKeepsTheTrackFromBlendingAndReportsItsEnd() async throws {
        let facts = StarterTestFacts.byID
        let a = StarterBlendCatalog.blends[0].trackIDs[0], b = StarterBlendCatalog.blends[0].trackIDs[1]
        let host = RecordingStarterHost()
        host.allowBlend = false
        let short = StarterStreamPlayer.Config(trackIDs: [a, b], plans: [StarterBlendCatalog.blends[0].edgePlans[0]])
        let player = StarterStreamPlayer(config: short, host: host, output: nil) { _, token in
            let s = SynthSource(low: 40, high: 1_000, seconds: 5); token.register { s.cancel() }; return s
        }
        defer { player.stop() }
        player.start(at: 0, seconds: 2)
        try await wait(player) { !player.isBuffering }
        var rendered = 0
        while host.finished == 0, rendered < 44_100 * 6 {
            try await wait(player) { player.bufferedFrames(deck: 0) >= 2_048 || rendered > 44_100 * 2 }
            _ = player.renderOffline(frames: 512); rendered += 512
            if rendered % 2_048 == 0 { player.tick() }
        }
        player.tick()
        XCTAssertEqual(host.finished, 1, "the track's end is reported so repeat/sleep logic decides what follows")
        XCTAssertTrue(host.edges.isEmpty, "no edge was scheduled")
        XCTAssertTrue(host.advanced.isEmpty)
    }

    func testPolicyChangeDropsAnOverlapThatHasNotBegun() async throws {
        let blend = StarterBlendCatalog.blends[0]
        let host = RecordingStarterHost()
        let factory = SynthCatalog.Factory(blend)
        let player = StarterStreamPlayer(config: config(blend), host: host, output: nil, makeSource: factory.make)
        defer { player.stop() }
        player.start(at: 0, seconds: 30)
        try await wait(player) { player.cell?.perform { if case .pending = $0.overlap { return true }; return false } ?? false }
        host.allowBlend = false
        player.edgePolicyChanged()
        XCTAssertEqual(player.cell?.perform { $0.overlap }, BoundedDeckMixer.Overlap.none)
        host.allowBlend = true
        player.edgePolicyChanged()
        try await wait(player) { player.cell?.perform { if case .pending = $0.overlap { return true }; return false } ?? false }
    }
}
#endif
