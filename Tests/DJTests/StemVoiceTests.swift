import XCTest
import AVFoundation

@testable import TonearmDJ

/// Commit 5.8 — stem voices live on decks (§35.1, plan decision 3), the engine
/// rows of AT-STEM-\*: the reader sums the four voices at the shared playhead
/// with per-voice smoothed gains, and **a deck with no stem set is byte-for-byte
/// the current single-source reader**. All assertions run against the
/// deterministic offline-render harness (§47.2, the AT-ENGINE-* tier).
@MainActor
final class StemVoiceTests: XCTestCase {

    private func makeEngine(ringCapacity: Int = 16) throws -> PerformanceEngine {
        try PerformanceEngine(configuration: .init(sampleRate: 48_000, channelCount: 1,
                                                   ringCapacity: ringCapacity))
    }

    /// A deterministic mono voice generator: `amplitude × sin(2π·f·i/48000 + phase)`.
    private func tone(_ frequency: Double, _ amplitude: Double, phase: Double = 0) -> (Int) -> Float {
        { i in
            Float(amplitude * sin(2 * Double.pi * frequency * Double(i) / 48_000 + phase))
        }
    }

    private func voiceSource(frames: Int = 48_000, grid: DeckGrid = DeckGrid(),
                             _ generator: @escaping (Int) -> Float) -> TestVoiceSource {
        TestVoiceSource(frames: frames, grid: grid, generator)
    }

    private func makeStemSet(vocals: TestVoiceSource, drums: TestVoiceSource,
                             bass: TestVoiceSource, other: TestVoiceSource) -> StemSet {
        StemSet(vocals: vocals.source, drums: drums.source,
                bass: bass.source, other: other.source)
    }

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

    // MARK: - Bit-identical fallback (plan decision 3)

    func testDeckWithoutStemSetIsByteForByteTheCurrentReader() throws {
        let engine = try makeEngine()
        try engine.start()
        defer { engine.stop() }

        let fullMix = voiceSource(frames: 20_000, tone(440, 0.25))
        engine.load(.a, source: fullMix.source)
        engine.play(.a)

        // No stem set armed → the reader is exactly the M4 single-source path.
        let baseline = try renderFrames(engine, count: 512)
        for (i, value) in baseline.enumerated() {
            XCTAssertEqual(value, Float(0.25 * sin(2 * Double.pi * 440 * Double(i) / 48_000)),
                           accuracy: 0.0005, "sample \(i)")
        }

        // Arming a passthrough set (vocals = full mix, others silent) is
        // sample-transparent: the playhead is preserved and the reader produces
        // exactly the full-mix samples the single-source path would have.
        let vocals = voiceSource(frames: 20_000, tone(440, 0.25))
        let silent = voiceSource(frames: 20_000, { _ in 0 })
        engine.armStemSet(.a, stemSet: makeStemSet(vocals: vocals, drums: silent,
                                                   bass: silent, other: silent))
        let armed = try renderFrames(engine, count: 512)
        for (k, value) in armed.enumerated() {
            let i = 512 + k
            XCTAssertEqual(value, Float(0.25 * sin(2 * Double.pi * 440 * Double(i) / 48_000)),
                           accuracy: 0.0005, "armed sample \(k) = track \(i)")
        }

        // Disarming restores the single-source reader byte-for-byte.
        engine.armStemSet(.a, stemSet: nil)
        let disarmed = try renderFrames(engine, count: 512)
        for (k, value) in disarmed.enumerated() {
            let i = 1024 + k
            XCTAssertEqual(value, Float(0.25 * sin(2 * Double.pi * 440 * Double(i) / 48_000)),
                           accuracy: 0.0005, "disarmed sample \(k) = track \(i)")
        }
    }

    func testStemArmedDeckWithoutFullMixStillReadsTheVoices() throws {
        let engine = try makeEngine()
        try engine.start()
        defer { engine.stop() }

        // A stem set armed without a full-mix source (the §36.5 swap path) must
        // still render — the reader's reference falls back to the set's voices.
        let vocals = voiceSource(frames: 48_000, tone(440, 0.25))
        let silent = voiceSource(frames: 48_000, { _ in 0 })
        engine.armStemSet(.a, stemSet: makeStemSet(vocals: vocals, drums: silent,
                                                   bass: silent, other: silent))
        engine.play(.a)

        let samples = try renderFrames(engine, count: 512)
        for (i, value) in samples.enumerated() {
            XCTAssertEqual(value, Float(0.25 * sin(2 * Double.pi * 440 * Double(i) / 48_000)),
                           accuracy: 0.0005, "sample \(i)")
        }
    }

    // MARK: - Frame-exact summing (§35.1)

    func testFourVoicesSumFrameExactAtUnity() throws {
        let engine = try makeEngine()
        try engine.start()
        defer { engine.stop() }

        let vocals = voiceSource(tone(440, 0.25))
        let drums = voiceSource(tone(220, 0.1))
        let bass = voiceSource(tone(110, 0.05, phase: .pi / 2))
        let other = voiceSource { i in 0.01 * Float(i % 7) }
        engine.armStemSet(.a, stemSet: makeStemSet(vocals: vocals, drums: drums,
                                                   bass: bass, other: other))
        engine.play(.a)

        let samples = try renderFrames(engine, count: 512)
        for (i, value) in samples.enumerated() {
            let expected = Float(0.25 * sin(2 * Double.pi * 440 * Double(i) / 48_000))
                + Float(0.1 * sin(2 * Double.pi * 220 * Double(i) / 48_000))
                + Float(0.05 * cos(2 * Double.pi * 110 * Double(i) / 48_000))
                + 0.01 * Float(i % 7)
            XCTAssertEqual(value, expected, accuracy: 0.0005,
                           "sample \(i): the four voices sum at the shared playhead")
        }
        XCTAssertGreaterThan(samples.reduce(0) { max($0, abs($1)) }, 0.1)
    }

    func testStemGainScalesAVoiceAfterTheRamp() throws {
        let engine = try makeEngine()
        try engine.start()
        defer { engine.stop() }

        let vocals = voiceSource(tone(440, 0.25))
        let drums = voiceSource(tone(220, 0.1))
        let silent = voiceSource { _ in 0 }
        engine.armStemSet(.a, stemSet: makeStemSet(vocals: vocals, drums: drums,
                                                   bass: silent, other: silent))
        engine.play(.a)
        _ = try renderFrames(engine, count: 512) // settle at unity

        engine.setStemGain(.a, stem: .vocals, gain: 0.5)
        let samples = try renderFrames(engine, count: 4096)

        // After the one-pole ramp settles (~240 samples), vocals halve.
        let settled = Array(samples.suffix(1024))
        for (k, value) in settled.enumerated() {
            let i = 512 + 4096 - 1024 + k
            let expected = Float(0.25 * 0.5 * sin(2 * Double.pi * 440 * Double(i) / 48_000))
                + Float(0.1 * sin(2 * Double.pi * 220 * Double(i) / 48_000))
            XCTAssertEqual(value, expected, accuracy: 0.0005, "sample \(i)")
        }
    }

    func testStemMuteRampsAVoiceToSilence() throws {
        let engine = try makeEngine()
        try engine.start()
        defer { engine.stop() }

        let vocals = voiceSource(tone(440, 0.25))
        let drums = voiceSource(tone(220, 0.1))
        let silent = voiceSource { _ in 0 }
        engine.armStemSet(.a, stemSet: makeStemSet(vocals: vocals, drums: drums,
                                                   bass: silent, other: silent))
        engine.play(.a)
        _ = try renderFrames(engine, count: 512)

        engine.setStemMute(.a, stem: .vocals, muted: true)
        let samples = try renderFrames(engine, count: 4096)
        let settled = Array(samples.suffix(1024))
        for (k, value) in settled.enumerated() {
            let i = 512 + 4096 - 1024 + k
            let expected = Float(0.1 * sin(2 * Double.pi * 220 * Double(i) / 48_000))
            XCTAssertEqual(value, expected, accuracy: 0.0005,
                           "sample \(i): the muted voice is gone, the rest unaffected")
        }
    }

    func testStemSoloIsolatesTheSoloedVoice() throws {
        let engine = try makeEngine()
        try engine.start()
        defer { engine.stop() }

        let vocals = voiceSource(tone(440, 0.25))
        let drums = voiceSource(tone(220, 0.1))
        let silent = voiceSource { _ in 0 }
        engine.armStemSet(.a, stemSet: makeStemSet(vocals: vocals, drums: drums,
                                                   bass: silent, other: silent))
        engine.play(.a)
        _ = try renderFrames(engine, count: 512)

        engine.setStemSolo(.a, stem: .drums, soloed: true)
        let samples = try renderFrames(engine, count: 4096)
        let settled = Array(samples.suffix(1024))
        for (k, value) in settled.enumerated() {
            let i = 512 + 4096 - 1024 + k
            let expected = Float(0.1 * sin(2 * Double.pi * 220 * Double(i) / 48_000))
            XCTAssertEqual(value, expected, accuracy: 0.0005,
                           "sample \(i): soloing drums silences every other voice")
        }
    }

    func testStemSetGridDrivesTheMasterClock() throws {
        // The set's grid is the deck's grid (§35.1): with no full-mix source,
        // the master clock's effective BPM comes from the armed set.
        let grid = DeckGrid(referenceSample: 0, bpm: 124, beatsPerBar: 4, sampleRate: 48_000)
        let engine = try makeEngine()
        try engine.start()
        defer { engine.stop() }

        let vocals = voiceSource(frames: 48_000, grid: grid, tone(440, 0.25))
        let silent = voiceSource(frames: 48_000, grid: grid, { _ in 0 })
        engine.armStemSet(.a, stemSet: makeStemSet(vocals: vocals, drums: silent,
                                                   bass: silent, other: silent))
        engine.play(.a)
        _ = try renderFrames(engine, count: 256)

        let telemetry = engine.sampleTelemetry()
        XCTAssertEqual(telemetry.masterBPM, 124, accuracy: 0.01,
                       "the armed set's grid is the deck's grid — the master clock reads its BPM")
    }
}

/// An owned, heap-backed mono PCM source for the stem harness. Mirrors the
/// offline harness's `TestSource` (the engine boxes only the `DeckSource`
/// value; the test keeps the buffer alive for the engine's lifetime).
private final class TestVoiceSource {
    let buffer: UnsafeMutablePointer<Float>
    let source: DeckSource

    init(frames: Int = 48_000, grid: DeckGrid = DeckGrid(), _ generator: (Int) -> Float) {
        buffer = .allocate(capacity: frames)
        for i in 0..<frames {
            buffer[i] = generator(i)
        }
        source = DeckSource(pcm: UnsafeRawPointer(buffer), frameCount: Int64(frames),
                            channelCount: 1, sampleRate: 48_000, grid: grid)
    }

    deinit {
        buffer.deallocate()
    }
}
