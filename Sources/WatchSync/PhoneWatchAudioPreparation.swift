import AVFoundation
import Foundation
import TonearmWatchCore
import TonearmWatchProtocol

/// Makes a stable, app-owned file for background delivery. Document-picker access
/// must cover reading the source, not just resolving its bookmark. Unsupported
/// watch containers (including FLAC) are exported to AAC rather than sent as-is.
public enum PhoneWatchAudioPreparation {
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
        let needsConversion = !WatchFileInstaller.supportedFileExtensions.contains(ext)
        let outputExtension = needsConversion ? "m4a" : ext
        let filename = digest.sha256 + (needsConversion ? "-watch-aac" : "") + "." + outputExtension
        let destination = directory.appendingPathComponent(filename)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { return destination }
        let temporary = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(outputExtension)
        defer { try? fm.removeItem(at: temporary) }
        if needsConversion {
            let input: URL
            if ext == "opus" || ext == "ogg" {
                input = try await OpusRemuxer().remux(opusFileURL: sourceURL, cacheKey: digest.sha256)
            } else {
                input = sourceURL
            }
            guard let exporter = AVAssetExportSession(asset: AVURLAsset(url: input),
                presetName: AVAssetExportPresetAppleM4A) else { throw CocoaError(.fileReadCorruptFile) }
            try await exporter.export(to: temporary, as: .m4a)
        } else {
            try fm.copyItem(at: sourceURL, to: temporary)
        }
        // Publish only a complete snapshot. Concurrent preparations can converge on
        // an existing destination without replacing a file WCSession may be reading.
        if !fm.fileExists(atPath: destination.path) {
            try fm.moveItem(at: temporary, to: destination)
        }
        return destination
    }
}
