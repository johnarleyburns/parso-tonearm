import AVFoundation
import Foundation
import TonearmWatchCore
import TonearmWatchProtocol

/// Makes a stable, app-owned file for background delivery. Document-picker access
/// covers the entire read/encode operation. Every source, including MP3 and FLAC,
/// is normalized to the same watch-only AAC128 profile; originals are unchanged.
public enum PhoneWatchAudioPreparation {
    public static let bitRate = 128_000
    public static let sampleRate = 44_100.0
    public static func isReadable(_ url: URL) -> Bool {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return FileManager.default.isReadableFile(atPath: url.path)
    }

    public static func prepare(
        sourceURL: URL, directory: URL,
        startAccess: @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stopAccess: @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    ) async throws -> URL {
        let accessed = startAccess(sourceURL)
        defer { if accessed { stopAccess(sourceURL) } }
        let digest = try WatchFileDigest.measure(sourceURL)
        let ext = WatchAudioFileMetadata.fileExtension(for: sourceURL) ?? ""
        let outputExtension = "m4a"
        let filename = digest.sha256 + "-watch-aac128-v1.m4a"
        let destination = directory.appendingPathComponent(filename)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { return destination }
        let temporary = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(outputExtension)
        defer { try? fm.removeItem(at: temporary) }
        let input: URL
        if ext == "opus" || ext == "ogg" {
            input = try await OpusRemuxer().remux(opusFileURL: sourceURL, cacheKey: digest.sha256)
        } else {
            input = sourceURL
        }
        try await encodeAAC(source: input, destination: temporary)
        // Publish only a complete snapshot. Concurrent preparations can converge on
        // an existing destination without replacing a file WCSession may be reading.
        if !fm.fileExists(atPath: destination.path) {
            try fm.moveItem(at: temporary, to: destination)
        }
        return destination
    }

    private static func encodeAAC(source: URL, destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        guard reader.canAdd(output) else { throw CocoaError(.fileReadCorruptFile) }
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: bitRate,
            AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Constant])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw CocoaError(.fileWriteUnknown) }
        writer.add(input)
        guard writer.startWriting(), reader.startReading() else {
            throw writer.error ?? reader.error ?? CocoaError(.fileReadCorruptFile)
        }
        writer.startSession(atSourceTime: .zero)
        do {
            while let buffer = output.copyNextSampleBuffer() {
                while !input.isReadyForMoreMediaData {
                    guard writer.status == .writing else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                    try await Task.sleep(for: .milliseconds(2))
                }
                try Task.checkCancellation()
                guard input.append(buffer) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            }
            guard reader.status == .completed else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        } catch {
            reader.cancelReading(); writer.cancelWriting()
            throw error
        }
    }

    /// The only production audio send path: one prepared AAC file, one Apple file transfer.
    public static func transferWholeFile(_ fileURL: URL, metadata: WatchAudioFileMetadata,
                                         transport: any WatchProtocolTransport) async throws {
        let file = try AVAudioFile(forReading: fileURL)
        let measured = try WatchFileDigest.measure(fileURL)
        guard metadata.fileExtension == "m4a", file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC,
              measured.bytes == metadata.expectedBytes, measured.sha256 == metadata.sha256 else {
            throw WatchProtocolFault(code: .unsupportedAudio)
        }
        try await transport.transferFile(fileURL, metadata: metadata.dictionary)
    }
}
