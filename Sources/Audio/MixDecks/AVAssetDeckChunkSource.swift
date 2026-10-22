#if !os(watchOS)
import AVFoundation
import Foundation
import ParsoAudioStreaming

/// Seekable stereo PCM windows decoded by AVFoundation from an `AVURLAsset`.
/// When the asset uses `CachingResourceLoader`, every AVAssetReader seek causes
/// only its needed byte spans to be obtained through the sparse cache. This is
/// deliberately an async source: URL I/O and container parsing never run on
/// the render callback or the main actor.
final class AVAssetDeckChunkSource: AsyncDeckChunkSource, @unchecked Sendable {
    let asset: AVURLAsset
    let sampleRate: Double
    let channelCount: Int

    init(asset: AVURLAsset, sampleRate: Double = 44_100, channelCount: Int = 2) {
        self.asset = asset; self.sampleRate = sampleRate; self.channelCount = channelCount
    }

    func read(startFrame: Int64, count: Int) async throws -> [[Float]] {
        guard count > 0 else { return Array(repeating: [], count: channelCount) }
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw MixTrackLoaderError.empty }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { throw MixTrackLoaderError.decode("cannot configure asset reader") }
        reader.add(output)
        let timeScale = CMTimeScale(sampleRate.rounded())
        reader.timeRange = CMTimeRange(start: CMTime(value: startFrame, timescale: timeScale),
                                       duration: CMTime(value: Int64(count), timescale: timeScale))
        guard reader.startReading() else { throw MixTrackLoaderError.decode(reader.error?.localizedDescription ?? "cannot start asset reader") }
        defer { reader.cancelReading() }
        var channels = Array(repeating: [Float](), count: channelCount)
        channels.indices.forEach { channels[$0].reserveCapacity(count) }
        while channels[0].count < count, let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            var bytes = [UInt8](repeating: 0, count: length)
            let status = bytes.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            bytes.withUnsafeBytes { raw in
                let samples = raw.bindMemory(to: Float.self)
                let frames = samples.count / channelCount
                for channel in 0..<channelCount {
                    for frame in 0..<frames where channels[channel].count < count {
                        channels[channel].append(samples[frame * channelCount + channel])
                    }
                }
            }
        }
        if reader.status == .failed { throw MixTrackLoaderError.decode(reader.error?.localizedDescription ?? "asset reader failed") }
        return channels
    }
}

/// Keeps the shared sparse resource loader alive for a remote deck. AVAsset
/// asks it for byte ranges as the feeder seeks forward; no complete temporary
/// media file is made.
final class RemoteAVAssetDeckChunkSource: AsyncDeckChunkSource, @unchecked Sendable {
    private let loader: CachingResourceLoader
    private let source: AVAssetDeckChunkSource
    let totalFrames: Int64

    init(url: URL, headers: [String: String], sampleRate: Double = 44_100) async throws {
        loader = CachingResourceLoader(originalURL: url, store: AudioCache.shared,
                                       config: AudioCache.loaderConfig(headers: headers))
        let asset = AVURLAsset(url: CachingResourceLoader.cacheURL(for: url, scheme: AudioCache.scheme))
        asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "tonearm.mixdeck.range"))
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { throw MixTrackLoaderError.empty }
        totalFrames = Int64((seconds * sampleRate).rounded(.up))
        source = AVAssetDeckChunkSource(asset: asset, sampleRate: sampleRate)
    }

    func read(startFrame: Int64, count: Int) async throws -> [[Float]] {
        try await source.read(startFrame: startFrame, count: count)
    }

    func shutdown() { loader.shutdown() }
}
#endif
