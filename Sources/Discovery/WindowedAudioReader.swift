#if !os(watchOS)
import AVFoundation
import Foundation

/// Bounded-memory windowed PCM reader (IMPLEMENT_CLAP_PLAN.md §6): decodes
/// and resamples exactly one requested window's worth of audio into mono
/// Float32 samples at a time — never the whole file. This replaces the
/// forbidden "decode the entire file, build all windows" shape
/// (`AnalyzePipeline.embed`, plan §2) with a reader that only ever holds one
/// window's frames (source + resampled) in memory at once.
///
/// Implementation note: a single window here is already small and bounded
/// (10 s of source audio, ~a few MB at most as Float32 before/after
/// resampling for any real-world sample rate), so this reads that bounded
/// window in one `AVAudioFile.read(into:frameCount:)` call rather than
/// sub-chunking within the window — the bound that matters (never touching
/// the rest of a multi-hour file) is preserved either way.
public struct WindowedAudioReaderError: Error, LocalizedError, Equatable {
    public enum Kind: Equatable, Sendable {
        case cannotOpenFile
        case unsupportedFormat
        case converterCreationFailed
        case readFailed
    }
    public let kind: Kind
    public let detail: String

    public init(kind: Kind, detail: String) {
        self.kind = kind
        self.detail = detail
    }

    public var errorDescription: String? {
        switch kind {
        case .cannotOpenFile: return "Could not open audio file: \(detail)"
        case .unsupportedFormat: return "Unsupported audio format: \(detail)"
        case .converterCreationFailed: return "Could not create an audio resampler: \(detail)"
        case .readFailed: return "Could not read audio: \(detail)"
        }
    }
}

public struct WindowedAudioReader: Sendable {
    public let targetSampleRate: Double

    public init(targetSampleRate: Double = 48_000) {
        self.targetSampleRate = targetSampleRate
    }

    /// The real duration of the file, read from its header/track metadata —
    /// not a whole-file decode (plan §6: "Determine duration from actual
    /// readable media when metadata is absent").
    public func duration(url: URL) throws -> Double {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw WindowedAudioReaderError(kind: .cannotOpenFile, detail: error.localizedDescription)
        }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else {
            throw WindowedAudioReaderError(kind: .unsupportedFormat, detail: "zero sample rate")
        }
        return Double(file.length) / sampleRate
    }

    /// Reads `windowSeconds` of audio starting at `startSeconds` from `url`,
    /// resampled/downmixed to mono `targetSampleRate` Float32. Zero-pads the
    /// tail when the requested window runs past end-of-file (plan §6:
    /// "for tracks <=10 seconds, one zero-padded window" — generalized to
    /// any window whose tail exceeds the file).
    public func readWindow(url: URL, startSeconds: Double, windowSeconds: Double) throws -> [Float] {
        let targetFrameCount = max(0, Int((windowSeconds * targetSampleRate).rounded()))
        guard targetFrameCount > 0 else { return [] }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw WindowedAudioReaderError(kind: .cannotOpenFile, detail: error.localizedDescription)
        }
        let sourceFormat = file.processingFormat
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else {
            throw WindowedAudioReaderError(kind: .unsupportedFormat, detail: "invalid source format")
        }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: 1,
            interleaved: false)
        else {
            throw WindowedAudioReaderError(kind: .unsupportedFormat, detail: "cannot build target format")
        }

        let sourceStartFrame = AVAudioFramePosition(
            max(0, (startSeconds * sourceFormat.sampleRate).rounded()))
        let sourceWindowFrames = AVAudioFrameCount(
            max(0, (windowSeconds * sourceFormat.sampleRate).rounded()))

        var output = [Float](repeating: 0, count: targetFrameCount)
        guard sourceStartFrame < file.length, sourceWindowFrames > 0 else {
            // Entirely past end-of-file (or a degenerate zero-length file):
            // an all-silence, zero-padded window.
            return output
        }

        file.framePosition = sourceStartFrame
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: sourceWindowFrames)
        else {
            throw WindowedAudioReaderError(kind: .readFailed, detail: "could not allocate source buffer")
        }
        do {
            try file.read(into: inBuffer, frameCount: sourceWindowFrames)
        } catch {
            throw WindowedAudioReaderError(kind: .readFailed, detail: error.localizedDescription)
        }
        guard inBuffer.frameLength > 0 else { return output }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw WindowedAudioReaderError(kind: .converterCreationFailed, detail: "incompatible formats")
        }
        let outFrameCapacity = AVAudioFrameCount(
            (Double(inBuffer.frameLength) * targetSampleRate / sourceFormat.sampleRate).rounded(.up) + 8)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrameCapacity)
        else {
            throw WindowedAudioReaderError(kind: .readFailed, detail: "could not allocate output buffer")
        }
        // The block-based API is required for sample-rate conversion; the
        // one-shot `convert(to:from:)` returns OSStatus -50 whenever the in
        // and out formats differ in rate.
        var conversionError: NSError?
        var suppliedInput = false
        let status = converter.convert(to: outBuffer, error: &conversionError) {
            _, outStatus in
            if suppliedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return inBuffer
        }
        if status == .error {
            throw WindowedAudioReaderError(
                kind: .readFailed,
                detail: conversionError?.localizedDescription ?? "conversion failed")
        }

        guard let channelData = outBuffer.floatChannelData else { return output }
        let converted = Int(outBuffer.frameLength)
        let copyCount = min(converted, targetFrameCount)
        if copyCount > 0 {
            output.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.update(from: channelData[0], count: copyCount)
            }
        }
        return output
    }
}
#endif
