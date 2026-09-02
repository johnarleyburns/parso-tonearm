import XCTest
import AVFoundation

@testable import TonearmDJ

/// Commit 5.10 — the §37.2 record tap + encoder (plan §5 5.10, FR-ENG-7).
///
/// Three tiers, mirroring the plan's test list:
/// - **tap → drain matches the rendered master buffer**: a real offline render
///   through a `recordTapEnabled` graph, then draining the ring returns exactly
///   what the master produced (bit-exact — the tap is a pure copy).
/// - **tap idle leaves the reader bit-exact**: an enabled-but-not-recording tap
///   leaves the rendered output identical to a graph with no tap at all.
/// - **the ring absorbs a dropped drain**: a tiny ring, no drain, a render far
///   past capacity — the render never blocks, the audio stays correct, and the
///   overflow is counted (samples are dropped, never the performance).
/// - **encoder**: drain → finalize produces a playable segmented M4A whose
///   decoded content matches the source (AAC is lossy, so the assertion is
///   duration + dominant frequency, the repo's established tolerance pattern).
@MainActor
final class RecordTapTests: XCTestCase {

    // MARK: - tap → drain matches the rendered master buffer

    func testTapDrainMatchesRenderedMasterBuffer() throws {
        let engine = try makeEngine(recordTapEnabled: true)
        try engine.start()
        defer { engine.stop() }

        let source = sineSource(frames: 48_000)
        engine.load(.a, source: source.source)
        engine.play(.a)

        engine.graph.recordTap?.setRecording(true)
        let master = try engine.renderMono(512)
        XCTAssertGreaterThan(master.reduce(0) { max($0, abs($1)) }, 0.2)

        guard let tap = engine.graph.recordTap else {
            return XCTFail("recordTapEnabled graph must construct a tap")
        }
        XCTAssertEqual(tap.availableFrames, 512)

        var drained = [Float](repeating: 0, count: 512)
        let read = drained.withUnsafeMutableBufferPointer { ptr in
            tap.read(maxFrames: 512, into: ptr.baseAddress!)
        }
        XCTAssertEqual(read, 512)
        XCTAssertEqual(tap.availableFrames, 0)
        for i in 0..<512 {
            XCTAssertEqual(drained[i], master[i], "the tap must be a pure copy, sample \(i)")
        }
        XCTAssertEqual(tap.droppedFrames, 0, "a ring that fits drops nothing")
    }

    func testTapIdleLeavesReaderBitExact() throws {
        // A graph with an enabled but idle tap must render identically to a
        // graph with no tap at all — the tap is read-only on the signal and
        // does no work unless recording (§37.2, plan 5.10).
        let plain = try makeEngine(recordTapEnabled: false)
        let tapped = try makeEngine(recordTapEnabled: true)
        try plain.start()
        try tapped.start()
        defer {
            plain.stop()
            tapped.stop()
        }

        let sourceA = sineSource(frames: 48_000)
        let sourceB = sineSource(frames: 48_000)
        plain.load(.a, source: sourceA.source)
        tapped.load(.a, source: sourceB.source)
        plain.play(.a)
        tapped.play(.a)

        let a = try plain.renderMono(512)
        let b = try tapped.renderMono(512)
        for i in 0..<512 {
            XCTAssertEqual(a[i], b[i], "idle tap must leave the reader bit-exact, sample \(i)")
        }
        XCTAssertEqual(tapped.graph.recordTap?.availableFrames, 0,
                       "an idle tap captures nothing")
    }

    // MARK: - the ring absorbs a dropped drain

    func testRingAbsorbsDroppedDrain() throws {
        // A 64-frame ring, one 1024-frame render, no drain in between: the
        // render must complete without blocking and the audio must be correct
        // — the overflow is dropped and counted, never the performance.
        let engine = try makeEngine(recordTapEnabled: true, tapCapacity: 64)
        try engine.start()
        defer { engine.stop() }

        let source = sineSource(frames: 48_000)
        engine.load(.a, source: source.source)
        engine.play(.a)

        engine.graph.recordTap?.setRecording(true)
        let master = try engine.renderMono(1024)
        let expected = sineReference(count: 1024)
        for i in 0..<1024 {
            XCTAssertEqual(master[i], expected[i], accuracy: 0.0005,
                           "the render must stay correct with a full ring, sample \(i)")
        }

        guard let tap = engine.graph.recordTap else {
            return XCTFail("recordTapEnabled graph must construct a tap")
        }
        XCTAssertEqual(tap.droppedFrames, 1024,
                       "a 64-frame ring holds none of a 1024-frame render — all dropped, none blocked")
        XCTAssertEqual(tap.availableFrames, 0)
    }

    // MARK: - encoder: drain → finalize → a playable segmented M4A

    func testEncoderFinalizesPlayableM4A() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let tap = RecordTap(sampleRate: 48_000, channelCount: 1, capacityFrames: 96_000)
        try writeSine(into: tap, frames: 48_000) // 1 s @ 48 kHz

        let encoder = try RecordingEncoder(tap: tap, configuration: .init(
            sampleRate: 48_000, channelCount: 1,
            segmentFrames: 96_000, // no mid-stream flush — one segment
            outputDirectory: tmp))
        try await encoder.start()
        while tap.availableFrames > 0 {
            _ = try await encoder.drain(maxFrames: 8192)
        }
        let output = try await encoder.finalize()

        XCTAssertEqual(output.segmentURLs.count, 1)
        XCTAssertEqual(output.format, RecordingEncoder.formatName)
        XCTAssertGreaterThan(output.totalFrames, 40_000,
                             "nearly all of a 1 s sine must survive the ring + encode")
        XCTAssertEqual(output.duration, 1.0, accuracy: 0.1)

        // Read the M4A back: it must decode, be ~1 s long, and its dominant
        // frequency must be the source's 440 Hz (AAC tolerance — the plan's
        // "finalize matches the rendered master buffer" within codec loss).
        let file = try AVAudioFile(forReading: output.segmentURLs[0])
        XCTAssertEqual(file.processingFormat.sampleRate, 48_000, accuracy: 1)
        let decoded = try readAllFrames(file)
        XCTAssertGreaterThan(decoded.count, 40_000, "the M4A must decode real audio")
        let frequency = measuredFrequency(decoded)
        XCTAssertEqual(frequency, 440.0, accuracy: 440.0 * 0.02,
                       "the recorded mix must preserve the source pitch (measured \(frequency) Hz)")
    }

    func testEncoderFlushesSegmentsOnBudget() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let tap = RecordTap(sampleRate: 48_000, channelCount: 1, capacityFrames: 96_000)
        try writeSine(into: tap, frames: 48_000)

        let encoder = try RecordingEncoder(tap: tap, configuration: .init(
            sampleRate: 48_000, channelCount: 1,
            segmentFrames: 16_000, // flush every ~1/3 s
            outputDirectory: tmp))
        try await encoder.start()
        _ = try await encoder.drain(maxFrames: 8192)
        let output = try await encoder.finalize()

        XCTAssertEqual(output.segmentURLs.count, 3,
                       "1 s / 1/3 s budget → three playable segments")
        for url in output.segmentURLs {
            let file = try AVAudioFile(forReading: url)
            XCTAssertGreaterThan(try readAllFrames(file).count, 1000,
                                 "every flushed segment must be a complete, playable M4A")
        }
        XCTAssertEqual(output.totalFrames, 48_000)
    }

    func testPerformanceEngineStartStopRecording() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let engine = try PerformanceEngine(
            configuration: .init(sampleRate: 48_000, channelCount: 1,
                                 recordTapEnabled: true,
                                 recordTapCapacityFrames: 96_000),
            recordingDirectory: tmp)
        try engine.start()
        defer { engine.stop() }

        XCTAssertFalse(engine.isRecording)
        _ = try await engine.startRecording()
        XCTAssertTrue(engine.isRecording)

        let source = sineSource(frames: 48_000)
        engine.load(.a, source: source.source)
        engine.play(.a)
        _ = try renderFrames(engine, count: 24_000)

        let output = try await engine.stopRecording()
        XCTAssertFalse(engine.isRecording)
        XCTAssertNotNil(output)
        XCTAssertEqual(output?.segmentURLs.count, 1)
        let file = try AVAudioFile(forReading: output!.segmentURLs[0])
        XCTAssertGreaterThan(try readAllFrames(file).count, 10_000,
                             "the engine façade must produce a playable recording")
    }

    func testStartRecordingWithoutTapIsHonest() async throws {
        // A graph built with recordTapEnabled: false has no tap — startRecording
        // must throw the honest unavailable error, not silently no-op.
        let engine = try PerformanceEngine(configuration: .init(sampleRate: 48_000,
                                                                channelCount: 1))
        try engine.start()
        defer { engine.stop() }
        do {
            _ = try await engine.startRecording()
            XCTFail("startRecording without a record tap must throw")
        } catch RecordingEncoder.RecordingError.tapNotRecording {
            // expected
        }
    }

    // MARK: - Helpers

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

    private func makeEngine(recordTapEnabled: Bool,
                            tapCapacity: Int = 96_000) throws -> PerformanceEngine {
        try PerformanceEngine(configuration: .init(sampleRate: 48_000, channelCount: 1,
                                                   recordTapEnabled: recordTapEnabled,
                                                   recordTapCapacityFrames: tapCapacity))
    }

    private func sineSource(frames: Int = 48_000) -> TestSource {
        TestSource(frames: frames) { sineValue(at: $0) }
    }

    private func sineValue(at trackSample: Int) -> Float {
        0.25 * Float(sin(2 * Double.pi * 440.0 * Double(trackSample) / 48_000.0))
    }

    private func sineReference(count: Int) -> [Float] {
        (0..<count).map { sineValue(at: $0) }
    }

    /// Fill a mono tap with `frames` samples of a 440 Hz sine by writing through
    /// the tap's render-side `write(into:frames:)` — the same path the graph's
    /// render closures use (§37.2). Chunked at 4096 frames so a block always
    /// fits a ring that is ≥ 8192 frames (the render callback writes bounded
    /// blocks; a single oversized write would be dropped by design).
    private func writeSine(into tap: RecordTap, frames: Int) throws {
        tap.setRecording(true)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                   channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(4096))!
        let data = buffer.floatChannelData![0]
        var written = 0
        while written < frames {
            let count = min(4096, frames - written)
            for i in 0..<count {
                data[i] = sineValue(at: written + i)
            }
            buffer.frameLength = AVAudioFrameCount(count)
            tap.write(into: UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList),
                      frames: count)
            written += count
        }
    }

    /// Decode every frame of a file as channel 0.
    private func readAllFrames(_ file: AVAudioFile) throws -> [Float] {
        var out: [Float] = []
        let format = file.processingFormat
        let chunk: AVAudioFrameCount = 16_384
        var remaining = file.length
        while remaining > 0 {
            let count = AVAudioFrameCount(min(Int64(chunk), remaining))
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
            try file.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0 else { break }
            if let data = buffer.floatChannelData {
                out.append(contentsOf: UnsafeBufferPointer(start: data[0],
                                                           count: Int(buffer.frameLength)))
            }
            remaining -= Int64(buffer.frameLength)
        }
        return out
    }

    /// The dominant frequency of `samples` by zero crossings over the whole
    /// buffer (each cycle contributes two crossings) — the repo's established
    /// lossy-codec assertion (§31 time-pitch tests).
    private func measuredFrequency(_ samples: [Float]) -> Double {
        guard samples.count > 8 else { return 0 }
        var crossings = 0
        var last = samples[0]
        for i in 1..<samples.count {
            let s = samples[i]
            if (last < 0 && s >= 0) || (last >= 0 && s < 0) { crossings += 1 }
            last = s
        }
        return Double(crossings) * 48_000.0 / (2.0 * Double(samples.count))
    }
}

/// An owned, heap-backed PCM source for the offline harness (same shape as
/// `EngineOfflineTests.TestSource`, local so the recording tests stay
/// self-contained).
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
