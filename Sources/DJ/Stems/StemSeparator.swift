import Foundation
import Accelerate

// MARK: - Chunk / overlap-add kernel (§36.2, plan decision 1)

/// The pure chunk/overlap-add geometry and kernel the separator drives (§36.2):
/// the model runs on fixed-length stereo chunks; the outputs are windowed and
/// overlap-added to reconstruct full-length voices with no seam artifacts.
///
/// The window is a **periodic Hann** applied once to each chunk's model output.
/// At 50% overlap its first-power COLA (constant overlap-add) sum is exactly 1
/// (`w[i] + w[i + hop] == 1`), so a passthrough model reconstructs its input
/// exactly in the interior — the property the reconstruction-golden test locks.
public enum StemChunking {
    /// The working sample rate the separator and cache write at (§36.2). A
    /// model running at a different rate is resampled inside its own wrapper;
    /// the kernel always works at this rate.
    public static let workingSampleRate: Double = 48_000
    /// Fixed-length chunk in frames (~2.73 s at 48 kHz).
    public static let chunkFrames = 1 << 17
    /// Overlap in frames — 50% of the chunk.
    public static let overlapFrames = 1 << 16
    /// Frames advanced between chunks.
    public static var hopFrames: Int { chunkFrames - overlapFrames }

    /// Periodic Hann: `w[i] = 0.5(1 − cos(2πi/N))`. Exact first-power COLA at
    /// 50% overlap (verified: `w[i] + w[i + N/2] == 1` for all `i`), which is
    /// what makes the reconstruction exact — the standard "Hann at 50%" of the
    /// §36.2 overlap-add contract. (Accelerate's own `vDSP_HANN_NORM` is
    /// energy-normalized and does *not* hold this identity, so the window is
    /// generated here; the vector math below is still vDSP.)
    public static func window(_ count: Int) -> [Float] {
        guard count > 0 else { return [] }
        return (0..<count).map { i in
            Float(0.5 * (1 - cos(2 * Double.pi * Double(i) / Double(count))))
        }
    }

    /// Split stereo PCM into overlapping chunks, each exactly `chunkFrames`
    /// long; the final chunk is zero-padded so every chunk has equal length
    /// (the overlap-add kernel's contract).
    public static func chunks(left: [Float], right: [Float],
                              chunkFrames: Int, hop: Int) -> [(left: [Float], right: [Float])] {
        let frameCount = max(left.count, right.count)
        guard frameCount > 0, chunkFrames > 0, hop > 0 else { return [] }
        var result: [(left: [Float], right: [Float])] = []
        var offset = 0
        while offset < frameCount {
            result.append((left: slice(left, from: offset, to: offset + chunkFrames),
                           right: slice(right, from: offset, to: offset + chunkFrames)))
            offset += hop
        }
        return result
    }

    /// Window each chunk output with `window` and overlap-add into a single
    /// `totalFrames`-long channel. `window` must be the periodic Hann of the
    /// chunk length; all chunks must have that same length. vDSP does the
    /// multiply and accumulate; no per-sample Swift loop in the hot path.
    public static func overlapAdd(chunkOutputs: [[Float]], window: [Float],
                                  hop: Int, totalFrames: Int) -> [Float] {
        guard let chunkFrames = chunkOutputs.first?.count, chunkFrames > 0,
              window.count == chunkFrames, hop > 0 else {
            return [Float](repeating: 0, count: totalFrames)
        }
        var output = [Float](repeating: 0, count: totalFrames)
        var windowed = [Float](repeating: 0, count: chunkFrames)
        for (k, chunk) in chunkOutputs.enumerated() {
            let offset = k * hop
            guard offset < totalFrames else { break }
            guard chunk.count == chunkFrames else { continue }
            chunk.withUnsafeBufferPointer { cp in
                window.withUnsafeBufferPointer { wp in
                    windowed.withUnsafeMutableBufferPointer { wmp in
                        vDSP_vmul(cp.baseAddress!, 1, wp.baseAddress!, 1,
                                  wmp.baseAddress!, 1, vDSP_Length(chunkFrames))
                    }
                }
            }
            let count = min(chunkFrames, totalFrames - offset)
            output.withUnsafeMutableBufferPointer { op in
                windowed.withUnsafeBufferPointer { wp in
                    vDSP_vadd(op.baseAddress!.advanced(by: offset), 1,
                              wp.baseAddress!, 1,
                              op.baseAddress!.advanced(by: offset), 1,
                              vDSP_Length(count))
                }
            }
        }
        return output
    }

    /// Streaming sibling of `overlapAdd` (S3): window `chunk` and add it into
    /// `output` at `offset`, clamped so the write never runs past the buffer
    /// (the final chunk is zero-padded to `chunkFrames`, exactly as the
    /// accumulating kernel assumes). The separator uses this to overlap-add
    /// each chunk **as it comes back from the model**, so peak extra memory is
    /// one chunk instead of the whole track's eight voices. Numerically
    /// identical to `overlapAdd(chunkOutputs:…)` for the same chunks.
    public static func overlapAddInto(_ output: inout [Float],
                                      chunk: [Float], window: [Float],
                                      offset: Int) {
        let chunkFrames = chunk.count
        guard chunkFrames > 0, window.count == chunkFrames else { return }
        guard offset >= 0, offset < output.count else { return }
        let count = min(chunkFrames, output.count - offset)
        guard count > 0 else { return }
        // COW copy — one chunk of extra memory, windowed in place.
        var windowed = chunk
        windowed.withUnsafeMutableBufferPointer { wp in
            window.withUnsafeBufferPointer { win in
                vDSP_vmul(wp.baseAddress!, 1, win.baseAddress!, 1,
                          wp.baseAddress!, 1, vDSP_Length(chunkFrames))
            }
            output.withUnsafeMutableBufferPointer { op in
                vDSP_vadd(op.baseAddress!.advanced(by: offset), 1, wp.baseAddress!, 1,
                          op.baseAddress!.advanced(by: offset), 1, vDSP_Length(count))
            }
        }
    }

    private static func slice(_ buffer: [Float], from: Int, to: Int) -> [Float] {
        var out = [Float](repeating: 0, count: max(0, to - from))
        let start = max(0, from)
        let end = min(buffer.count, to)
        if start < end {
            out[0..<(end - start)] = buffer[start..<end]
        }
        return out
    }
}

// MARK: - Separator

public enum StemSeparatorError: Error, LocalizedError, Equatable {
    /// The decoded audio had no frames.
    case emptyInput
    /// The model returned a voice whose length differs from the chunk length.
    case chunkLengthMismatch
    /// The model reported available but stopped producing output mid-run —
    /// loud, never a silent partial result (ADR-10).
    case modelUnavailableDuringSeparation

    public var errorDescription: String? {
        switch self {
        case .emptyInput: return "The track has no audio to separate"
        case .chunkLengthMismatch:
            return "The stem model returned a voice of the wrong length"
        case .modelUnavailableDuringSeparation:
            return "The stem model became unavailable during separation"
        }
    }
}

/// Drives a `StemModelProviding` over a decoded track through the §36.2
/// chunk/overlap-add pipeline: slice → model → window → overlap-add → the four
/// full-length voices. Returns nil when the model is absent — the honest
/// FR-SEM-6 absence; the deck plays the full mix (FR-ENG-3, §36.5).
public struct StemSeparator: Sendable {
    public let model: any StemModelProviding
    public let chunkFrames: Int
    public let overlapFrames: Int

    public var hopFrames: Int { chunkFrames - overlapFrames }

    public init(model: any StemModelProviding,
                chunkFrames: Int = StemChunking.chunkFrames,
                overlapFrames: Int = StemChunking.overlapFrames) {
        self.model = model
        self.chunkFrames = chunkFrames
        self.overlapFrames = overlapFrames
    }

    /// Separate a decoded track into its four voices. The input is the canonical
    /// `PCMBuffer` (§19.2); mono sources are duplicated into L/R.
    public func separate(pcm: PCMBuffer) async throws -> StemSeparation? {
        guard await model.isAvailable() else { return nil }
        let frameCount = pcm.frameCount
        guard frameCount > 0 else { throw StemSeparatorError.emptyInput }

        let left = pcm.channels[0]
        let right = pcm.channelCount > 1 ? pcm.channels[1] : pcm.channels[0]
        let hop = hopFrames
        let window = StemChunking.window(chunkFrames)

        // Eight full-length output buffers, allocated **once**. Each chunk is
        // windowed and added into place as it returns from the model (S3), so
        // peak extra memory is one chunk, not ~2× the track × 8 channels —
        // the ~900 MB accumulation the old `[[Float]]` per-voice arrays held.
        var vocalsL = [Float](repeating: 0, count: frameCount)
        var vocalsR = [Float](repeating: 0, count: frameCount)
        var drumsL = [Float](repeating: 0, count: frameCount)
        var drumsR = [Float](repeating: 0, count: frameCount)
        var bassL = [Float](repeating: 0, count: frameCount)
        var bassR = [Float](repeating: 0, count: frameCount)
        var otherL = [Float](repeating: 0, count: frameCount)
        var otherR = [Float](repeating: 0, count: frameCount)

        var offset = 0
        while offset < frameCount {
            let count = min(chunkFrames, frameCount - offset)
            var chunkLeft = [Float](repeating: 0, count: chunkFrames)
            var chunkRight = [Float](repeating: 0, count: chunkFrames)
            chunkLeft.withUnsafeMutableBufferPointer { p in
                p.baseAddress!.update(from: left.baseAddress!.advanced(by: offset), count: count)
            }
            chunkRight.withUnsafeMutableBufferPointer { p in
                p.baseAddress!.update(from: right.baseAddress!.advanced(by: offset), count: count)
            }

            guard let result = try await model.separate(
                chunk: StemChunk(sampleRate: pcm.sampleRate,
                                 left: chunkLeft, right: chunkRight))
            else {
                throw StemSeparatorError.modelUnavailableDuringSeparation
            }
            guard result.vocals.frameCount == chunkFrames,
                  result.drums.frameCount == chunkFrames,
                  result.bass.frameCount == chunkFrames,
                  result.other.frameCount == chunkFrames else {
                throw StemSeparatorError.chunkLengthMismatch
            }

            // Window and overlap-add each voice into its pre-allocated buffer
            // immediately — the streaming kernel (S3), identical to the
            // accumulating `overlapAdd` the golden reconstruction test locks.
            StemChunking.overlapAddInto(&vocalsL, chunk: result.vocals.left, window: window, offset: offset)
            StemChunking.overlapAddInto(&vocalsR, chunk: result.vocals.right, window: window, offset: offset)
            StemChunking.overlapAddInto(&drumsL, chunk: result.drums.left, window: window, offset: offset)
            StemChunking.overlapAddInto(&drumsR, chunk: result.drums.right, window: window, offset: offset)
            StemChunking.overlapAddInto(&bassL, chunk: result.bass.left, window: window, offset: offset)
            StemChunking.overlapAddInto(&bassR, chunk: result.bass.right, window: window, offset: offset)
            StemChunking.overlapAddInto(&otherL, chunk: result.other.left, window: window, offset: offset)
            StemChunking.overlapAddInto(&otherR, chunk: result.other.right, window: window, offset: offset)

            offset += hop
        }

        return StemSeparation(sampleRate: pcm.sampleRate,
                              vocals: StemChunk(sampleRate: pcm.sampleRate,
                                                left: vocalsL, right: vocalsR),
                              drums: StemChunk(sampleRate: pcm.sampleRate,
                                               left: drumsL, right: drumsR),
                              bass: StemChunk(sampleRate: pcm.sampleRate,
                                              left: bassL, right: bassR),
                              other: StemChunk(sampleRate: pcm.sampleRate,
                                               left: otherL, right: otherR))
    }
}
