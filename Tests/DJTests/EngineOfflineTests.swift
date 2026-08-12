import XCTest
import AVFoundation

@testable import TonearmDJ

/// Commit 4.1 — the RT boundary under test (plan §5, spec §12/§46.3/§34.3).
///
/// Two tiers:
/// - pure boundary tests: the SPSC command ring (FIFO, full/empty, pointer
///   payload), the double-buffered snapshot (publish/read/retire), the RTGuard
///   shim, and `RenderLoad` metering;
/// - the offline-render harness: a manual-rendering `AVAudioEngine` graph with
///   a known sine source, driven only through the command ring, with the RTGuard
///   shim active. Assertions are sample-referenced — a pitch change lands on the
///   exact frame (AT-ENGINE-\*), and a long render never overruns.
final class EngineOfflineTests: XCTestCase {

    // MARK: - Command ring

    func testRingPushDrainPreservesOrderAndValues() {
        let ring = CommandRing(capacity: 8)
        for frequency in [440, 441, 442, 443, 444] {
            XCTAssertTrue(ring.tryPush(.setPitch(deck: 0, frequency: Float(frequency))))
        }
        XCTAssertEqual(ring.count, 5)

        var received: [Float] = []
        let drained = ring.drain { received.append($0.f0) }
        XCTAssertEqual(drained, 5)
        XCTAssertEqual(received, [440, 441, 442, 443, 444])
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

    // MARK: - Offline render harness

    func testOfflineGraphRendersReferenceSine() throws {
        let graph = try AudioGraph()
        try graph.start()
        defer { graph.stop() }

        let samples = try render(graph, frames: 512)
        let expected = sineReference(frequency: 440, sampleRate: 48_000, amplitude: 0.25, count: 512)
        for i in 0..<512 {
            XCTAssertEqual(samples[i], expected[i], accuracy: 0.0005, "sample \(i)")
        }
        XCTAssertGreaterThan(samples.reduce(0) { max($0, abs($1)) }, 0.2)
    }

    func testPauseMutesAndPlayResumesWithFrozenPhase() throws {
        let graph = try AudioGraph()
        try graph.start()
        defer { graph.stop() }

        let head = try render(graph, frames: 64)
        XCTAssertGreaterThan(head.reduce(0) { max($0, abs($1)) }, 0.2)

        XCTAssertTrue(graph.commandRing.tryPush(.pause(deck: 0)))
        let silent = try render(graph, frames: 32)
        XCTAssertTrue(silent.allSatisfy { $0 == 0 }, "paused deck must render silence")

        XCTAssertTrue(graph.commandRing.tryPush(.play(deck: 0)))
        let resumed = try render(graph, frames: 32)
        // The playhead froze during the pause: the resumed run continues exactly
        // where the 64th frame ended, at 440 Hz.
        let step = 2 * Double.pi * 440.0 / 48_000.0
        var phase = (64.0 * step).truncatingRemainder(dividingBy: 2 * Double.pi)
        for (i, value) in resumed.enumerated() {
            let expected = 0.25 * Float(sin(phase))
            XCTAssertEqual(value, expected, accuracy: 0.0005, "sample \(i)")
            phase += step
            if phase >= 2 * Double.pi { phase -= 2 * Double.pi }
        }
    }

    func testSetPitchAppliesAtExactFrameBoundary() throws {
        let graph = try AudioGraph(configuration: .init(initialFrequency: 440, initialAmplitude: 0.25))
        try graph.start()
        defer { graph.stop() }

        // 100 frames at 440 Hz in one callback.
        let head = try render(graph, frames: 100)

        // The command is drained at the top of the NEXT callback, so frame 100
        // is the first produced at 880 Hz — sample-exact (§47.2, AT-ENGINE-*).
        XCTAssertTrue(graph.commandRing.tryPush(.setPitch(deck: 0, frequency: 880)))
        let tail = try render(graph, frames: 5, chunk: 1)

        let samples = head + tail
        var phase = 0.0
        for (k, actual) in samples.enumerated() {
            let frequency = k < 100 ? 440.0 : 880.0
            let expected = 0.25 * Float(sin(phase))
            XCTAssertEqual(actual, expected, accuracy: 0.0005, "sample \(k)")
            phase += 2 * Double.pi * frequency / 48_000.0
            if phase >= 2 * Double.pi { phase -= 2 * Double.pi }
        }
    }

    func testRTGuardWrapsOfflineRender() throws {
        let graph = try AudioGraph()
        try graph.start()
        defer { graph.stop() }
        _ = try render(graph, frames: 128)
        #if DEBUG
        XCTAssertTrue(graph.guardWasActive, "the render callback must run inside RTGuard")
        #else
        XCTAssertFalse(graph.guardWasActive)
        #endif
    }

    func testLongRenderNoOverrunAndLoadSane() throws {
        // A 10 s offline render in 512-frame chunks while the producer hammers
        // the ring with bursts far larger than its capacity: pushes fail softly
        // (§12.2 coalesce/drop), the render never misses a frame, and the output
        // stays bounded — the "never overrun" property of the boundary (§34.1).
        let graph = try AudioGraph(configuration: .init(ringCapacity: 8))
        try graph.start()
        defer { graph.stop() }

        let chunk = 512
        let total = 48_000 * 10
        var rendered = 0
        var maxAbs: Float = 0
        var nonFinite = false

        while rendered < total {
            for i in 0..<20 {
                _ = graph.commandRing.tryPush(.setPitch(deck: 0, frequency: 440 + Float(i % 5)))
            }
            _ = graph.commandRing.tryPush(.play(deck: 0))

            let count = AVAudioFrameCount(min(chunk, total - rendered))
            let buffer = try graph.render(count)
            XCTAssertEqual(buffer.frameLength, count)
            guard let channel = buffer.floatChannelData?[0] else {
                XCTFail("render returned no float channel")
                return
            }
            for i in 0..<Int(buffer.frameLength) {
                let value = channel[i]
                if !value.isFinite { nonFinite = true }
                maxAbs = max(maxAbs, abs(value))
            }
            rendered += Int(buffer.frameLength)
        }

        XCTAssertEqual(rendered, total, "the harness must render every requested frame")
        XCTAssertFalse(nonFinite, "render produced non-finite samples")
        XCTAssertLessThanOrEqual(maxAbs, 0.26, "render produced out-of-range samples")

        XCTAssertGreaterThan(graph.renderLoad.lastRenderNanos, 0)
        let periodNanos = UInt64((128.0 / 48_000.0) * 1e9) // 128-frame buffer period
        XCTAssertLessThan(graph.renderLoad.loadRatio(periodNanos: periodNanos), 1.0,
                          "render load must leave headroom below the buffer period")
    }

    // MARK: - Helpers

    private func render(_ graph: AudioGraph, frames: Int, chunk: Int = 512) throws -> [Float] {
        var out: [Float] = []
        var remaining = frames
        while remaining > 0 {
            let count = AVAudioFrameCount(min(remaining, chunk))
            let buffer = try graph.render(count)
            guard let channel = buffer.floatChannelData?[0] else { return [] }
            out.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            remaining -= Int(buffer.frameLength)
        }
        return out
    }

    /// The exact phase-accumulator model the render block implements, so a
    /// rendered buffer can be compared sample-by-sample.
    private func sineReference(frequency: Double, sampleRate: Double, amplitude: Float,
                               startingPhase: Double = 0, count: Int) -> [Float] {
        var phase = startingPhase
        let step = 2 * Double.pi * frequency / sampleRate
        var out: [Float] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            out.append(amplitude * Float(sin(phase)))
            phase += step
            if phase >= 2 * Double.pi { phase -= 2 * Double.pi }
        }
        return out
    }
}
