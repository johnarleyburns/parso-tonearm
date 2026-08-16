import XCTest
import Accelerate

@testable import TonearmDJ

/// Commit 5.7 — Demucs ODR + separation + cache (plan 5.7, §36, FR-ENG-3).
///
/// The chunk/overlap-add kernel and the `StemSeparator` pipeline driven against
/// a **deterministic fake stem model** (plan decision 1) so the kernel, its
/// golden reconstruction and the absence path are all testable off-device:
///
/// - The periodic-Hann window has exact first-power COLA at 50% overlap, which
///   is what makes overlap-add reconstruction exact (§36.2).
/// - A passthrough model reconstructs its input exactly in the interior —
///   the "reconstruction golden across chunk boundaries" (plan 5.7).
/// - Absence is a value (FR-SEM-6): no model → `separate` returns nil, and a
///   model that stops mid-run is loud, never a partial result (ADR-10).
final class StemSeparatorTests: XCTestCase {

    // MARK: - The fake model (plan decision 1)

    /// Deterministic fake: every voice is exactly the chunk's stereo input
    /// (a pure passthrough). This makes the reconstruction test a golden — a
    /// passthrough model + the §36.2 overlap-add reconstructs the input.
    private struct PassthroughStemModel: StemModelProviding {
        var version: Int = AnalysisVersions.stems
        var available: Bool = true

        func isAvailable() async -> Bool { available }

        func separate(chunk: StemChunk) async throws -> StemSeparation? {
            guard available else { return nil }
            return StemSeparation(sampleRate: chunk.sampleRate,
                                  vocals: chunk, drums: chunk,
                                  bass: chunk, other: chunk)
        }
    }

    // MARK: - Window / COLA

    func testWindowSatisfiesFirstPowerCOLAAtHalfOverlap() {
        for count in [1024, 2048, 4096, StemChunking.chunkFrames] {
            let window = StemChunking.window(count)
            XCTAssertEqual(window.count, count)
            for i in 0..<(count / 2) {
                XCTAssertEqual(window[i] + window[i + count / 2], 1, accuracy: 1e-6,
                               "periodic Hann at 50% overlap sums to unity — the §36.2 COLA contract")
            }
        }
    }

    func testWindowBounds() {
        let window = StemChunking.window(1024)
        XCTAssertEqual(window[0], 0, accuracy: 1e-6)
        XCTAssertEqual(window[512], 1, accuracy: 1e-6, "Hann peaks at the centre")
        // The periodic Hann's last sample is cos(2π(N−1)/N) ≈ 1 − (2π/N)²/2 —
        // not exactly zero; the COLA identity, not the endpoint, is the contract.
        XCTAssertLessThan(window[1023], 1e-4)
    }

    // MARK: - Chunking

    func testChunkingProducesEqualLengthZeroPaddedChunks() {
        let left = [Float](repeating: 1, count: 1200)
        let right = [Float](repeating: 0.5, count: 1200)
        let chunked = StemChunking.chunks(left: left, right: right,
                                          chunkFrames: 1024, hop: 512)
        XCTAssertEqual(chunked.count, 3, "ceil(1200/512) = 3 chunks")
        for (i, chunk) in chunked.enumerated() {
            XCTAssertEqual(chunk.left.count, 1024, "every chunk is exactly chunkFrames")
            XCTAssertEqual(chunk.right.count, 1024)
            if i == chunked.count - 1 {
                XCTAssertEqual(chunk.left[1023], 0, "the final chunk is zero-padded")
                XCTAssertEqual(chunk.left[1000], 0, "past the signal's end")
            }
        }
    }

    func testChunkingReturnsEmptyForEmptyInput() {
        let chunked = StemChunking.chunks(left: [], right: [],
                                          chunkFrames: 1024, hop: 512)
        XCTAssertTrue(chunked.isEmpty)
    }

    // MARK: - Overlap-add reconstruction golden

    /// A deterministic stereo signal with independent L/R content.
    private func makeSignal(frames: Int, seed: UInt64) -> (left: [Float], right: [Float]) {
        var leftRNG = SplitMix64(seed: seed)
        var rightRNG = SplitMix64(seed: seed ^ 0x0A55_CA11)
        let left = (0..<frames).map { i -> Float in
            let t = Double(i) / 48_000.0
            let tone = 0.5 * sin(2.0 * Double.pi * 55.0 * t)
            let r = Double(leftRNG.next() % 1000)
            return Float(tone) + Float(r / 1000.0 - 0.5) * 0.1
        }
        let right = (0..<frames).map { i -> Float in
            let t = Double(i) / 48_000.0
            let tone = 0.4 * sin(2.0 * Double.pi * 611.0 * t)
            let r = Double(rightRNG.next() % 1000)
            return Float(tone) + Float(r / 1000.0 - 0.5) * 0.1
        }
        return (left, right)
    }

    func testOverlapAddReconstructsInputAcrossChunkBoundaries() {
        let chunkFrames = 1024
        let hop = 512
        let frames = 5000
        let signal = (0..<frames).map { i -> Float in
            let t = Double(i) / 48_000.0
            let tone = Float(0.6 * sin(2.0 * Double.pi * 200.0 * t))
            let impulse: Float = (i % 97 == 0) ? 0.5 : 0.0 // deterministic, inside every chunk
            return tone + impulse
        }

        let chunked = StemChunking.chunks(left: signal, right: signal,
                                          chunkFrames: chunkFrames, hop: hop)
        let window = StemChunking.window(chunkFrames)
        let reconstructed = StemChunking.overlapAdd(chunkOutputs: chunked.map { $0.left },
                                                    window: window, hop: hop,
                                                    totalFrames: frames)

        XCTAssertEqual(reconstructed.count, frames)
        // Interior [hop, frames-hop): window coverage is complete there.
        for i in hop..<(frames - hop) {
            XCTAssertEqual(reconstructed[i], signal[i], accuracy: 1e-4,
                           "frame \(i) reconstructs exactly across a chunk boundary")
        }
    }

    func testSeparatorReconstructsAllFourVoicesEndToEnd() async throws {
        let (left, right) = makeSignal(frames: 10_000, seed: 0xABCD)
        let pcm = PCMBuffer(sampleRate: 48_000, channels: [left, right])
        let separator = StemSeparator(model: PassthroughStemModel(),
                                      chunkFrames: 2048, overlapFrames: 1024)

        let result = try await separator.separate(pcm: pcm)
        let separated = try XCTUnwrap(result,
                                      "an available model never returns nil")
        let interior = 1024..<(left.count - 1024)
        for kind in StemKind.allCases {
            let voice = separated.voice(kind)
            XCTAssertEqual(voice.frameCount, left.count, "each voice spans the whole track")
            XCTAssertEqual(voice.sampleRate, 48_000)
            for i in interior {
                XCTAssertEqual(voice.left[i], left[i], accuracy: 1e-4,
                               "\(kind.rawValue) left reconstructs at frame \(i)")
                XCTAssertEqual(voice.right[i], right[i], accuracy: 1e-4,
                               "\(kind.rawValue) right reconstructs at frame \(i)")
            }
        }
    }

    func testSeparatorMatchesPureKernelExactly() async throws {
        // The pipeline must be byte-for-byte what the pure kernel computes —
        // otherwise the kernel test proves nothing about what ships.
        let chunkFrames = 1024
        let hop = 512
        let frames = 4096
        var rng = SplitMix64(seed: 0xBEEF)
        let signal = (0..<frames).map { _ in
            Float(Double(rng.next() % 200_000) / 100_000 - 1)
        }
        let pcm = PCMBuffer(sampleRate: 48_000, channels: [signal, signal])
        let separator = StemSeparator(model: PassthroughStemModel(),
                                      chunkFrames: chunkFrames, overlapFrames: 512)
        let result = try await separator.separate(pcm: pcm)
        let separated = try XCTUnwrap(result)

        let chunked = StemChunking.chunks(left: signal, right: signal,
                                          chunkFrames: chunkFrames, hop: hop)
        let window = StemChunking.window(chunkFrames)
        let expected = StemChunking.overlapAdd(chunkOutputs: chunked.map { $0.left },
                                               window: window, hop: hop,
                                               totalFrames: frames)
        for i in 0..<frames {
            XCTAssertEqual(separated.vocals.left[i], expected[i], accuracy: 1e-7,
                           "the pipeline and the pure kernel agree bit-for-bit")
        }
    }

    // MARK: - S3: the streaming overlap-add (memory profile)

    /// The streaming kernel is numerically identical to the accumulating one
    /// for the same chunks — the reconstruction-golden contract carries over.
    func testOverlapAddIntoMatchesAccumulatingKernel() {
        let chunkFrames = 1024
        let hop = 512
        let frames = 8000
        let signal = makeSignal(frames: frames, seed: 0x5150).left
        let chunked = StemChunking.chunks(left: signal, right: signal,
                                          chunkFrames: chunkFrames, hop: hop)
        let window = StemChunking.window(chunkFrames)

        let expected = StemChunking.overlapAdd(chunkOutputs: chunked.map { $0.left },
                                               window: window, hop: hop,
                                               totalFrames: frames)
        var streamed = [Float](repeating: 0, count: frames)
        for (k, chunk) in chunked.enumerated() {
            StemChunking.overlapAddInto(&streamed, chunk: chunk.left,
                                        window: window, offset: k * hop)
        }
        for i in 0..<frames {
            XCTAssertEqual(streamed[i], expected[i], accuracy: 1e-7,
                           "streaming and accumulating overlap-add agree at frame \(i)")
        }
        XCTAssertEqual(streamed.count, frames)
    }

    /// A ten-chunk separation through the passthrough model reconstructs the
    /// input exactly — the S3 rewrite (pre-allocated buffers, per-chunk
    /// accumulate) is the same result the accumulating pipeline produced, with
    /// peak extra memory capped at one chunk rather than the whole track.
    func testSeparatorStreamsTenChunksWithoutPerChunkAccumulator() async throws {
        let chunkFrames = 2048
        let hop = 1024
        let frames = 10 * hop + 321          // ten full chunks + a partial tail
        let (left, right) = makeSignal(frames: frames, seed: 0xC0FFEE)
        let pcm = PCMBuffer(sampleRate: 48_000, channels: [left, right])
        let separator = StemSeparator(model: PassthroughStemModel(),
                                      chunkFrames: chunkFrames, overlapFrames: 1024)
        let result = try await separator.separate(pcm: pcm)
        let separated = try XCTUnwrap(result)
        let interior = hop..<(left.count - hop)
        for kind in StemKind.allCases {
            let voice = separated.voice(kind)
            XCTAssertEqual(voice.frameCount, left.count)
            for i in interior {
                XCTAssertEqual(voice.left[i], left[i], accuracy: 1e-4,
                               "\(kind.rawValue) reconstructs at frame \(i)")
                XCTAssertEqual(voice.right[i], right[i], accuracy: 1e-4)
            }
        }
    }

    // MARK: - Honest absence and failure

    func testSeparatorReturnsNilWhenModelAbsent() async throws {
        let (left, right) = makeSignal(frames: 2048, seed: 1)
        let pcm = PCMBuffer(sampleRate: 48_000, channels: [left, right])
        let separator = StemSeparator(model: PassthroughStemModel(available: false))
        let result = try await separator.separate(pcm: pcm)
        XCTAssertNil(result, "no model → no separation, never an error (FR-SEM-6)")
    }

    func testSeparatorThrowsWhenModelReturnsWrongLength() async throws {
        let (left, right) = makeSignal(frames: 2048, seed: 2)
        let pcm = PCMBuffer(sampleRate: 48_000, channels: [left, right])
        let separator = StemSeparator(model: TruncatingStemModel())
        do {
            _ = try await separator.separate(pcm: pcm)
            XCTFail("a length-mismatched voice must be loud, not a silent result")
        } catch StemSeparatorError.chunkLengthMismatch {
            // expected
        }
    }

    func testSeparatorThrowsWhenModelStopsMidRun() async throws {
        let (left, right) = makeSignal(frames: 4096, seed: 3)
        let pcm = PCMBuffer(sampleRate: 48_000, channels: [left, right])
        // Available up front, then yields nil — an inconsistency that must be
        // loud (ADR-10), never a silently partial separation.
        let separator = StemSeparator(model: FlakyStemModel(availableUpfront: true))
        do {
            _ = try await separator.separate(pcm: pcm)
            XCTFail("a mid-run disappearance must be loud, never a partial result")
        } catch StemSeparatorError.modelUnavailableDuringSeparation {
            // expected
        }
    }

    func testSeparatorThrowsOnEmptyInput() async throws {
        let pcm = PCMBuffer(sampleRate: 48_000, channels: [[]])
        let separator = StemSeparator(model: PassthroughStemModel())
        do {
            _ = try await separator.separate(pcm: pcm)
            XCTFail("empty audio must be loud")
        } catch StemSeparatorError.emptyInput {
            // expected
        }
    }

    // MARK: - Misbehaving fakes

    private struct TruncatingStemModel: StemModelProviding {
        var version: Int = AnalysisVersions.stems
        func isAvailable() async -> Bool { true }
        func separate(chunk: StemChunk) async throws -> StemSeparation? {
            let short = StemChunk(sampleRate: chunk.sampleRate,
                                  left: Array(chunk.left.dropLast()),
                                  right: Array(chunk.right.dropLast()))
            return StemSeparation(sampleRate: chunk.sampleRate,
                                  vocals: short, drums: short, bass: short, other: short)
        }
    }

    private struct FlakyStemModel: StemModelProviding {
        var version: Int = AnalysisVersions.stems
        let availableUpfront: Bool
        func isAvailable() async -> Bool { availableUpfront }
        func separate(chunk: StemChunk) async throws -> StemSeparation? {
            nil // available up front, gone at the first chunk
        }
    }
}
