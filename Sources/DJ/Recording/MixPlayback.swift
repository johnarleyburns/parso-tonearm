import AVFoundation
import Foundation

// MARK: - The review listen (FR-REC-6, plan 5.12)

/// The finished mix's player — the review listen's transport (mockup
/// `ipad/09`, §41.11). Playable **in place, the moment it finalises**: no
/// export, no re-encode, no hunting in Mixes. The real implementation wraps
/// `AVAudioPlayer`; tests inject a fake so the finish model's forwarding is
/// exercised deterministically (§47.2).
@MainActor
public protocol MixPlayback: AnyObject {
    var isPlaying: Bool { get }
    /// The playback position in seconds — the review-listen playhead.
    var currentTime: TimeInterval { get }
    /// The loaded file's duration (the mix's real audio, not the DB header).
    var duration: TimeInterval { get }
    /// Prepare a mix file for playback. `AVAudioPlayer` decodes the M4A/AAC
    /// natively — the file plays on any recipient's device (FR-REC-7).
    func load(url: URL) throws
    func play()
    func pause()
    func seek(to time: TimeInterval)
}

/// `AVAudioPlayer`-backed review-listen transport. `currentTime` is settable
/// while playing, which is exactly the review-listen seek-to-marker need.
@MainActor
public final class AVAudioPlayerMixPlayer: MixPlayback {
    private var player: AVAudioPlayer?

    public init() {}

    public var isPlaying: Bool { player?.isPlaying ?? false }
    public var currentTime: TimeInterval { player?.currentTime ?? 0 }
    public var duration: TimeInterval { player?.duration ?? 0 }

    public func load(url: URL) throws {
        let player = try AVAudioPlayer(contentsOf: url)
        player.prepareToPlay()
        self.player = player
    }

    public func play() { player?.play() }
    public func pause() { player?.pause() }

    public func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = max(0, min(time, player.duration))
    }
}

// MARK: - Review-listen waveform

/// The review listen's seekable strip (FR-REC-6): a coarse peak overview of the
/// mix's own audio — not the analysed pyramid (a fresh mix has none). The
/// transition markers are overlaid from the §37.4 timeline; tapping one seeks.
public struct MixWaveformModel: Equatable, Sendable {
    public static let defaultBinCount = 240

    /// Per-bin peak magnitude, 0...1, `binCount` wide.
    public let peaks: [Float]
    /// The mix's duration in seconds (from the decoded audio).
    public let duration: TimeInterval
    /// The decoded file's sample rate — the finish screen's "48 kHz" pill
    /// (mockup `ipad/09`).
    public let sampleRate: Double
    /// The decoded file's channel count — the "stereo" pill.
    public let channelCount: Int

    public init(peaks: [Float], duration: TimeInterval,
                sampleRate: Double, channelCount: Int) {
        self.peaks = peaks
        self.duration = duration
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    public var binCount: Int { peaks.count }

    /// The peak at a playhead fraction 0...1 (the review-listen waveform's
    /// cursor height). Clamped; empty models read 0.
    public func level(atFraction fraction: Double) -> Float {
        guard !peaks.isEmpty else { return 0 }
        let index = Int(fraction * Double(peaks.count))
        return peaks[max(0, min(peaks.count - 1, index))]
    }
}

/// The pure bin-assignment kernel behind the review-listen waveform (plan 5.12):
/// assign each frame's |sample| to its bin and keep the bin's running maximum.
/// Streaming-safe — the accumulator owns the bin-edge math, so a builder can
/// feed arbitrarily long audio chunk-by-chunk without holding it in memory
/// (a 20-minute mix is ~57M frames; it must not be buffered for an overview).
public struct MixWaveformAccumulator {
    public let bins: Int
    public let totalFrames: Int64
    public private(set) var peaks: [Float]

    private var binIndex: Int
    private var nextEdgeFrames: Double
    private var framesPerBin: Double
    private var consumed: Int64
    private var currentMax: Float

    public init(bins: Int, totalFrames: Int64) {
        self.bins = bins
        self.totalFrames = max(1, totalFrames)
        self.peaks = [Float](repeating: 0, count: bins)
        self.binIndex = 0
        self.framesPerBin = Double(self.totalFrames) / Double(bins)
        self.nextEdgeFrames = self.framesPerBin
        self.consumed = 0
        self.currentMax = 0
    }

    /// Consume one (already mono-mixed) frame value.
    public mutating func consume(frameValue: Float) {
        let magnitude = abs(frameValue)
        if magnitude > currentMax { currentMax = magnitude }
        consumed += 1
        if Double(consumed) >= nextEdgeFrames, binIndex < bins {
            peaks[binIndex] = currentMax
            binIndex += 1
            currentMax = 0
            nextEdgeFrames += framesPerBin
        }
    }

    /// The final bin maxima — the finished overview (a partially-consumed final
    /// bin is flushed by the last `consume`).
    public var result: [Float] { peaks }
}

/// Loads a finished mix's audio into a review-listen waveform. `AVAudioFile`
/// decodes the M4A/AAC; the streaming accumulator keeps the memory footprint
/// O(bins) regardless of the mix's length. A `MixWaveformLoading` seam so the
/// finish model's state is testable with a canned model (§47.2).
public protocol MixWaveformLoading: Sendable {
    func loadWaveform(url: URL) async throws -> MixWaveformModel
}

public struct MixWaveformBuilder: MixWaveformLoading, Sendable {
    public init() {}

    public func loadWaveform(url: URL) async throws -> MixWaveformModel {
        try MixWaveformBuilder.build(from: url)
    }

    public static func build(from url: URL,
                             bins: Int = MixWaveformModel.defaultBinCount) throws -> MixWaveformModel {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let channelCount = max(1, Int(format.channelCount))
        var accumulator = MixWaveformAccumulator(bins: bins, totalFrames: file.length)

        let chunkFrames: AVAudioFrameCount = 16_384
        var remaining = file.length
        while remaining > 0 {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: chunkFrames) else { break }
            let count = AVAudioFrameCount(min(Int64(chunkFrames), remaining))
            try file.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0,
                  let channels = buffer.floatChannelData else { break }
            // Mono mix of the channels — a recording is stereo; the overview
            // only needs levels.
            for i in 0..<Int(buffer.frameLength) {
                var sum = 0.0
                for channel in 0..<channelCount {
                    sum += Double(channels[channel][i])
                }
                accumulator.consume(frameValue: Float(sum / Double(channelCount)))
            }
            remaining -= Int64(buffer.frameLength)
        }
        return MixWaveformModel(peaks: accumulator.result,
                                duration: Double(file.length) / format.sampleRate,
                                sampleRate: format.sampleRate,
                                channelCount: channelCount)
    }
}
