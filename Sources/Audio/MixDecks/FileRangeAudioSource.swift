#if !os(watchOS)
import AVFoundation
import Foundation
import ParsoAudioCore
import Synchronization

/// Scoped access to one local file for as long as a decode needs it. A required scope denial
/// throws before decoding. Every stored property is initialized before validation, so a thrown
/// initializer runs deinit and `release()`, balancing `activeCount` and stopping a granted scope
/// exactly once. Successful leases release explicitly or on deinit.
final class SourceAccessLease: @unchecked Sendable {
    private static let live = Atomic<Int>(0)
    static var activeCount: Int { live.load(ordering: .relaxed) }

    let url: URL
    private let lock = NSLock()
    private var scoped: Bool
    private var released = false

    /// `securityScoped`: require a security-scope grant for a bookmark URL.
    /// Every guard runs after full initialization, so deinit releases even when a guard throws.
    init(url: URL, securityScoped: Bool,
         startAccess: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }) throws {
        self.url = url
        Self.live.add(1, ordering: .relaxed)   // balanced by `release`, which deinit runs even if init throws
        scoped = securityScoped && startAccess(url)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MixTrackLoaderError.fileMissing
        }
        guard !securityScoped || scoped else {
            throw MixTrackLoaderError.accessDenied
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw MixTrackLoaderError.accessDenied
        }
    }

    func release() {
        let stop: Bool? = lock.withLock {
            guard !released else { return nil }
            released = true
            return scoped
        }
        guard let stop else { return }
        if stop { url.stopAccessingSecurityScopedResource() }
        Self.live.subtract(1, ordering: .relaxed)
    }

    deinit { release() }
}

/// A decoder-backed, seekable window onto a local audio file. Whether a file is windowed is decided
/// by the decoder (it must open, report a length and actually produce frames from the middle), not
/// by its extension or a FLAC seek table alone; anything else throws `unsupportedBoundedDecode`
/// and the caller falls back to sequential playback. Never decodes more than the range asked for.
final class FileRangeAudioSource: RangeAudioSource, DeckChunkSource, @unchecked Sendable {
    let sampleRate: Double
    let channelCount: Int
    let totalFrames: Int64
    var supportsRangeAccess: Bool { true }

    private let url: URL
    private let container: AudioContainer
    private let lock = NSLock()
    private let file: AVAudioFile?          // AVFoundation containers; FLAC reads through libFLAC seeks
    private let lease: SourceAccessLease?

    private static let rangeCalls = Atomic<Int>(0)
    /// Total `decodeRange` calls made in this process (a test hook for "was it windowed").
    static var rangeCallCount: Int { rangeCalls.load(ordering: .relaxed) }

    static func open(url: URL, container: AudioContainer, lease: SourceAccessLease? = nil) throws -> FileRangeAudioSource {
        let resolved = container == .auto ? MixTrackLoader.container(forExtension: url.pathExtension) : container
        switch resolved {
        case .auto, .oggVorbis, .opus: throw MixTrackLoaderError.unsupportedBoundedDecode(resolved)
        default: break
        }
        let probe: AVAudioFile
        do { probe = try AVAudioFile(forReading: url) } catch {
            throw MixTrackLoaderError.unsupportedBoundedDecode(resolved)
        }
        let rate = probe.processingFormat.sampleRate
        let channels = Int(probe.processingFormat.channelCount)
        guard rate > 0, channels > 0, probe.length > 0 else { throw MixTrackLoaderError.empty }
        let source = FileRangeAudioSource(url: url, container: resolved, rate: rate, channels: channels,
                                          total: probe.length, file: resolved == .flac ? nil : probe, lease: lease)
        // Capability is what the decoder delivers, not what the header claims.
        guard let sample = try? source.decodeRange(startFrame: probe.length / 2, frameCount: 1), !sample.isEmpty else {
            throw MixTrackLoaderError.unsupportedBoundedDecode(resolved)
        }
        return source
    }

    private init(url: URL, container: AudioContainer, rate: Double, channels: Int, total: Int64,
                 file: AVAudioFile?, lease: SourceAccessLease?) {
        self.url = url; self.container = container; sampleRate = rate; channelCount = channels
        totalFrames = total; self.file = file; self.lease = lease
    }

    func release() { lease?.release() }

    func decodeRange(startFrame: Int64, frameCount: Int) throws -> [Float] {
        Self.rangeCalls.add(1, ordering: .relaxed)
        let start = max(0, min(startFrame, totalFrames))
        let count = Int(max(0, min(Int64(frameCount), totalFrames - start)))
        guard count > 0 else { return [] }
        let channels = channelCount
        if let file {
            return try lock.withLock {
                if file.framePosition != start { file.framePosition = start }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                    frameCapacity: AVAudioFrameCount(count)) else {
                    throw MixTrackLoaderError.decode("could not allocate decode buffer")
                }
                do { try file.read(into: buffer, frameCount: AVAudioFrameCount(count)) }
                catch { throw MixTrackLoaderError.decode(error.localizedDescription) }
                guard let data = buffer.floatChannelData else { throw MixTrackLoaderError.decode("not float PCM") }
                let frames = Int(buffer.frameLength)
                var out = [Float](repeating: 0, count: frames * channels)
                for c in 0..<channels { for f in 0..<frames { out[f * channels + c] = data[c][f] } }
                return out
            }
        }
        do {
            let result = try AudioFileReader.decodeRange(url: url, container: container,
                                                         range: AudioFrameRange(startFrame: start, frameCount: count))
            let pcm = result.buffer
            let frames = min(result.decodedSourceFrames, pcm.frameCount)
            var out = [Float](repeating: 0, count: frames * channels)
            for c in 0..<min(channels, pcm.channelCount) {
                let channel = pcm.channel(c)
                for f in 0..<frames { out[f * channels + c] = channel[f] }
            }
            return out
        } catch RangeDecodeError.notSeekable {
            throw MixTrackLoaderError.unsupportedBoundedDecode(container)
        } catch let error as RangeDecodeError {
            throw MixTrackLoaderError.decode(String(describing: error))
        }
    }

    /// Planar chunk for a deck feeder.
    func read(startFrame: Int64, count: Int) throws -> [[Float]] {
        let interleaved = try decodeRange(startFrame: startFrame, frameCount: count)
        let frames = interleaved.count / channelCount
        return (0..<channelCount).map { c in (0..<frames).map { interleaved[$0 * channelCount + c] } }
    }
}
#endif
