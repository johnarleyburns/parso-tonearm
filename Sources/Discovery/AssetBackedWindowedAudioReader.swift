#if !os(watchOS)
import AVFoundation
import Foundation

/// `WindowedAudioReader`'s counterpart for an `AVURLAsset` backed by a
/// custom-scheme `AVAssetResourceLoaderDelegate` (`RemoteSparseAssetResolver`)
/// rather than a plain local file `URL`. `AVAudioFile(forReading:)` —
/// what `WindowedAudioReader` is built on — does not support custom
/// resource loaders; only `AVURLAsset`/`AVAssetReader` do, per
/// docs/plans/remote-sparse-indexing.md's "Proposed design".
///
/// Produces exactly the same output contract as `WindowedAudioReader`
/// (mono Float32 at `targetSampleRate`, zero-padded to exactly the
/// requested window length) so `SemanticPreprocess.logMel` and everything
/// downstream of a window read stays unchanged.
public struct AssetBackedWindowedAudioReader: Sendable {
    public let targetSampleRate: Double

    public init(targetSampleRate: Double = 48_000) {
        self.targetSampleRate = targetSampleRate
    }

    /// The real duration from the asset's own metadata track — not a
    /// whole-file decode.
    public func duration(asset: AVURLAsset) async throws -> Double {
        let time: CMTime
        do {
            time = try await asset.load(.duration)
        } catch {
            throw WindowedAudioReaderError(kind: .cannotOpenFile, detail: error.localizedDescription)
        }
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds > 0 else {
            throw WindowedAudioReaderError(kind: .unsupportedFormat, detail: "invalid duration")
        }
        return seconds
    }

    /// Reads `windowSeconds` of audio starting at `startSeconds`, resampled/
    /// downmixed to mono `targetSampleRate` Float32 by `AVAssetReader`
    /// itself (via `AVAssetReaderTrackOutput`'s `outputSettings` — no manual
    /// `AVAudioConverter` step needed, unlike `WindowedAudioReader`, since
    /// `AVAssetReader` already does the conversion as part of decoding).
    /// Zero-pads the tail when the window runs past end-of-file, matching
    /// `WindowedAudioReader.readWindow`'s contract exactly.
    public func readWindow(
        asset: AVURLAsset, startSeconds: Double, windowSeconds: Double
    ) async throws -> [Float] {
        let targetFrameCount = max(0, Int((windowSeconds * targetSampleRate).rounded()))
        guard targetFrameCount > 0 else { return [] }

        let track: AVAssetTrack?
        do {
            track = try await asset.loadTracks(withMediaType: .audio).first
        } catch {
            throw WindowedAudioReaderError(kind: .cannotOpenFile, detail: error.localizedDescription)
        }
        guard let track else {
            throw WindowedAudioReaderError(kind: .unsupportedFormat, detail: "no audio track")
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw WindowedAudioReaderError(kind: .cannotOpenFile, detail: error.localizedDescription)
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        guard reader.canAdd(output) else {
            throw WindowedAudioReaderError(kind: .unsupportedFormat, detail: "cannot add track output")
        }
        reader.add(output)

        let startTime = CMTime(seconds: max(0, startSeconds), preferredTimescale: 600)
        let durationTime = CMTime(seconds: windowSeconds, preferredTimescale: 600)
        reader.timeRange = CMTimeRange(start: startTime, duration: durationTime)

        guard reader.startReading() else {
            throw WindowedAudioReaderError(
                kind: .readFailed, detail: reader.error?.localizedDescription ?? "startReading failed")
        }

        var samples: [Float] = []
        samples.reserveCapacity(targetFrameCount)
        while samples.count < targetFrameCount, let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            guard length > 0 else { continue }
            var bytes = [UInt8](repeating: 0, count: length)
            let status = bytes.withUnsafeMutableBytes { ptr -> OSStatus in
                CMBlockBufferCopyDataBytes(
                    blockBuffer, atOffset: 0, dataLength: length, destination: ptr.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            bytes.withUnsafeBytes { raw in
                samples.append(contentsOf: raw.bindMemory(to: Float.self))
            }
        }

        let failed = reader.status == .failed
        let failureDetail = reader.error?.localizedDescription
        reader.cancelReading()
        if failed {
            throw WindowedAudioReaderError(kind: .readFailed, detail: failureDetail ?? "reader failed")
        }

        if samples.count < targetFrameCount {
            samples.append(contentsOf: [Float](repeating: 0, count: targetFrameCount - samples.count))
        } else if samples.count > targetFrameCount {
            samples.removeLast(samples.count - targetFrameCount)
        }
        return samples
    }
}
#endif
