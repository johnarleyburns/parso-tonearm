import Accelerate
import XCTest

@testable import TonearmDJ

/// Commit S2 — the Demucs STFT/ISTFT kernel (`DemucsSpectrogram`), verified
/// against saved torch tensors (plan `dj-stems-model.md` §5, §6.2).
///
/// The demucs analysis/synthesis pair is **not** invertible (`_spec` drops the
/// Nyquist bin and trims two frames each end; `_ispec` zero-fills them back),
/// so the only valid tests are golden-vector comparisons against torch — never
/// a round-trip identity assertion.
///
/// The golden fixture `Fixtures/demucs_stem_golden.bin` is exported from
/// `reference.pt` by `tools/demucs-coreml/export_fixtures.py`:
///
/// - **forward** — the torch `_spec`+`_magnitude` (`mag`, `[4, 2048, 40]`)
///   of the first 40960 samples of each channel of the reference `audio`;
/// - **inverse** — the torch `_ispec` of the first 16 frames of `spec[0, 0]`
///   (source drums, cac layout `[4, 2048, 16]`), full 343 980-frame output per
///   channel.
///
/// Comparison rule (stated for reproduction from `reference.pt`): every 97th
/// element with its flat index, `max|d| ≤ 1e-4`. The reference values were
/// computed by the export script from the exact tensors in `reference.pt`, so
/// the margin is the real kernel's, not a fixture's.
final class StemSpectrogramTests: XCTestCase {

    /// The fixture's subsample stride — must match the export script.
    private static let stride = 97

    private struct Golden {
        let forwardAudioLeft: [Float]
        let forwardAudioRight: [Float]
        let forwardMagIndex: [Int]
        let forwardMagValue: [Float]
        let inverseSpec: [Float]
        let inverseIndex: [Int]
        let inverseValue: [Float]
    }

    private func loadGolden() throws -> Golden {
        let url = DJFixtures.url("demucs_stem_golden", ext: "bin")
        let data = try Data(contentsOf: url)
        return try data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let magic = String(bytes: bytes[0..<4], encoding: .ascii)
            XCTAssertEqual(magic, "DSMG", "fixture magic")
            var offset = 4
            func readU32() throws -> Int {
                defer { offset += 4 }
                let v = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                return Int(v)
            }
            func readF32() throws -> Float {
                defer { offset += 4 }
                return raw.loadUnaligned(fromByteOffset: offset, as: Float.self)
            }
            let version = try readU32()
            let stride = try readU32()
            let forwardFrames = try readU32()
            let forwardMagFrames = try readU32()
            let forwardMagCount = try readU32()
            let inverseSpecFrames = try readU32()
            let inverseCount = try readU32()
            XCTAssertEqual(version, 1)
            XCTAssertEqual(stride, Self.stride)
            XCTAssertEqual(forwardFrames, 40_960)
            XCTAssertEqual(forwardMagFrames, 40)
            XCTAssertEqual(inverseSpecFrames, 16)

            func readFloats(_ count: Int) throws -> [Float] {
                let values = (0..<count).map { _ in try! readF32() }
                return values
            }
            func readIndexedFloats(_ count: Int) throws -> ([Int], [Float]) {
                var indices: [Int] = []
                var values: [Float] = []
                indices.reserveCapacity(count)
                values.reserveCapacity(count)
                for _ in 0..<count {
                    indices.append(try readU32())
                    values.append(try readF32())
                }
                return (indices, values)
            }

            let left = try readFloats(forwardFrames)
            let right = try readFloats(forwardFrames)
            let (magIdx, magVal) = try readIndexedFloats(forwardMagCount)
            let spec = try readFloats(4 * 2048 * inverseSpecFrames)
            let (invIdx, invVal) = try readIndexedFloats(inverseCount)

            XCTAssertEqual(offset, data.count, "fixture fully consumed")
            return Golden(forwardAudioLeft: left, forwardAudioRight: right,
                          forwardMagIndex: magIdx, forwardMagValue: magVal,
                          inverseSpec: spec, inverseIndex: invIdx, inverseValue: invVal)
        }
    }

    // MARK: - Golden forward

    /// Golden forward: `forward` of the reference audio's first 40 960 samples
    /// reproduces the torch `mag` on the subsampled slice, `max|d| ≤ 1e-4`.
    /// The output layout is `[L.re, L.im, R.re, R.im]` plane-major, each plane
    /// `bins × frames` row-major — the flat index is `plane·2048·40 +
    /// freq·40 + frame`.
    func testGoldenForwardMatchesTorchMag() throws {
        let golden = try loadGolden()
        let mag = DemucsSpectrogram.forward(left: golden.forwardAudioLeft,
                                            right: golden.forwardAudioRight)
        XCTAssertEqual(mag.count, 4 * DemucsSpectrogram.bins * 40,
                       "forward output is four planes of bins×40 frames")
        var maxDiff: Float = 0
        var worst: Int = 0
        for (idx, ref) in zip(golden.forwardMagIndex, golden.forwardMagValue) {
            let d = abs(mag[idx] - ref)
            if d > maxDiff {
                maxDiff = d
                worst = idx
            }
        }
        XCTAssertLessThanOrEqual(maxDiff, 1e-4,
                                 "forward drifted from the torch mag at flat index \(worst)")
    }

    // MARK: - Golden inverse

    /// Golden inverse: `inverse` of the reference spec's first 16 frames
    /// (source drums) reproduces the torch `ispec` on the subsampled slice.
    /// The reference is `[2, 343 980]` channel-major, so flat indices below
    /// `segmentFrames` are the left channel and the rest the right.
    func testGoldenInverseMatchesTorchIspec() throws {
        let golden = try loadGolden()
        let result = golden.inverseSpec.withUnsafeBufferPointer {
            DemucsSpectrogram.inverse(spec: $0)
        }
        XCTAssertEqual(result.left.count, DemucsSpectrogram.segmentFrames)
        XCTAssertEqual(result.right.count, DemucsSpectrogram.segmentFrames)
        var maxDiff: Float = 0
        var worst = 0
        for (idx, ref) in zip(golden.inverseIndex, golden.inverseValue) {
            let value = idx < DemucsSpectrogram.segmentFrames
                ? result.left[idx]
                : result.right[idx - DemucsSpectrogram.segmentFrames]
            let d = abs(value - ref)
            if d > maxDiff {
                maxDiff = d
                worst = idx
            }
        }
        XCTAssertLessThanOrEqual(maxDiff, 1e-4,
                                 "inverse drifted from the torch ispec at flat index \(worst)")
    }

    // MARK: - Window

    /// The window is the periodic Hann (`torch.hann_window(4096)`), not the
    /// energy-normalised `vDSP_HANN_NORM`: endpoints and symmetry per plan §6.2.
    func testWindowIsPeriodicHann() {
        let window = DemucsSpectrogram.window
        XCTAssertEqual(window.count, DemucsSpectrogram.nfft)
        XCTAssertEqual(window[0], 0, accuracy: 1e-7)
        XCTAssertEqual(window[DemucsSpectrogram.nfft / 2], 1, accuracy: 1e-7,
                       "periodic Hann peaks at the centre")
        for i in 1..<DemucsSpectrogram.nfft {
            XCTAssertEqual(window[i], window[DemucsSpectrogram.nfft - i], accuracy: 1e-7,
                           "periodic Hann is symmetric about the centre")
        }
    }

    // MARK: - Layout

    /// The output layout: plane `c·2 + ri` carries channel `c`'s real (0) or
    /// imaginary (1) part, and the frame axis is the minor stride (the
    /// `_magnitude` cac index `= channel*2 + reim`, plan §5.2). Left holds a
    /// real impulse, right is silence: L.re's DC bin lights, L.im's DC bin is
    /// zero (real signal), and both R planes are entirely silent.
    func testForwardLayoutCarriesChannelAndPart() {
        // 4096 samples → le = 4 frames.
        var signal = [Float](repeating: 0, count: 4096)
        signal[1000] = 1
        let silence = [Float](repeating: 0, count: 4096)
        let mag = DemucsSpectrogram.forward(left: signal, right: silence)
        let frames = 4
        let planeSize = DemucsSpectrogram.bins * frames
        XCTAssertEqual(mag.count, 4 * planeSize)
        // Plane 0 = L.re: the DC bin (freq 0, frame 0) carries the impulse.
        XCTAssertNotEqual(mag[0 * planeSize + 0 * frames + 0], 0, accuracy: 1e-6,
                          "L.re's DC bin carries the real impulse")
        // Plane 1 = L.im: a real signal's DC has zero imaginary part.
        XCTAssertEqual(mag[1 * planeSize + 0 * frames + 0], 0, accuracy: 1e-6,
                       "L.im's DC bin is zero for a real signal")
        // Planes 2/3 = R.re/R.im: the silent channel stays silent everywhere.
        for p in [2, 3] {
            XCTAssertEqual(mag[p * planeSize ..< (p + 1) * planeSize]
                .reduce(0) { Swift.max($0, abs($1)) }, 0, accuracy: 1e-6,
                "the silent right channel leaves planes \(p) empty")
        }
    }

    /// `frames` describes the model geometry: a full segment produces 336
    /// frames at 1024 hop, and the channel/part constants are what the docs
    /// claim.
    func testGeometryConstants() {
        XCTAssertEqual(DemucsSpectrogram.sampleRate, 44_100)
        XCTAssertEqual(DemucsSpectrogram.segmentFrames, 343_980)
        XCTAssertEqual(DemucsSpectrogram.nfft, 4096)
        XCTAssertEqual(DemucsSpectrogram.hop, 1024)
        XCTAssertEqual(DemucsSpectrogram.bins, 2048)
        XCTAssertEqual(DemucsSpectrogram.frames,
                       (DemucsSpectrogram.segmentFrames + DemucsSpectrogram.hop - 1)
                       / DemucsSpectrogram.hop)
    }
}
