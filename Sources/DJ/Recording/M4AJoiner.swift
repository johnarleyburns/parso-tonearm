import AVFoundation
import Foundation

/// Concatenates the §37.2 encoder's segment M4As into one playable M4A
/// (plan 5.11, §37.5 step 1).
///
/// The segments are individually playable AAC files precisely because a crash
/// must lose at most the in-flight one; the finished mix is the concatenation
/// (§34A.4). The joiner decodes each segment's PCM and re-encodes it into the
/// output AAC file — the same `AVAudioFile` PCM→AAC path the encoder itself
/// uses, so it is deterministic and host-testable. The output is the single
/// `mix_asset.localRelPath` file the §15.5 row and the review listen/export
/// (5.12) consume.
///
/// A segment that is absent, empty, or undecodable is **skipped**, not fatal:
/// that is exactly the crashed/interrupted segment the journal's recovery is
/// designed around (§37.3 — "loses at most the final segment"). If no segment
/// decodes at all, the joiner still produces the (empty) output file and
/// returns 0 frames — the caller decides how to present a zero-length mix.
public enum M4AJoiner {

    public enum JoinError: Error, LocalizedError, Equatable {
        case cannotCreateOutput(URL)
        case segmentFormatMismatch(URL)
        case outputWriteFailed(String)

        public var errorDescription: String? {
            switch self {
            case .cannotCreateOutput(let url):
                return "Could not create the joined recording at \(url.lastPathComponent)."
            case .segmentFormatMismatch(let url):
                return "Segment \(url.lastPathComponent) is in an unexpected format."
            case .outputWriteFailed(let detail):
                return "Joining the recording failed\(detail.isEmpty ? "" : ": \(detail)")."
            }
        }
    }

    /// The fixed read-block the joiner streams each segment with.
    private static let readFrames = 4096

    /// The first decodable segment's PCM format — `reconcile()` probes this so
    /// it can join a crashed recording without the engine's metadata.
    public struct SegmentFormat: Equatable, Sendable {
        public let sampleRate: Double
        public let channelCount: Int
    }

    /// Read the format of the first decodable segment (absent/undecodable
    /// segments are skipped, matching `join`'s tolerance). `nil` when nothing
    /// decodes.
    public static func probeFormat(of segmentURLs: [URL]) -> SegmentFormat? {
        let fm = FileManager.default
        for url in segmentURLs where fm.fileExists(atPath: url.path) {
            guard let file = try? AVAudioFile(forReading: url) else { continue }
            return SegmentFormat(sampleRate: file.processingFormat.sampleRate,
                                 channelCount: Int(file.processingFormat.channelCount))
        }
        return nil
    }

    /// Join `segmentURLs` into a single AAC M4A at `outputURL` and return the
    /// total frames written. The output settings mirror the encoder's
    /// (`bitRate` defaults to 256 kbps). Any pre-existing file at `outputURL`
    /// is replaced. Segments that cannot be decoded are skipped.
    @discardableResult
    public static func join(segmentURLs: [URL], to outputURL: URL,
                            sampleRate: Double,
                            channelCount: Int,
                            bitRate: Int = 256_000) throws -> Int {
        let fm = FileManager.default
        if fm.fileExists(atPath: outputURL.path) {
            try fm.removeItem(at: outputURL)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: bitRate,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let output: AVAudioFile
        do {
            output = try AVAudioFile(forWriting: outputURL, settings: settings,
                                     commonFormat: .pcmFormatFloat32,
                                     interleaved: false)
        } catch {
            throw JoinError.cannotCreateOutput(outputURL)
        }
        defer { output.close() }

        var totalFrames = 0
        for url in segmentURLs {
            guard fm.fileExists(atPath: url.path) else { continue }
            let reader: AVAudioFile
            do {
                reader = try AVAudioFile(forReading: url)
            } catch {
                // A crashed/interrupted segment is absent from the recovered
                // mix, never fatal (§37.3).
                continue
            }
            let format = reader.processingFormat
            guard format.sampleRate == sampleRate,
                  format.channelCount == AVAudioChannelCount(channelCount) else {
                throw JoinError.segmentFormatMismatch(url)
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(Self.readFrames)) else {
                continue
            }
            while true {
                do {
                    try reader.read(into: buffer)
                } catch {
                    break
                }
                if buffer.frameLength == 0 { break }
                do {
                    try output.write(from: buffer)
                } catch {
                    throw JoinError.outputWriteFailed(error.localizedDescription)
                }
                totalFrames += Int(buffer.frameLength)
            }
        }
        return totalFrames
    }
}
