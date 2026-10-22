#if !os(watchOS)
import Foundation
import ParsoAudioCore
import ParsoAudioStreaming
import ParsoAudioAnalysis

/// Where a mix track's whole audio comes from. The mix decks play decoded PCM
/// (a blend needs any point of the track at once, sample-exact), so a stream
/// is downloaded completely before it can join a mix.
enum MixTrackSource: Sendable, Equatable {
    case file(URL, container: AudioContainer, securityScoped: Bool)
    /// `cacheKey`: the stream cache entry the downloaded file is kept under, so the
    /// track isn't downloaded again (nil: not cacheable).
    case remote(URL, headers: [String: String], container: AudioContainer, cacheKey: String?)
}

/// A decoded mix track at the mix decks' sample rate, and its blend analysis.
struct MixTrackAudio: Sendable {
    let trackID: Int64
    let audio: PCMBuffer
    let analysis: BlendTrackAnalysis
}

/// The bounded MixDeck input. It deliberately contains a seekable decoder,
/// not decoded samples; resident memory is fixed by the two deck buffers.
struct StreamingMixTrack: @unchecked Sendable {
    let trackID: Int64
    let source: any AsyncDeckChunkSource
    let totalFrames: Int64
    let sampleRate: Double
}

enum MixTrackLoaderError: Error, LocalizedError, Equatable {
    case download(Int)
    case decode(String)
    case empty
    /// Scoped access to the file was refused: nothing is decoded.
    case accessDenied
    /// The file was moved or deleted: nothing is decoded; reselect or relink it.
    case fileMissing
    /// The decoder cannot position within this container, so a windowed decode is impossible.
    /// There is no whole-file fallback; the edge plays sequentially.
    case unsupportedBoundedDecode(AudioContainer)
    /// Longer than the resident-PCM ceiling the mix decks accept (seconds).
    case tooLong(Int)

    var errorDescription: String? {
        switch self {
        case .download(let status): return "Download failed (HTTP \(status))"
        case .decode(let reason): return "Could not decode the track: \(reason)"
        case .empty: return "The track has no audio"
        case .accessDenied: return "Access to the file was denied; the file was not opened. Retry or reselect it"
        case .fileMissing: return "The file was moved or deleted; it was not opened. Reselect or relink it"
        case .unsupportedBoundedDecode: return "This format cannot be blended; it plays without a blend"
        case .tooLong: return "The track is too long to blend; it plays without a blend"
        }
    }
}

/// Downloads (when remote), decodes and analyses one mix track off the main
/// actor. Progress goes to `progress` so the prep state is always real.
enum MixTrackLoader {
    enum Stage: Sendable, Equatable {
        case downloading(Double)
        case analyzing
    }

    /// Opens exactly the decoder needed by the bounded deck. Remote assets
    /// retain their sparse loader and begin from the media container header;
    /// they are never copied through `download` or `PCMBuffer`.
    static func openStreaming(trackID: Int64, source: MixTrackSource) async throws -> StreamingMixTrack {
        switch source {
        case .file(let url, let container, let securityScoped):
            let lease = try SourceAccessLease(url: url, securityScoped: securityScoped)
            do {
                let opened = try FileRangeAudioSource.open(url: url, container: container, lease: lease)
                return StreamingMixTrack(trackID: trackID, source: opened,
                                         totalFrames: opened.totalFrames, sampleRate: opened.sampleRate)
            } catch {
                lease.release()
                throw error
            }
        case .remote(let url, let headers, _, _):
            let opened = try await RemoteAVAssetDeckChunkSource(url: url, headers: headers)
            return StreamingMixTrack(trackID: trackID, source: opened,
                                     totalFrames: opened.totalFrames, sampleRate: 44_100)
        }
    }

    static func load(trackID: Int64, source: MixTrackSource, approximateBPM: Double?, sampleRate: Double,
                     progress: @escaping @Sendable (Stage) -> Void) async throws -> MixTrackAudio {
        let decoded: PCMBuffer
        switch source {
        case .file(let url, let container, let scoped):
            let lease = try SourceAccessLease(url: url, securityScoped: scoped)
            defer { lease.release() }
            decoded = try decode(url, container: container)
        case .remote(let url, let headers, let container, let cacheKey):
            let file = try await download(url, headers: headers, container: container, progress: progress)
            if let cacheKey, let cached = await adoptIntoCache(file, key: cacheKey) {
                decoded = try decode(cached, container: container)
            } else {
                defer { try? FileManager.default.removeItem(at: file) }
                decoded = try decode(file, container: container)
            }
        }
        try Task.checkCancellation()
        progress(.analyzing)
        var audio = decoded
        if abs(audio.format.sampleRate - sampleRate) >= 0.5 {
            audio = try SampleRateConverter(from: audio.format.sampleRate, to: sampleRate,
                                            channels: audio.channelCount).convert(audio)
        }
        guard audio.frameCount > Int(sampleRate) else { throw MixTrackLoaderError.empty }
        let bpm = approximateBPM.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            ?? TrackAnalyzer().analyze(audio).tempo.bpm
        try Task.checkCancellation()
        return MixTrackAudio(trackID: trackID, audio: audio,
                             analysis: BlendAnalyzer.analyze(audio, approximateBPM: bpm))
    }

    /// Longest track the mix decks hold as resident PCM. Beyond it the edge plays sequentially.
    static let maxResidentSeconds = 900.0
    /// Frames per windowed read while filling the deck PCM; the only transient allocation.
    static let decodeChunkFrames = 1 << 16

    /// Decodes through the windowed range source, `decodeChunkFrames` at a time: no whole-file read, no
    /// whole-file decoder copy. A container that cannot seek throws `unsupportedBoundedDecode`.
    /// AVFoundation picks a parser from the file extension; a cache blob has none, so it is read
    /// through a link that carries one.
    static func decode(_ url: URL, container: AudioContainer) throws -> PCMBuffer {
        var readable = url
        var link: URL?
        if url.pathExtension.isEmpty, let ext = fileExtension(for: container) {
            let named = temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: named, withDestinationURL: url)
            readable = named
            link = named
        }
        defer { if let link { try? FileManager.default.removeItem(at: link) } }
        let source = try FileRangeAudioSource.open(url: readable, container: container)
        let seconds = Double(source.totalFrames) / source.sampleRate
        guard seconds <= maxResidentSeconds else { throw tooLongError(seconds) }
        let total = Int(source.totalFrames)
        let channels = source.channelCount
        let format = AudioFormat(sampleRate: source.sampleRate, channelCount: channels)
        var out = PCMBuffer(format: format, capacity: total)
        var filled = 0
        while filled < total {
            try Task.checkCancellation()
            let pcm = try source.decodeRange(startFrame: Int64(filled), frameCount: decodeChunkFrames)
            let frames = pcm.count / channels
            guard frames > 0 else { break }
            for c in 0..<channels {
                let channel = out.channel(c)
                for f in 0..<frames { channel[filled + f] = pcm[f * channels + c] }
            }
            filled += frames
        }
        if filled < total {              // the header over-reported (VBR estimate): keep what decoded
            let trimmed = PCMBuffer(format: format, capacity: filled)
            for c in 0..<channels {
                let from = out.channel(c), to = trimmed.channel(c)
                for f in 0..<filled { to[f] = from[f] }
            }
            out = trimmed
        }
        return out
    }

    private static func tooLongError(_ seconds: Double) -> MixTrackLoaderError { .tooLong(Int(seconds)) }

    static func download(_ url: URL, headers: [String: String], container: AudioContainer,
                         progress: @escaping @Sendable (Stage) -> Void) async throws -> URL {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MixTrackLoaderError.download(http.statusCode)
        }
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let ext = fileExtension(for: container) ?? url.pathExtension
        let file = temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let expected = response.expectedContentLength
        var chunk = Data()
        chunk.reserveCapacity(1 << 18)
        var written: Int64 = 0
        progress(.downloading(0))
        do {
            for try await byte in bytes {
                chunk.append(byte)
                if chunk.count >= 1 << 18 {
                    try handle.write(contentsOf: chunk)
                    written += Int64(chunk.count)
                    chunk.removeAll(keepingCapacity: true)
                    try Task.checkCancellation()
                    if expected > 0 { progress(.downloading(min(1, Double(written) / Double(expected)))) }
                }
            }
            try handle.write(contentsOf: chunk)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        progress(.downloading(1))
        return file
    }

    /// Keeps a complete download as the stream cache's entry for the track, so it plays
    /// (and joins a mix) from disk next time. Nil, leaving the file where it is, on failure.
    static func adoptIntoCache(_ file: URL, key: String) async -> URL? {
        let destination = AudioCache.fileURL(for: key)
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.int64Value ?? 0
        guard bytes > 0 else { return nil }
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: file, to: destination)
        } catch {
            return nil
        }
        await AudioCache.shared.adoptCompleteFile(byteCount: bytes, for: key)
        return destination
    }

    static func fileExtension(for container: AudioContainer) -> String? {
        switch container {
        case .flac: return "flac"
        case .oggVorbis: return "ogg"
        case .opus: return "opus"
        case .wav: return "wav"
        case .aiff: return "aiff"
        case .caf: return "caf"
        case .mp3: return "mp3"
        case .aac: return "aac"
        case .m4a: return "m4a"
        case .m4b: return "m4b"
        case .auto: return nil
        }
    }

    static func container(forMIME mime: String?) -> AudioContainer {
        switch mime?.lowercased() {
        case "audio/mpeg", "audio/mp3": return .mp3
        case "audio/mp4", "audio/m4a", "audio/x-m4a": return .m4a
        case "audio/aac": return .aac
        case "audio/flac", "audio/x-flac": return .flac
        case "audio/wav", "audio/x-wav", "audio/wave": return .wav
        case "audio/aiff", "audio/x-aiff": return .aiff
        case "audio/ogg": return .oggVorbis
        case "audio/opus": return .opus
        default: return .auto
        }
    }

    static func container(forExtension ext: String) -> AudioContainer {
        switch ext.lowercased() {
        case "flac": return .flac
        case "ogg": return .oggVorbis
        case "opus": return .opus
        case "wav": return .wav
        case "aif", "aiff": return .aiff
        case "caf": return .caf
        case "mp3": return .mp3
        case "aac": return .aac
        case "m4a", "alac": return .m4a
        case "m4b": return .m4b
        default: return .auto
        }
    }

    static var temporaryDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MixDecks", isDirectory: true)
    }
}
#endif
