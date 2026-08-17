import XCTest
import AVFoundation

@testable import TonearmDJ

/// Commit 4.1–4.3 — the RT boundary and the single-deck play/cue/loop engine
/// under test (plan §5, spec §12/§30/§33/§46.2–46.3).
///
/// Four tiers:
/// - pure boundary tests: the SPSC command ring (FIFO, full/empty, pointer
///   payload), the double-buffered snapshot (publish/read/retire), the RTGuard
///   shim, and `RenderLoad` metering;
/// - pure scheduler/cue-loop math: quantize boundaries, trigger frames, loop
///   length conversion, the CDJ temp-cue state machine;
/// - the offline-render harness: a manual-rendering `AVAudioEngine` graph with
///   a deck reader driven only through the command ring, with the RTGuard shim
///   active. Assertions are sample-referenced (AT-ENGINE-\*): a cue lands on
///   the exact frame, a loop wraps `end → start` frame-exact, a quantized
///   trigger lands on the grid boundary, playhead telemetry is exact, a
///   deck with no buffer renders silence not garbage (§46.2), and a long
///   render never overruns.
@MainActor
final class EngineOfflineTests: XCTestCase {

    // MARK: - Command ring

    func testRingPushDrainPreservesOrderAndValues() {
        let ring = CommandRing(capacity: 8)
        for rate in [1.0, 1.05, 1.1, 1.15, 1.2] {
            XCTAssertTrue(ring.tryPush(.setRate(deck: 0, rate: Float(rate))))
        }
        XCTAssertEqual(ring.count, 5)

        var received: [Float] = []
        let drained = ring.drain { received.append($0.f0) }
        XCTAssertEqual(drained, 5)
        XCTAssertEqual(received, [1.0, 1.05, 1.1, 1.15, 1.2])
        XCTAssertTrue(ring.isEmpty)
        XCTAssertEqual(ring.count, 0)
    }

    func testRingFullReturnsFalseAndDrainRecovers() {
        let ring = CommandRing(capacity: 4)
        for _ in 0..<4 {
            XCTAssertTrue(ring.tryPush(.play(deck: 0)))
        }
        XCTAssertEqual(ring.count, 4)
        XCTAssertFalse(ring.tryPush(.pause(deck: 0)), "full ring must reject a push")
        XCTAssertEqual(ring.count, 4)

        var applied = 0
        XCTAssertEqual(ring.drain { _ in applied += 1 }, 4)
        XCTAssertEqual(applied, 4)
        XCTAssertTrue(ring.isEmpty)

        XCTAssertTrue(ring.tryPush(.play(deck: 1)), "ring must accept pushes again after draining")
        XCTAssertEqual(ring.count, 1)
    }

    func testRingDrainEmptyIsNoOp() {
        let ring = CommandRing(capacity: 8)
        XCTAssertEqual(ring.drain { _ in XCTFail("empty ring must not apply anything") }, 0)
        XCTAssertTrue(ring.isEmpty)
    }

    func testRingPointerPayloadRoundTrips() {
        let ring = CommandRing(capacity: 8)
        var token: UInt8 = 7
        let pointer = withUnsafePointer(to: &token) { UnsafeRawPointer($0) }

        XCTAssertTrue(ring.tryPush(.loadArm(deck: 1, source: pointer)))
        var received: UnsafeRawPointer?
        var deck: UInt8 = 99
        XCTAssertEqual(ring.drain {
            received = $0.ptr
            deck = $0.deck
        }, 1)
        XCTAssertEqual(received, pointer, "the armed-source pointer must cross the ring intact")
        XCTAssertEqual(deck, 1)
        XCTAssertEqual(pointer.load(as: UInt8.self), 7)
    }

    // MARK: - Engine snapshot

    func testSnapshotDoubleBufferPublishReadRetire() {
        let snapshot = EngineSnapshot()
        let a = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 1)
        let b = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 1)
        defer {
            a.deallocate()
            b.deallocate()
        }

        XCTAssertNil(snapshot.read(), "no snapshot before the first publish")
        XCTAssertNil(snapshot.publish(a), "first publish replaces nothing")
        XCTAssertEqual(snapshot.read(), a)

        XCTAssertEqual(snapshot.publish(b), a, "second publish hands the replaced pointer back")
        XCTAssertEqual(snapshot.read(), b, "render reads the newest pointer")

        snapshot.retire(a)
        XCTAssertEqual(snapshot.drainRetired(), [a], "the retired pointer is reclaimed off the render thread")
        XCTAssertEqual(snapshot.drainRetired(), [])
        XCTAssertEqual(snapshot.read(), b)
    }

    // MARK: - RTGuard

    func testRTGuardTracksRenderContextOnTheCallingThread() {
        XCTAssertFalse(RTGuard.isInRenderContext)
        XCTAssertNil(RTGuard.checkRTSafe("malloc"), "outside a render the same operation is safe")

        let detected = RTGuard.withRenderContext {
            XCTAssertTrue(RTGuard.isInRenderContext)
            return RTGuard.checkRTSafe("malloc")
        }
        XCTAssertEqual(detected, "malloc", "the shim must flag the render thread")
        XCTAssertFalse(RTGuard.isInRenderContext, "the flag must be restored after the context")

        let nested = RTGuard.withRenderContext {
            RTGuard.withRenderContext { RTGuard.checkRTSafe("lock") }
        }
        XCTAssertEqual(nested, "lock")
    }

    // MARK: - RenderLoad

    func testRenderLoadMeasuresAndResets() {
        let load = RenderLoad()
        XCTAssertEqual(load.lastRenderNanos, 0)
        XCTAssertEqual(load.loadRatio(periodNanos: 1000), 0, "no measurement yet")

        let start = load.startTicks()
        var sink = 0.0
        for i in 0..<200_000 { sink += Double(i).squareRoot() }
        load.endTicks(start)

        XCTAssertGreaterThan(load.lastRenderNanos, 0, "a measured render must publish a positive duration")
        XCTAssertGreaterThan(sink, 0)
        XCTAssertLessThan(load.loadRatio(periodNanos: 1_000_000_000), 1.0)

        load.reset()
        XCTAssertEqual(load.lastRenderNanos, 0)
    }

    // MARK: - Pure scheduler / cue-loop math (§30.3, §33)

    func testQuantizedBoundaryLandsOnGridDivisions() {
        // 120 BPM @ 48 kHz → one beat = 24 000 samples.
        let grid = DeckGrid(referenceSample: 0, bpm: 120, beatsPerBar: 4, sampleRate: 48_000)
        XCTAssertEqual(Scheduler.quantizedBoundary(after: 0, resolution: .beat, grid: grid), 24_000)
        XCTAssertEqual(Scheduler.quantizedBoundary(after: 23_999, resolution: .beat, grid: grid), 24_000)
        XCTAssertEqual(Scheduler.quantizedBoundary(after: 24_000, resolution: .beat, grid: grid), 48_000,
                       "a trigger exactly on a boundary moves to the next")
        XCTAssertEqual(Scheduler.quantizedBoundary(after: 10_000, resolution: .halfBeat, grid: grid), 12_000)
        XCTAssertEqual(Scheduler.quantizedBoundary(after: 10_000, resolution: .bar, grid: grid), 96_000,
                       "one bar = 4 beats")
        XCTAssertEqual(Scheduler.quantizedBoundary(after: 10_000, resolution: .fourBars, grid: grid), 384_000)
    }

    func testQuantizedBoundaryRespectsGridReference() {
        let grid = DeckGrid(referenceSample: 500, bpm: 120, beatsPerBar: 4, sampleRate: 48_000)
        XCTAssertEqual(Scheduler.quantizedBoundary(after: 500, resolution: .beat, grid: grid), 24_500)
        XCTAssertEqual(Scheduler.quantizedBoundary(after: 24_000, resolution: .beat, grid: grid), 24_500)
        XCTAssertEqual(Scheduler.quantizedBoundary(after: 24_500, resolution: .beat, grid: grid), 48_500)
    }

    func testTriggerFrameIsImmediateWhenUnquantized() {
        let grid = DeckGrid(sampleRate: 48_000)
        XCTAssertEqual(Scheduler.triggerFrame(playhead: 100, masterSample: 100, targetSample: 8000,
                                              quantized: false, resolution: .beat, grid: grid, rate: 1), 100,
                       "an unquantized trigger fires at the current callback boundary")
    }

    func testTriggerFrameLandsOnBoundaryThroughRate() {
        let grid = DeckGrid(bpm: 120, sampleRate: 48_000) // beat = 24 000
        // Next beat after playhead 10 000 is 24 000 → 14 000 output frames away.
        XCTAssertEqual(Scheduler.triggerFrame(playhead: 10_000, masterSample: 10_000, targetSample: 8000,
                                              quantized: true, resolution: .beat, grid: grid, rate: 1), 24_000)
        // At rate 2 the playhead reaches the same boundary in half the frames.
        XCTAssertEqual(Scheduler.triggerFrame(playhead: 10_000, masterSample: 10_000, targetSample: 8000,
                                              quantized: true, resolution: .beat, grid: grid, rate: 2), 17_000)
    }

    func testCueLoopLoopEndConvertsBeatsToSamples() {
        let grid = DeckGrid(bpm: 120, sampleRate: 48_000) // 24 000 per beat
        XCTAssertEqual(CueLoop.loopEnd(start: 4000, beats: 8, grid: grid), 4000 + 8 * 24_000)
        XCTAssertEqual(CueLoop.loopEnd(start: 0, beats: 0.5, grid: grid), 12_000)
        XCTAssertEqual(CueLoop.wrap(6000, loopStart: 4000, loopEnd: 6000), 4000)
    }

    func testTempCueStatePressRelease() {
        var cue = TempCueState()
        XCTAssertFalse(cue.press(at: 500), "first press with no point sets it")
        XCTAssertEqual(cue.pointSample, 500)
        XCTAssertTrue(cue.hasPoint)
        XCTAssertFalse(cue.previewing)

        XCTAssertTrue(cue.press(at: 1200), "second press previews")
        XCTAssertTrue(cue.previewing)
        XCTAssertEqual(cue.previewStartSample, 1200)
        XCTAssertEqual(cue.pointSample, 500)

        XCTAssertEqual(cue.release(), 1200, "release restores the pre-preview playhead")
        XCTAssertNil(cue.release(), "no preview in flight → nothing to restore")

        cue.setPoint(777)
        XCTAssertEqual(cue.pointSample, 777)
    }

    // MARK: - Offline render harness

    func testDeckReadsReferencePCM() throws {
        let engine = try makeEngine()
        try engine.start()
        defer { engine.stop() }

        let source = sineSource()
        engine.load(.a, source: source.source)
        engine.play(.a)

        let samples = try engine.renderMono(512)
        let expected = sineReference(count: 512)
        for i in 0..<512 {
            XCTAssertEqual(samples[i], expected[i], accuracy: 0.0005, "sample \(i)")
        }
        XCTAssertGreaterThan(samples.reduce(0) { max($0, abs($1)) }, 0.2)
    }

    func testPauseMutesAndPlayResumesWithFrozenPlayhead() throws {
        let engine = try makeEngine()
        try engine.start()
        defer { engine.stop() }

        let source = sineSource()
        engine.load(.a, source: source.source)
        engine.play(.a)

        let head = try engine.renderMono(64)
        XCTAssertGreaterThan(head.reduce(0) { max($0, abs($1)) }, 0.2)

        engine.pause(.a)
        let silent = try engine.renderMono(32)
        XCTAssertTrue(silent.allSatisfy { $0 == 0 }, "paused deck must render silence")

        engine.play(.a)
        let resumed = try engine.renderMono(32)
        // The playhead froze during the pause: the resumed run continues exactly
        // where the 64th frame ended, reading source sample 64 onward.
        for (i, value) in resumed.enumerated() {
            let expected = sineValue(at: 64 + i)
            XCTAssertEqual(value, expected, accuracy: 0.0005, "sample \(i)")
        }
    }

    func testRateAppliesAtExactFrameBoundary() throws {
        let engine = try makeEngine()
        try engine.start()
        defer { engine.stop() }

        let source = sineSource(frames: 20_000)
        engine.load(.a, source: source.source)
        engine.play(.a)

        var out: [Float] = []
        out += try engine.renderMono(100)

        // Rate change is drained at the top of the NEXT callback, so frame 100 is
        // the first produced at rate 2 — the playhead advances 2 track samples
        // per output frame (§30.1, §47.2).
        engine.setRate(.a, rate: 2.0)
        out += try engine.renderMono(5)

        for k in 0..<5 {
            let track = 100 + 2 * k
            XCTAssertEqual(out[100 + k], sineValue(at: track), accuracy: 0.0005, "sample \(100 + k)")
        }
        XCTAssertEqual(engine.deckPlayhead(.a), 110)
    }

    func testHotCueJumpsAtExactFrame() throws {
        let engine = try makeEngine()
        try engine.start()
        defer { engine.stop() }

        let source = rampSource()
        engine.load(.a, source: source.source)
        engine.play(.a)

        var out: [Float] = []
        out += try engine.renderMono(100) // frames 0..100 = track samples 0..100

        // Quantize is off: the trigger fires at the next render boundary, frame 100.
        engine.triggerHotCue(.a, atSample: 5000)
        out += try engine.renderMono(3)

        XCTAssertEqual(out[99], 99)
        XCTAssertEqual(out[100], 5000, "the cue jump lands on the exact frame")
        XCTAssertEqual(out[101], 5001)
        XCTAssertEqual(out[102], 5002)
        XCTAssertEqual(engine.deckPlayhead(.a), 5003)
    }

    func testQuantizedTriggerLandsOnGridBoundary() throws {
        // 120 BPM @ 48 kHz → beat = 24 000 samples, reference at sample 0.
        let grid = DeckGrid(referenceSample: 0, bpm: 120, beatsPerBar: 4, sampleRate: 48_000)
        let engine = try makeEngine()
        try engine.start()
        defer { engine.stop() }

        let source = rampSource(frames: 50_000, grid: grid)
        engine.load(.a, source: source.source)
        engine.play(.a)

        var out: [Float] = []
        out += try renderFrames(engine, count: 10_000) // playhead → 10 000

        engine.setQuantize(true, resolution: .beat)
        engine.triggerHotCue(.a, atSample: 8000) // fires on the next beat, sample 24 000
        out += try renderFrames(engine, count: 20_000) // covers frames 10 000..30 000

        XCTAssertEqual(out[23_999], 23_999, "the frame just before the boundary")
        XCTAssertEqual(out[24_000], 8000, "the quantized trigger lands exactly on the grid boundary")
        XCTAssertEqual(out[24_001], 8001)
        XCTAssertEqual(engine.deckPlayhead(.a), 14_000, "8000 + (30 000 − 24 000)")
    }

    func testLoopWrapsFrameExact() throws {
        let engine = try makeEngine()
        try engine.start()
        defer { engine.stop() }

        let source = rampSource()
        engine.load(.a, source: source.source)
        engine.play(.a)
        engine.setLoopRange(.a, start: 4000, end: 6000)

        let out = try renderFrames(engine, count: 10_000)
        XCTAssertEqual(out[3999], 3999)
        XCTAssertEqual(out[4000], 4000)
        XCTAssertEqual(out[5999], 5999)
        XCTAssertEqual(out[6000], 4000, "the loop wraps end → start at the exact frame")
        XCTAssertEqual(out[7999], 5999)
        XCTAssertEqual(out[8000], 4000, "the wrap repeats seamlessly")
        XCTAssertEqual(out[9999], 5999)
    }

    func testPlayheadTelemetryIsExact() throws {
        let engine = try makeEngine()
        try engine.start()
        defer { engine.stop() }

        let source = rampSource()
        engine.load(.a, source: source.source)
        engine.play(.a)
        engine.seek(.a, toSample: 1000, quantized: false)

        let out = try engine.renderMono(256)
        XCTAssertEqual(engine.masterSample, 256, "the master clock counts absolute frames")
        XCTAssertEqual(engine.deckPlayhead(.a), 1256, "playhead telemetry is exact")
        XCTAssertEqual(out[0], 1000)
        XCTAssertEqual(out[255], 1255)
    }

    func testTempCuePressJumpsToCueAndReleaseReturns() throws {
        let engine = try makeEngine()
        try engine.start()
        defer { engine.stop() }

        let source = rampSource(frames: 20_000)
        engine.load(.a, source: source.source)
        engine.play(.a)

        var out: [Float] = []
        out += try engine.renderMono(100) // samples 0..100, playhead 100

        engine.setCue(.a, atSample: 2000)
        engine.cue(.a)                    // press: jump to 2000 and preview
        out += try engine.renderMono(50)  // samples 2000..2050

        engine.releaseCue(.a)             // release: return to 100, pause
        out += try engine.renderMono(20)  // silence

        engine.play(.a)
        out += try engine.renderMono(20)  // samples 100..120

        XCTAssertEqual(out[100], 2000)
        XCTAssertEqual(out[149], 2049)
        XCTAssertTrue(out[150..<170].allSatisfy { $0 == 0 }, "released cue must pause")
        XCTAssertEqual(out[170], 100, "release returns to the pre-preview playhead")
        XCTAssertEqual(out[189], 119)
        XCTAssertEqual(engine.deckPlayhead(.a), 120)
    }

    func testTwoDecksPlayIndependentlyAndSum() throws {
        let engine = try makeEngine()
        try engine.start()
        defer { engine.stop() }

        let ramp = rampSource()
        let flat = rampSource { _ in 0.25 }
        engine.load(.a, source: ramp.source)
        engine.load(.b, source: flat.source)
        engine.play(.a)
        engine.play(.b)

        var out: [Float] = []
        out += try engine.renderMono(128)
        for k in 0..<128 {
            XCTAssertEqual(out[k], Float(k) + 0.25, accuracy: 0.0001, "both decks sum, sample \(k)")
        }

        engine.pause(.b)
        out += try engine.renderMono(128)
        for k in 0..<128 {
            XCTAssertEqual(out[128 + k], Float(128 + k), accuracy: 0.0001, "deck A continues alone, sample \(k)")
        }
        XCTAssertEqual(engine.deckPlayhead(.a), 256)
        XCTAssertEqual(engine.deckPlayhead(.b), 128, "deck B's playhead froze when paused")
    }

    func testDeckWithoutBufferRendersSilenceNotGarbage() throws {
        let engine = try makeEngine()
        try engine.start()
        defer { engine.stop() }

        engine.play(.a) // playing with no source
        let out = try engine.renderMono(512)
        XCTAssertTrue(out.allSatisfy { $0 == 0 }, "a deck with no buffer renders silence, not garbage")
        XCTAssertGreaterThanOrEqual(engine.starvedFrames, 512, "silence bumps the starved counter (§46.2)")
    }

    func testDeckStopsWhenItReachesTheEndOfItsTrack() throws {
        // A deck past the end of its material is not playing, and has to stop
        // saying that it is — the §34A.5 rule ("a stopped graph stops lying")
        // applied one layer down, at the deck.
        //
        // This is not a cosmetic claim. `holdMix` in the DJ regression driver
        // reads the transport to decide when a deck needs its next track, and
        // while a dry deck went on reporting `playing` the lane could not tell:
        // every djmix recording ended with twenty seconds of digital silence
        // because both fixtures had run out and nothing noticed.
        let engine = try makeEngine()
        try engine.start()
        defer { engine.stop() }

        let source = TestSource(frames: 1000) { Float($0) / 1000.0 }
        engine.load(.a, source: source.source)
        engine.play(.a)

        _ = try engine.renderMono(512)
        XCTAssertTrue(engine.sampleTelemetry().deckA.playing,
                      "still inside the track: the deck is playing")

        _ = try engine.renderMono(1024) // runs off the end at frame 1000
        XCTAssertFalse(engine.sampleTelemetry().deckA.playing,
                       "a deck that reached the end of its track reports stopped")
        XCTAssertEqual(engine.deckPlayhead(.a), 1000,
                       "the playhead is clamped to the end, not left past it")

        let after = try engine.renderMono(512)
        XCTAssertTrue(after.allSatisfy { $0 == 0 },
                      "a stopped deck renders silence, and the playhead stays put")
        XCTAssertEqual(engine.deckPlayhead(.a), 1000)
    }

    func testLoadingATrackStartsItFromTheBeginning() throws {
        // Arming a source used to change the pointer and nothing else, so the
        // playhead stayed where the previous track left it. Load the next track
        // after one has played to the end and the deck is parked past the end of
        // the new one: silence for ever, with no way back except CUE.
        //
        // This is what put twenty seconds of digital silence at the end of every
        // djmix recording. The lane's rotation was working and the audio still
        // never came back, because the deck it loaded onto was already past EOF.
        let engine = try makeEngine()
        try engine.start()
        defer { engine.stop() }

        let first = TestSource(frames: 1000) { _ in 0.5 }
        engine.load(.a, source: first.source)
        engine.play(.a)
        _ = try engine.renderMono(2048) // plays out and stops at the end
        XCTAssertFalse(engine.sampleTelemetry().deckA.playing)
        XCTAssertEqual(engine.deckPlayhead(.a), 1000)

        // The next track goes on the same deck, as a rotation would do.
        let second = TestSource(frames: 4000) { Float($0) / 4000.0 }
        engine.load(.a, source: second.source)
        _ = try engine.renderMono(64)
        XCTAssertEqual(engine.deckPlayhead(.a), 0,
                       "a freshly loaded track starts at its beginning, not where the last one ended")

        engine.play(.a)
        let out = try engine.renderMono(512)
        XCTAssertTrue(out.contains { $0 != 0 },
                      "the new track actually plays — this is the dead-air defect")
        XCTAssertTrue(engine.sampleTelemetry().deckA.playing)
    }

    func testRTGuardWrapsOfflineRender() throws {
        let engine = try makeEngine()
        try engine.start()
        defer { engine.stop() }
        _ = try engine.renderMono(128)
        #if DEBUG
        XCTAssertTrue(engine.guardWasActive, "the render callback must run inside RTGuard")
        #else
        XCTAssertFalse(engine.guardWasActive)
        #endif
    }

    func testLongRenderNoOverrunAndLoadSane() throws {
        // A 10 s offline render in 512-frame chunks while the producer hammers
        // the ring with bursts far larger than its capacity: pushes fail softly
        // (§12.2 coalesce/drop), the render never misses a frame, and the output
        // stays bounded — the "never overrun" property of the boundary (§34.1).
        let engine = try makeEngine(ringCapacity: 8)
        try engine.start()
        defer { engine.stop() }

        let source = sineSource(frames: 480_000)
        engine.load(.a, source: source.source)
        engine.play(.a)

        let chunk = 512
        let total = 48_000 * 10
        var rendered = 0
        var maxAbs: Float = 0
        var nonFinite = false

        while rendered < total {
            for i in 0..<20 {
                _ = engine.commandRing.tryPush(.setRate(deck: 0, rate: Float(1 + (i % 5) / 10)))
            }
            _ = engine.commandRing.tryPush(.play(deck: 0))

            let buffer = try engine.renderMono(AVAudioFrameCount(min(chunk, total - rendered)))
            for value in buffer {
                if !value.isFinite { nonFinite = true }
                maxAbs = max(maxAbs, abs(value))
            }
            rendered += buffer.count
        }

        XCTAssertEqual(rendered, total, "the harness must render every requested frame")
        XCTAssertFalse(nonFinite, "render produced non-finite samples")
        XCTAssertLessThanOrEqual(maxAbs, 0.26, "render produced out-of-range samples")

        XCTAssertGreaterThan(engine.graph.renderLoad.lastRenderNanos, 0)
        let periodNanos = UInt64((128.0 / 48_000.0) * 1e9) // 128-frame buffer period
        XCTAssertLessThan(engine.graph.renderLoad.loadRatio(periodNanos: periodNanos), 1.0,
                          "render load must leave headroom below the buffer period")
    }

    // MARK: - Real-time driver (commit 5.4a, §53.11)

    func testRealtimeModeRefusesOfflineRender() throws {
        // A `.realtime` graph has no manual-rendering mode; the offline pull is
        // meaningless there (§53.11). The existing offline suite keeps its
        // meaning because the `.offline` default is untouched.
        let engine = try makeEngine(rendering: .realtime)
        try engine.start()
        defer { engine.stop() }
        XCTAssertThrowsError(try engine.render(128)) { error in
            XCTAssertEqual(error as? AudioGraphError, .renderingUnavailableInRealtimeMode)
        }
    }

    // MARK: - Mixer (commit 4.4, §35)

    func testEQKillThroughGraphIsSilent() throws {
        let engine = try makeEngine()
        try engine.start()
        defer { engine.stop() }

        let source = sineSource()
        engine.load(.a, source: source.source)
        engine.play(.a)

        _ = try engine.renderMono(128) // audible before the kill
        engine.setEQKnobs(.a, low: -1, mid: -1, high: -1) // full kill (−∞)
        _ = try renderFrames(engine, count: 8192) // let the smoothing settle

        let out = try engine.renderMono(512)
        XCTAssertTrue(out.allSatisfy { abs($0) < 1e-4 },
                      "a full EQ kill must silence the deck in the graph")
        XCTAssertEqual(engine.deckPlayhead(.a), 128 + 8192 + 512, "the deck keeps playing through the kill")
    }

    func testFilterThroughGraphBypassIsIdenticalToReference() throws {
        let engine = try makeEngine()
        try engine.start()
        defer { engine.stop() }

        let source = sineSource()
        engine.load(.a, source: source.source)
        engine.play(.a)
        engine.setFilter(.a, knob: 0) // centre detent → hard bypass

        let out = try engine.renderMono(512)
        let expected = sineReference(count: 512)
        for i in 0..<512 {
            XCTAssertEqual(out[i], expected[i], accuracy: 0.0005,
                           "the bypassed filter must leave the deck frame-identical at sample \(i)")
        }
    }

    func testChannelFaderScalesDeckOutput() throws {
        let engine = try makeEngine()
        try engine.start()
        defer { engine.stop() }

        let source = sineSource()
        engine.load(.a, source: source.source)
        engine.play(.a)
        engine.setChannelFader(.a, gain: 0.5)
        _ = try renderFrames(engine, count: 8192) // settle the fader ramp

        let out = try engine.renderMono(512)
        for (i, value) in out.enumerated() {
            let expected = 0.5 * sineValue(at: 8192 + i)
            XCTAssertEqual(value, expected, accuracy: 0.002, "fader at 0.5 halves the deck, sample \(i)")
        }
    }

    func testCrossfaderBlendsDecksPerConstantPowerLaw() throws {
        let engine = try makeEngine()
        try engine.start()
        defer { engine.stop() }

        // Deck A's ramp is scaled to ±40 so float-level gain residuals (the
        // one-pole's ~1e-5 convergence error) stay well below the assertions.
        let ramp = rampSource(frames: 40_000) { Float($0) * 0.001 }
        let flat = rampSource(frames: 40_000) { _ in 0.5 }
        engine.load(.a, source: ramp.source)
        engine.load(.b, source: flat.source)
        engine.play(.a)
        engine.play(.b)

        // Full A: deck A at unity, deck B silent.
        engine.setCrossfader(-1, curve: .constantPower)
        _ = try renderFrames(engine, count: 8192)
        var headA = engine.deckPlayhead(.a)
        var out = try engine.renderMono(128)
        for k in 0..<128 {
            XCTAssertEqual(out[k], 0.001 * Float(headA + Int64(k)), accuracy: 1e-3,
                           "full A: only deck A's ramp, sample \(k)")
        }

        // Full B: deck A silent, deck B at unity. cos(π/2) is ≈7.5e-8 rather
        // than exactly 0, so deck A's ramp bleeds ~1e-6 through — absorb that
        // float-level crossfader bleed in the tolerance.
        engine.setCrossfader(1, curve: .constantPower)
        _ = try renderFrames(engine, count: 8192)
        out = try engine.renderMono(128)
        for k in 0..<128 {
            XCTAssertEqual(out[k], 0.5, accuracy: 1e-3, "full B: only deck B's level, sample \(k)")
        }

        // Centre: both decks at √2/2 — the constant-power blend.
        engine.setCrossfader(0, curve: .constantPower)
        _ = try renderFrames(engine, count: 8192)
        headA = engine.deckPlayhead(.a)
        out = try engine.renderMono(128)
        let c = cos(Float.pi / 4)
        for k in 0..<128 {
            let position = 0.001 * Float(headA + Int64(k))
            let expected = c * position + c * 0.5
            XCTAssertEqual(out[k], expected, accuracy: 0.005,
                           "centre blend follows the constant-power law, sample \(k)")
        }
        XCTAssertEqual(engine.deckPlayhead(.a), headA + 128)
        XCTAssertEqual(engine.deckPlayhead(.b), headA + 128)
    }

    func testMasterLimiterClampsGraphOutput() throws {
        let engine = try makeEngine(limiterCeiling: 0.9, limiterLookaheadFrames: 240)
        try engine.start()
        defer { engine.stop() }

        // 1.5 sits above the soft knee (ceiling·10^(3/20) ≈ 1.27), so the hard
        // `ceiling/peak` ratio applies: a constant 1.5 is held exactly at 0.9.
        let loud = rampSource(frames: 40_000) { _ in 1.5 }
        engine.load(.a, source: loud.source)
        engine.play(.a)

        let out = try renderFrames(engine, count: 4096)
        XCTAssertLessThanOrEqual(out.max() ?? 0, 0.9 + 1e-4,
                                 "the master limiter must hold the summed bus at the ceiling")
        for i in 0..<240 {
            XCTAssertEqual(out[i], 0, "the lookahead window primes with silence")
        }
        XCTAssertEqual(out[3000], 0.9, accuracy: 1e-3,
                       "a hot constant input is held at the ceiling in steady state")
    }

    // MARK: - Time-pitch / key lock (commit 4.5, §31)

    /// The time-pitch topology renders a deck through its `AVAudioUnitTimePitch`
    /// (plan §5 4.5, §29.1 shape). `AVAudioUnitTimePitch` is windowed DSP, not
    /// a bit-exact transform, so these assertions measure the **dominant
    /// frequency** over a steady window rather than individual samples — FR-ENG-6
    /// (key lock holds pitch under a tempo change) and §31.3 (key shift ratio).
    ///
    /// The deck reader is the tempo authority: at rate 1.2 a 440 Hz tone leaves
    /// the reader at 528 Hz. Key lock on lowers the unit's pitch by
    /// `1200·log2(1.2) ≈ 316¢` so the output stays at 440 Hz; key lock off
    /// leaves the 528 Hz vinyl behaviour; a +1 semitone shift moves the
    /// frequency by `2^(1/12)` with the rate held.

    func testKeyLockHoldsPitchUnderTempoChange() throws {
        let engine = try makeEngine(timePitch: true)
        try engine.start()
        defer { engine.stop() }

        let source = sineSource(frames: 200_000)
        engine.load(.a, source: source.source)
        engine.play(.a)
        engine.setRate(.a, rate: 1.2)
        engine.setKeyLock(.a, locked: true)

        let samples = try renderPitchChunks(engine, warmup: 4, measure: 28)
        let frequency = measuredFrequency(samples)
        XCTAssertEqual(frequency, 440.0, accuracy: 440.0 * 0.015,
                       "key lock must hold pitch at 440 Hz under a +20% tempo change "
                       + "(reader at 528 Hz, unit −316¢ → measured \(frequency) Hz)")
    }

    func testKeyLockAtUnityRateIsTransparent() throws {
        let engine = try makeEngine(timePitch: true)
        try engine.start()
        defer { engine.stop() }

        let source = sineSource(frames: 200_000)
        engine.load(.a, source: source.source)
        engine.play(.a)
        engine.setKeyLock(.a, locked: true) // rate stays 1 → compensation 0¢

        let samples = try renderPitchChunks(engine, warmup: 4, measure: 28)
        let frequency = measuredFrequency(samples)
        XCTAssertEqual(frequency, 440.0, accuracy: 440.0 * 0.015,
                       "key lock at unity rate must leave the frequency untouched "
                       + "(measured \(frequency) Hz)")
    }

    func testKeyLockOffPitchFollowsRate() throws {
        let engine = try makeEngine(timePitch: true)
        try engine.start()
        defer { engine.stop() }

        let source = sineSource(frames: 200_000)
        engine.load(.a, source: source.source)
        engine.play(.a)
        engine.setRate(.a, rate: 1.2) // key lock off (default): vinyl behaviour

        let samples = try renderPitchChunks(engine, warmup: 4, measure: 28)
        let frequency = measuredFrequency(samples)
        let expected = 440.0 * 1.2
        XCTAssertEqual(frequency, expected, accuracy: expected * 0.015,
                       "key lock off must let pitch follow rate (measured \(frequency) Hz, "
                       + "expected \(expected) Hz)")
    }

    func testKeyShiftSemitoneMovesFrequencyByExpectedRatio() throws {
        let engine = try makeEngine(timePitch: true)
        try engine.start()
        defer { engine.stop() }

        let source = sineSource(frames: 200_000)
        engine.load(.a, source: source.source)
        engine.play(.a)
        engine.setKeyShift(.a, semitones: 1) // rate held at 1

        let samples = try renderPitchChunks(engine, warmup: 4, measure: 28)
        let frequency = measuredFrequency(samples)
        let expected = 440.0 * pow(2, 1.0 / 12.0)
        XCTAssertEqual(frequency, expected, accuracy: expected * 0.015,
                       "a +1 semitone key shift must move the frequency by 2^(1/12) "
                       + "(measured \(frequency) Hz, expected \(expected) Hz)")
    }

    func testKeyShiftNegativeSemitoneMovesFrequencyDown() throws {
        let engine = try makeEngine(timePitch: true)
        try engine.start()
        defer { engine.stop() }

        let source = sineSource(frames: 200_000)
        engine.load(.a, source: source.source)
        engine.play(.a)
        engine.setKeyShift(.a, semitones: -1)

        let samples = try renderPitchChunks(engine, warmup: 4, measure: 28)
        let frequency = measuredFrequency(samples)
        let expected = 440.0 * pow(2, -1.0 / 12.0)
        XCTAssertEqual(frequency, expected, accuracy: expected * 0.015,
                       "a −1 semitone key shift must move the frequency by 2^(−1/12) "
                       + "(measured \(frequency) Hz, expected \(expected) Hz)")
    }

    func testKeyShiftCompoundsUnderKeyLock() throws {
        let engine = try makeEngine(timePitch: true)
        try engine.start()
        defer { engine.stop() }

        let source = sineSource(frames: 200_000)
        engine.load(.a, source: source.source)
        engine.play(.a)
        engine.setRate(.a, rate: 1.2)
        engine.setKeyLock(.a, locked: true) // holds pitch at 440 Hz
        engine.setKeyShift(.a, semitones: 1) // then nudges it up a semitone

        let samples = try renderPitchChunks(engine, warmup: 4, measure: 28)
        let frequency = measuredFrequency(samples)
        let expected = 440.0 * pow(2, 1.0 / 12.0)
        XCTAssertEqual(frequency, expected, accuracy: expected * 0.015,
                       "key lock under tempo + one semitone must land on 440·2^(1/12), "
                       + "not 528·2^(1/12) (measured \(frequency) Hz, expected \(expected) Hz)")
    }

    /// Render `warmup` + `measure` 4096-frame chunks on the time-pitch graph and
    /// return the measured window (the warm-up covers the unit's latency and
    /// windowing). The deck reader consumes `rate` source samples per output
    /// frame, so the test sources are sized well past the window.
    private func renderPitchChunks(_ engine: PerformanceEngine,
                                   warmup: Int, measure: Int) throws -> [Float] {
        var samples: [Float] = []
        samples.reserveCapacity(measure * 4096)
        for _ in 0..<warmup {
            _ = try engine.renderMono(4096)
        }
        for _ in 0..<measure {
            samples += try engine.renderMono(4096)
        }
        return samples
    }

    /// The dominant frequency of `samples` by zero crossings over the whole
    /// buffer (each cycle contributes two crossings).
    private func measuredFrequency(_ samples: [Float]) -> Double {
        guard samples.count > 8 else { return 0 }
        var crossings = 0
        var last = samples[0]
        for i in 1..<samples.count {
            let s = samples[i]
            if (last < 0 && s >= 0) || (last >= 0 && s < 0) { crossings += 1 }
            last = s
        }
        let window = Double(samples.count)
        return Double(crossings) * 48_000.0 / (2.0 * window)
    }

    // MARK: - Sync + telemetry (commit 4.6, §32)

    func testSyncAlignsBeatsOnMasterGrid() throws {
        let gridA = DeckGrid(referenceSample: 0, bpm: 120, beatsPerBar: 4, sampleRate: 48_000)
        let gridB = DeckGrid(referenceSample: 0, bpm: 120, beatsPerBar: 4, sampleRate: 48_000)
        let engine = try makeEngine()
        try engine.start()
        defer { engine.stop() }

        engine.load(.a, source: rampSource(frames: 100_000, grid: gridA).source)
        engine.load(.b, source: rampSource(frames: 100_000, grid: gridB).source)
        engine.play(.a)
        engine.play(.b)

        _ = try renderFrames(engine, count: 1024) // both playheads at 1024, same phase
        engine.seek(.b, toSample: 6000, quantized: false)
        _ = try renderFrames(engine, count: 1) // deck B jumps to 6000, then advances 1

        engine.sync(.b, to: .a)
        _ = try renderFrames(engine, count: 512)

        let phaseA = gridA.beatPhase(at: Double(engine.deckPlayhead(.a)))
        let phaseB = gridB.beatPhase(at: Double(engine.deckPlayhead(.b)))
        XCTAssertEqual(phaseA, phaseB, accuracy: 1e-3,
                       "sync must phase-align deck B to deck A's beat grid (AT-ENGINE-SYNC)")
        XCTAssertTrue(engine.isSynced(.b))
        XCTAssertEqual(engine.graph.deckRate(1), 1.0, accuracy: 1e-6,
                       "same BPM and unity master → the synced deck plays at unity")
    }

    func testSyncRateTracksMasterPitchChangeContinuously() throws {
        let gridA = DeckGrid(referenceSample: 0, bpm: 120, beatsPerBar: 4, sampleRate: 48_000)
        let gridB = DeckGrid(referenceSample: 0, bpm: 100, beatsPerBar: 4, sampleRate: 48_000)
        let engine = try makeEngine()
        try engine.start()
        defer { engine.stop() }

        engine.load(.a, source: rampSource(frames: 100_000, grid: gridA).source)
        engine.load(.b, source: rampSource(frames: 100_000, grid: gridB).source)
        engine.play(.a)
        engine.play(.b)
        _ = try renderFrames(engine, count: 512)

        engine.sync(.b, to: .a)
        _ = try renderFrames(engine, count: 4096)
        XCTAssertEqual(engine.graph.deckRate(1), 1.2, accuracy: 1e-4,
                       "120 BPM / 100 BPM at unity → rate 1.2")

        engine.setRate(.a, rate: 1.1) // master pitched +10% → effective 132 BPM
        _ = try renderFrames(engine, count: 4096)
        XCTAssertEqual(engine.graph.deckRate(1), 1.32, accuracy: 1e-4,
                       "continuous sync tracks the master pitch change (§32.1)")

        engine.unsync(.b)
        _ = try renderFrames(engine, count: 4096)
        XCTAssertFalse(engine.isSynced(.b))
        XCTAssertEqual(engine.graph.deckRate(1), 1.32, accuracy: 1e-4,
                       "unsync freezes the deck at its last synced rate (manual control)")
    }

    func testSyncBarAlignsDownbeats() throws {
        let gridA = DeckGrid(referenceSample: 0, bpm: 120, beatsPerBar: 4, sampleRate: 48_000)
        let gridB = DeckGrid(referenceSample: 0, bpm: 120, beatsPerBar: 4, sampleRate: 48_000)
        let engine = try makeEngine()
        try engine.start()
        defer { engine.stop() }

        engine.load(.a, source: rampSource(frames: 200_000, grid: gridA).source)
        engine.load(.b, source: rampSource(frames: 200_000, grid: gridB).source)
        engine.play(.a)
        engine.play(.b)
        _ = try renderFrames(engine, count: 1024)

        engine.seek(.b, toSample: 48_000, quantized: false) // mid-bar-2
        _ = try renderFrames(engine, count: 1)

        engine.sync(.b, to: .a, barSync: true)
        _ = try renderFrames(engine, count: 512)

        let barA = gridA.barPhase(at: Double(engine.deckPlayhead(.a)))
        let barB = gridB.barPhase(at: Double(engine.deckPlayhead(.b)))
        XCTAssertEqual(barA, barB, accuracy: 1e-3,
                       "bar sync aligns downbeats — bar 1 to bar 1 (§32.2)")
    }

    func testTelemetryPublishesMasterClockAndDeckReadouts() throws {
        let grid = DeckGrid(referenceSample: 0, bpm: 120, beatsPerBar: 4, sampleRate: 48_000)
        let engine = try makeEngine()
        try engine.start()
        defer { engine.stop() }

        engine.load(.a, source: rampSource(frames: 100_000, grid: grid).source)
        engine.play(.a)
        _ = try engine.renderMono(1000)

        let snapshot = engine.graph.masterClock
        XCTAssertEqual(snapshot.masterSample, 1000, "the master clock counts absolute frames")
        XCTAssertEqual(snapshot.masterBPM, 120, accuracy: 1e-6, "effective BPM from grid × rate")
        XCTAssertEqual(snapshot.downbeatPhase, grid.barPhase(at: 1000), accuracy: 1e-6)

        let telemetry = engine.sampleTelemetry()
        XCTAssertEqual(telemetry.masterSample, 1000)
        XCTAssertEqual(telemetry.deckA.playheadSample, 1000)
        XCTAssertEqual(telemetry.deckA.bpmEffective, 120, accuracy: 1e-6)
        XCTAssertEqual(telemetry.deckA.phase, grid.beatPhase(at: 1000), accuracy: 1e-6)
        XCTAssertTrue(telemetry.deckA.playing)
        XCTAssertFalse(telemetry.deckA.synced)
        XCTAssertGreaterThan(telemetry.deckA.level, 0, "a playing deck publishes a peak level")
        XCTAssertEqual(telemetry.masterLevel, telemetry.deckA.level, accuracy: 0.001,
                       "one deck, no crossfader → the bus equals the deck")
        XCTAssertGreaterThan(telemetry.renderLoad, 0)
        XCTAssertLessThanOrEqual(telemetry.renderLoad, 1)
    }

    // MARK: - Helpers

    private func makeEngine(ringCapacity: Int = 16,
                            limiterCeiling: Float? = nil,
                            limiterLookaheadFrames: Int = 0,
                            timePitch: Bool = false,
                            rendering: AudioGraphRenderingMode = .offline) throws -> PerformanceEngine {
        try PerformanceEngine(configuration: .init(sampleRate: 48_000, channelCount: 1,
                                                   ringCapacity: ringCapacity,
                                                   rendering: rendering,
                                                   limiterCeiling: limiterCeiling,
                                                   limiterLookaheadFrames: limiterLookaheadFrames,
                                                   timePitch: timePitch))
    }

    private func sineSource(frames: Int = 48_000) -> TestSource {
        TestSource(frames: frames) { sineValue(at: $0) }
    }

    private func rampSource(frames: Int = 10_000, grid: DeckGrid = .init(),
                            _ generator: @escaping (Int) -> Float = { Float($0) }) -> TestSource {
        TestSource(frames: frames, grid: grid, generator)
    }

    private func sineValue(at trackSample: Int) -> Float {
        0.25 * Float(sin(2 * Double.pi * 440.0 * Double(trackSample) / 48_000.0))
    }

    private func sineReference(count: Int) -> [Float] {
        (0..<count).map { sineValue(at: $0) }
    }

    /// Render `count` frames in manual-rendering-maximum chunks, because the
    /// offline engine rejects a single request beyond that
    /// (`kAudioUnitErr_TooManyFramesToProcess`).
    private func renderFrames(_ engine: PerformanceEngine, count: Int) throws -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(count)
        var remaining = count
        while remaining > 0 {
            let chunk = AVAudioFrameCount(min(4096, remaining))
            out += try engine.renderMono(chunk)
            remaining -= Int(chunk)
        }
        return out
    }
}

/// An owned, heap-backed PCM source for the offline harness. The engine boxes
/// only the `DeckSource` value; the test keeps the underlying `Float` buffer
/// alive for the engine's lifetime.
private final class TestSource {
    let buffer: UnsafeMutablePointer<Float>
    let source: DeckSource

    init(frames: Int, channels: Int = 1, sampleRate: Double = 48_000,
         grid: DeckGrid = DeckGrid(), _ generator: (Int) -> Float) {
        buffer = .allocate(capacity: frames * channels)
        for i in 0..<(frames * channels) {
            buffer[i] = generator(i)
        }
        source = DeckSource(pcm: UnsafeRawPointer(buffer), frameCount: Int64(frames),
                            channelCount: channels, sampleRate: sampleRate, grid: grid)
    }

    deinit {
        buffer.deallocate()
    }
}
