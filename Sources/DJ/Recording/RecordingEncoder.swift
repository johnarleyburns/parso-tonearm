import AVFoundation
import Foundation

/// The §37.2 encoder: an actor that drains the `RecordTap` ring off the RT
/// thread and writes the master output as AAC 256 kbps into a **segmented**
/// M4A with periodic flush (plan 5.10, FR-ENG-7, §37.2–37.3).
///
/// The tap only *copies*; this actor owns the encode + disk. Because it runs on
/// an actor (off the render callback) it can block on I/O freely — the ring
/// between it and the render thread is what decouples the two, so encoder
/// hiccups never stall audio (§37.2). The file is written incrementally in
/// **segment files** (`segment-NNN.m4a`): `flushSegment()` closes the current
/// file (a complete, playable M4A) and opens the next, so an interruption or
/// crash costs at most the current in-flight segment (NFR-REL-2, §34A.4).
///
/// Encoding is AVFoundation's native AAC path: the `AVAudioFile` is created
/// with AAC settings and an explicit PCM client format, and PCM buffers written
/// in `file.processingFormat` are encoded on write (the plan's
/// "AVAudioFile/AVAudioConverter configured for AAC"). Output is AAC 256 kbps
/// in `.m4a` (decision 22, §37.6) — the UI names the format it produces and
/// never promises MP3 (FR-REC-7).
public actor RecordingEncoder {

    public struct Configuration: Sendable {
        public var sampleRate: Double
        public var channelCount: Int
        public var bitRate: Int = 256_000
        /// Frames per segment — when the current segment reaches this budget,
        /// `drain` flushes it and opens the next (periodic flush, §37.3).
        public var segmentFrames: Int
        public var outputDirectory: URL

        public init(sampleRate: Double, channelCount: Int,
                    bitRate: Int = 256_000,
                    segmentFrames: Int,
                    outputDirectory: URL) {
            self.sampleRate = sampleRate
            self.channelCount = channelCount
            self.bitRate = bitRate
            self.segmentFrames = segmentFrames
            self.outputDirectory = outputDirectory
        }
    }

    /// The finished recording: where it is and how much is in it. The `mix` /
    /// `mix_asset` rows are 5.11's job (journal + finalize); this value is what
    /// that commit records.
    public struct RecordingOutput: Sendable, Equatable {
        public let outputDirectory: URL
        public let segmentURLs: [URL]
        public let totalFrames: Int
        public let sampleRate: Double
        public let format: String

        public init(outputDirectory: URL, segmentURLs: [URL],
                    totalFrames: Int, sampleRate: Double, format: String) {
            self.outputDirectory = outputDirectory
            self.segmentURLs = segmentURLs
            self.totalFrames = totalFrames
            self.sampleRate = sampleRate
            self.format = format
        }

        public var duration: TimeInterval { Double(totalFrames) / sampleRate }
    }

    public enum RecordingError: Error, LocalizedError, Equatable {
        case tapNotRecording
        case notStarted
        case cannotCreateOutputDirectory(URL)
        case cannotOpenFile(URL)
        case cannotCreateInputFormat
        case cannotCreateProcessingFormat
        case writeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .tapNotRecording:
                return "The record tap is not capturing."
            case .notStarted:
                return "The recording encoder has not been started."
            case .cannotCreateOutputDirectory(let url):
                return "Could not create the recording directory at \(url.path)."
            case .cannotOpenFile(let url):
                return "Could not open the recording file at \(url.lastPathComponent)."
            case .cannotCreateInputFormat:
                return "Could not create the recording input format."
            case .cannotCreateProcessingFormat:
                return "Could not create the recording processing format."
            case .writeFailed(let detail):
                return "Recording write failed\(detail.isEmpty ? "" : ": \(detail)")."
            }
        }
    }

    /// The format string the `mix.format` row records (FR-REC-7 honesty).
    public static let formatName = "m4a-aac-256"

    private let tap: RecordTap
    private let configuration: Configuration
    /// Interleaved float32 at the graph's rate/channels — the tap's layout.
    private let inputFormat: AVAudioFormat

    private var currentFile: AVAudioFile?
    private var processingFormat: AVAudioFormat?
    private var segmentIndex = 0
    private var segmentURLs: [URL] = []
    private var framesInSegment = 0
    private var totalFrames = 0
    private var isStarted = false

    /// Interleaved scratch — read from the tap, de-interleaved into the
    /// file's processing-format buffer. Fixed size, allocated once (§12.3
    /// discipline off-RT). Boxed so the actor's `deinit` can reach it.
    private let scratchFrames = 8192
    private var scratch = InterleavedScratch()
    private var pcmBuffer: AVAudioPCMBuffer?

    public init(tap: RecordTap, configuration: Configuration) throws {
        self.tap = tap
        self.configuration = configuration
        guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                              sampleRate: configuration.sampleRate,
                                              channels: AVAudioChannelCount(configuration.channelCount),
                                              interleaved: true) else {
            throw RecordingError.cannotCreateInputFormat
        }
        self.inputFormat = inputFormat
    }

    /// Open the output directory and segment 0. Call once before draining.
    public func start() throws {
        guard !isStarted else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: configuration.outputDirectory,
                                   withIntermediateDirectories: true)
        } catch {
            throw RecordingError.cannotCreateOutputDirectory(configuration.outputDirectory)
        }
        scratch.allocate(count: scratchFrames * configuration.channelCount)
        try openSegment(0)
        isStarted = true
    }

    /// Drain up to `maxFrames` frames from the tap, encode them to AAC and
    /// write them to the current segment; flush a completed segment. Returns
    /// the number of frames written (0 when the ring is empty or idle).
    @discardableResult
    public func drain(maxFrames: Int) throws -> Int {
        guard isStarted else { throw RecordingError.notStarted }
        guard let scratchPointer = scratch.pointer else { throw RecordingError.notStarted }
        let n = tap.read(maxFrames: maxFrames, into: scratchPointer)
        guard n > 0 else { return 0 }
        guard let file = currentFile,
              let pcmBuffer,
              let data = pcmBuffer.floatChannelData else {
            throw RecordingError.cannotOpenFile(segmentURLs.last ?? configuration.outputDirectory)
        }
        // De-interleave the tap's interleaved frames into the processing
        // format (float32, deinterleaved per channel) the file was created
        // with — AVAudioFile encodes PCM → AAC on write.
        let channels = configuration.channelCount
        for c in 0..<channels {
            let dst = data[c]
            for i in 0..<n {
                dst[i] = scratchPointer[i * channels + c]
            }
        }
        pcmBuffer.frameLength = AVAudioFrameCount(n)
        do {
            try file.write(from: pcmBuffer)
        } catch {
            throw RecordingError.writeFailed(error.localizedDescription)
        }
        totalFrames += n
        framesInSegment += n
        if framesInSegment >= configuration.segmentFrames {
            try flushSegment()
        }
        return n
    }

    /// Close the current segment (a complete, playable M4A) and open the next.
    public func flushSegment() throws {
        guard isStarted else { throw RecordingError.notStarted }
        currentFile?.close()
        currentFile = nil
        framesInSegment = 0
        segmentIndex += 1
        try openSegment(segmentIndex)
    }

    /// Drain the ring to empty, close the final segment and return the
    /// finished recording.
    public func finalize() throws -> RecordingOutput {
        guard isStarted else { throw RecordingError.notStarted }
        while tap.availableFrames > 0 {
            _ = try drain(maxFrames: scratchFrames)
        }
        currentFile?.close()
        currentFile = nil
        isStarted = false
        return RecordingOutput(outputDirectory: configuration.outputDirectory,
                               segmentURLs: segmentURLs,
                               totalFrames: totalFrames,
                               sampleRate: configuration.sampleRate,
                               format: Self.formatName)
    }

    // MARK: - Segment plumbing

    private func openSegment(_ index: Int) throws {
        let url = configuration.outputDirectory
            .appendingPathComponent(String(format: "segment-%03d.m4a", index))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: configuration.sampleRate,
            AVNumberOfChannelsKey: configuration.channelCount,
            AVEncoderBitRateKey: configuration.bitRate,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let file: AVAudioFile
        do {
            // The commonFormat makes the processing format float32 PCM; the
            // settings make the on-disk format AAC 256 kbps. Writes in the
            // processing format are encoded to AAC (plan: "AVAudioFile/
            // AVAudioConverter configured for AAC").
            file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        } catch {
            throw RecordingError.cannotOpenFile(url)
        }
        let processing = file.processingFormat
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: processing,
                                               frameCapacity: AVAudioFrameCount(scratchFrames)) else {
            throw RecordingError.cannotCreateProcessingFormat
        }
        currentFile = file
        processingFormat = processing
        self.pcmBuffer = pcmBuffer
        segmentURLs.append(url)
    }
}

/// The encoder's interleaved drain scratch, boxed so the actor's nonisolated
/// `deinit` can reclaim it (Swift 6: an actor cannot reach a non-Sendable raw
/// pointer in deinit). Allocated once at `start`, sized to
/// `scratchFrames × channelCount`.
private final class InterleavedScratch: @unchecked Sendable {
    private var storage: UnsafeMutablePointer<Float>?

    var pointer: UnsafeMutablePointer<Float>? { storage }

    func allocate(count: Int) {
        guard storage == nil else { return }
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: count)
        buffer.initialize(repeating: 0, count: count)
        storage = buffer
    }

    deinit {
        storage?.deinitialize(count: 0)
        storage?.deallocate()
    }
}
