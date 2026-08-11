import Foundation
import AVFoundation
import Accelerate

public enum AudioDecodeError: LocalizedError {
    case cannotOpen(URL)
    case noTargetFormat
    case conversionFailed

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let url): return "Could not open audio file at \(url.lastPathComponent)"
        case .noTargetFormat: return "Could not create the 48 kHz analysis format"
        case .conversionFailed: return "Audio conversion failed"
        }
    }
}

/// The canonical analysis format (§19.2, §19.3): 48 kHz, `Float32`, a mono sum
/// (for most DSP) plus the original channels deinterleaved (for loudness
/// true-peak). Uniquely owned — a buffer is *transferred* between actors, never
/// shared, so `Sendable` is meaningful without copying the audio.
public final class PCMBuffer: @unchecked Sendable {
    public let sampleRate: Double
    public let channelCount: Int
    public let frameCount: Int
    /// Mono sum (arithmetic mean of channels), length == frameCount.
    public let mono: UnsafeBufferPointer<Float>
    /// Deinterleaved channels; `channels[c]` has length == frameCount.
    public let channels: [UnsafeBufferPointer<Float>]

    private let monoStorage: UnsafeMutableBufferPointer<Float>
    private let channelStorage: [UnsafeMutableBufferPointer<Float>]

    /// Takes ownership of the given deinterleaved channel buffers and derives the
    /// mono sum. The caller must not mutate the passed arrays afterwards.
    public init(sampleRate: Double, channels rawChannels: [[Float]]) {
        self.sampleRate = sampleRate
        self.channelCount = rawChannels.count
        self.frameCount = rawChannels.first?.count ?? 0

        var storage: [UnsafeMutableBufferPointer<Float>] = []
        storage.reserveCapacity(rawChannels.count)
        for channel in rawChannels {
            let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: channel.count)
            _ = buffer.initialize(from: channel)
            storage.append(buffer)
        }
        self.channelStorage = storage
        self.channels = storage.map { UnsafeBufferPointer($0) }

        let monoBuffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: frameCount)
        if frameCount > 0 {
            if channelCount == 1 {
                monoBuffer.baseAddress!.update(from: storage[0].baseAddress!, count: frameCount)
            } else {
                for i in 0..<frameCount {
                    var sum: Float = 0
                    for c in 0..<channelCount {
                        sum += storage[c][i]
                    }
                    monoBuffer[i] = sum / Float(channelCount)
                }
            }
        }
        self.monoStorage = monoBuffer
        self.mono = UnsafeBufferPointer(monoBuffer)
    }

    deinit {
        monoStorage.deallocate()
        for buffer in channelStorage { buffer.deallocate() }
    }
}

/// Decodes a file once into the canonical analysis `PCMBuffer` (§19.2) using
/// AVFoundation (`AVAudioFile` + `AVAudioConverter`), resampling to 48 kHz
/// `Float32`. A single decode pass feeds every downstream stage.
public enum AudioDecoder {
    public static let workingSampleRate: Double = 48_000

    public static func decode(_ url: URL) throws -> PCMBuffer {
        guard let file = try? AVAudioFile(forReading: url) else {
            throw AudioDecodeError.cannotOpen(url)
        }
        let sourceFormat = file.processingFormat
        let channelCount = min(max(Int(sourceFormat.channelCount), 1), 2)

        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: workingSampleRate,
                                         channels: AVAudioChannelCount(channelCount),
                                         interleaved: false),
              let converter = AVAudioConverter(from: sourceFormat, to: target) else {
            throw AudioDecodeError.noTargetFormat
        }

        var channels = [[Float]](repeating: [], count: channelCount)
        let outputBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 32_768)!

        // Reads from the file only when the converter needs more input. The
        // input buffer is reused; AVAudioFile.read advances its own position.
        final class ReadState: @unchecked Sendable {
            let file: AVAudioFile
            let buffer: AVAudioPCMBuffer
            var reachedEOF = false
            init(file: AVAudioFile, buffer: AVAudioPCMBuffer) {
                self.file = file
                self.buffer = buffer
            }
        }
        let readState = ReadState(file: file,
                                  buffer: AVAudioPCMBuffer(pcmFormat: sourceFormat,
                                                           frameCapacity: 16_384)!)
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            let state = readState
            if state.reachedEOF {
                outStatus.pointee = .endOfStream
                return nil
            }
            state.buffer.frameLength = 0
            try? state.file.read(into: state.buffer, frameCount: 16_384)
            if state.buffer.frameLength == 0 {
                state.reachedEOF = true
                outStatus.pointee = .endOfStream
                return nil
            }
            outStatus.pointee = .haveData
            return state.buffer
        }

        var conversionError: NSError?
        while true {
            outputBuffer.frameLength = 0
            let status = converter.convert(to: outputBuffer,
                                           error: &conversionError,
                                           withInputFrom: inputBlock)
            guard status != .error else { throw AudioDecodeError.conversionFailed }

            if outputBuffer.frameLength > 0, let data = outputBuffer.floatChannelData {
                let frames = Int(outputBuffer.frameLength)
                for c in 0..<channelCount {
                    channels[c].append(contentsOf: UnsafeBufferPointer(start: data[c],
                                                                       count: frames))
                }
            }

            if status == .endOfStream { break }
            // .inputRanDry/.haveData with no output: keep looping until EOF.
            if status == .haveData && outputBuffer.frameLength == 0 && readState.reachedEOF { break }
        }

        guard !channels.allSatisfy({ $0.isEmpty }) else {
            throw AudioDecodeError.cannotOpen(url)
        }
        return PCMBuffer(sampleRate: workingSampleRate, channels: channels)
    }
}
