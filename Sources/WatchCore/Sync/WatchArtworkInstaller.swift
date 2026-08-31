import Foundation
import TonearmWatchProtocol

public enum WatchArtworkInstallOutcome: Equatable, Sendable {
    case installed(artworkID: String, relativeFilename: String, bytes: Int64)
    case duplicateIgnored(artworkID: String)
    case rejected(artworkID: String, WatchProtocolFault)
}

/// Validates and atomically installs content-addressed artwork deliveries.
public actor WatchArtworkInstaller {
    public static let supportedFileExtensions: Set<String> = ["jpg", "jpeg", "png", "heic"]
    private let repository: WatchLibraryRepository
    private let artworkDirectory: URL
    private let fileManager: FileManager
    private let storageProvider: @Sendable () async -> WatchStorageSnapshot?

    public init(repository: WatchLibraryRepository, artworkDirectory: URL,
                fileManager: FileManager = .default,
                storageProvider: (@Sendable () async -> WatchStorageSnapshot?)? = nil) {
        self.repository = repository; self.artworkDirectory = artworkDirectory
        self.fileManager = fileManager
        self.storageProvider = storageProvider ?? { [repository] in try? await repository.storage() }
    }

    @discardableResult
    public func install(stagedURL: URL, metadata raw: [String: String]) async -> WatchArtworkInstallOutcome {
        guard let metadata = WatchArtworkFileMetadata(dictionary: raw) else {
            try? fileManager.removeItem(at: stagedURL)
            return .rejected(artworkID: raw["artworkID"] ?? "", WatchProtocolFault(code: .installationFailed))
        }
        return await install(stagedURL: stagedURL, metadata: metadata)
    }

    @discardableResult
    public func install(stagedURL: URL, metadata: WatchArtworkFileMetadata) async -> WatchArtworkInstallOutcome {
        let id = metadata.artworkID
        try? fileManager.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        let ext = stagedURL.pathExtension.lowercased()
        guard Self.supportedFileExtensions.contains(ext) else {
            try? fileManager.removeItem(at: stagedURL)
            return .rejected(artworkID: id, WatchProtocolFault(code: .unsupportedArtwork))
        }
        guard let measured = try? WatchFileDigest.measure(stagedURL), measured.bytes == metadata.expectedBytes,
              measured.sha256.lowercased() == metadata.sha256.lowercased() else {
            try? fileManager.removeItem(at: stagedURL)
            return .rejected(artworkID: id, WatchProtocolFault(code: .checksumMismatch))
        }
        if let storage = await storageProvider(), !storage.canAccept(bytes: measured.bytes) {
            try? fileManager.removeItem(at: stagedURL)
            return .rejected(artworkID: id, WatchProtocolFault(code: .insufficientWatchStorage))
        }
        let name = WatchFileInstaller.contentAddressedName(sha256: measured.sha256, ext: ext)
        let destination = artworkDirectory.appendingPathComponent(name)
        do {
            if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: stagedURL) }
            else { try fileManager.moveItem(at: stagedURL, to: destination) }
            try await repository.markArtworkAsset(artworkID: id, relativeFilename: name,
                                                   installedBytes: measured.bytes, state: .ready)
            return .installed(artworkID: id, relativeFilename: name, bytes: measured.bytes)
        } catch {
            try? fileManager.removeItem(at: stagedURL)
            return .rejected(artworkID: id, WatchProtocolFault(code: .installationFailed))
        }
    }
}
