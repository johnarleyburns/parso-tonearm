import Foundation
import TonearmWatchProtocol

public enum WatchArtworkInstallOutcome: Equatable, Sendable {
    case installed(artworkID: String, relativeFilename: String, bytes: Int64)
    case duplicateIgnored(artworkID: String)
    case deferredAwaitingMetadata(artworkID: String)
    case rejected(artworkID: String, WatchProtocolFault)
}

/// Validates and atomically installs content-addressed artwork deliveries.
public actor WatchArtworkInstaller {
    public static let supportedFileExtensions: Set<String> = ["jpg", "jpeg", "png", "heic"]
    private let repository: WatchLibraryRepository
    private let artworkDirectory: URL
    private let stagingDirectory: URL
    private let fileManager: FileManager
    private let storageProvider: @Sendable () async -> WatchStorageSnapshot?

    public init(repository: WatchLibraryRepository, artworkDirectory: URL,
                stagingDirectory: URL? = nil,
                fileManager: FileManager = .default,
                storageProvider: (@Sendable () async -> WatchStorageSnapshot?)? = nil) {
        self.repository = repository; self.artworkDirectory = artworkDirectory
        self.stagingDirectory = stagingDirectory ?? artworkDirectory.deletingLastPathComponent()
            .appendingPathComponent("StagingArtwork", isDirectory: true)
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
        let id = metadata.artworkID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let expectedHash = metadata.sha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        try? fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        let ext = stagedURL.pathExtension.lowercased()
        guard Self.supportedFileExtensions.contains(ext) else {
            try? fileManager.removeItem(at: stagedURL)
            return .rejected(artworkID: id, WatchProtocolFault(code: .unsupportedArtwork))
        }
        guard id.count == 64, expectedHash.count == 64, id == expectedHash,
              metadata.expectedBytes >= 0 else {
            try? fileManager.removeItem(at: stagedURL)
            return .rejected(artworkID: id, WatchProtocolFault(code: .checksumMismatch))
        }
        guard let measured = try? WatchFileDigest.measure(stagedURL), measured.bytes == metadata.expectedBytes,
              measured.sha256.lowercased() == expectedHash else {
            try? fileManager.removeItem(at: stagedURL)
            return .rejected(artworkID: id, WatchProtocolFault(code: .checksumMismatch))
        }

        let name = WatchFileInstaller.contentAddressedName(sha256: expectedHash, ext: ext)
        let destination = artworkDirectory.appendingPathComponent(name)
        let hasReference = (try? await repository.hasArtworkReference(artworkID: id)) == true
        // A binding may arrive after a previously accepted file. Keep a valid content-addressed
        // row/file untouched and acknowledge the delivery without rewriting it.
        if let existing = try? await repository.artworkAsset(artworkID: id),
           existing.validationState == .ready,
           Self.supportedFileExtensions.contains(URL(fileURLWithPath: existing.relativeFilename).pathExtension.lowercased()),
           URL(fileURLWithPath: existing.relativeFilename).deletingPathExtension().lastPathComponent.lowercased() == id,
           let existingURL = Optional(artworkDirectory.appendingPathComponent(existing.relativeFilename)),
           let existingMeasured = try? WatchFileDigest.measure(existingURL),
           existingMeasured.bytes == existing.bytes,
           existingMeasured.sha256.lowercased() == id {
            try? fileManager.removeItem(at: stagedURL)
            try? removeDeferred(artworkID: id)
            return .duplicateIgnored(artworkID: id)
        }
        if fileManager.fileExists(atPath: destination.path),
           let existingMeasured = try? WatchFileDigest.measure(destination),
           existingMeasured.bytes == measured.bytes,
           existingMeasured.sha256.lowercased() == id {
            if hasReference {
                try? await repository.markArtworkAsset(artworkID: id, relativeFilename: name,
                                                        installedBytes: measured.bytes, state: .ready)
            } else {
                _ = try? retainDeferred(stagedURL: stagedURL, metadata: metadata)
                return .deferredAwaitingMetadata(artworkID: id)
            }
            try? fileManager.removeItem(at: stagedURL)
            try? removeDeferred(artworkID: id)
            return .duplicateIgnored(artworkID: id)
        }

        guard hasReference else {
            _ = try? retainDeferred(stagedURL: stagedURL, metadata: metadata)
            return .deferredAwaitingMetadata(artworkID: id)
        }
        if let storage = await storageProvider(), !storage.canAccept(bytes: measured.bytes) {
            try? fileManager.removeItem(at: stagedURL)
            return .rejected(artworkID: id, WatchProtocolFault(code: .insufficientWatchStorage))
        }
        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: stagedURL, to: destination)
            try await repository.markArtworkAsset(artworkID: id, relativeFilename: name,
                                                   installedBytes: measured.bytes, state: .ready)
            try? removeDeferred(artworkID: id)
            return .installed(artworkID: id, relativeFilename: name, bytes: measured.bytes)
        } catch {
            try? fileManager.removeItem(at: stagedURL)
            return .rejected(artworkID: id, WatchProtocolFault(code: .installationFailed))
        }
    }

    @discardableResult
    public func retryDeferred() async -> [WatchArtworkInstallOutcome] {
        guard let entries = try? fileManager.contentsOfDirectory(at: stagingDirectory,
                                                                   includingPropertiesForKeys: nil,
                                                                   options: [.skipsHiddenFiles]) else { return [] }
        var outcomes: [WatchArtworkInstallOutcome] = []
        for meta in entries where meta.pathExtension == "meta" {
            guard let data = try? Data(contentsOf: meta),
                  let dict = try? JSONDecoder().decode([String: String].self, from: data),
                  let metadata = WatchArtworkFileMetadata(dictionary: dict) else {
                try? fileManager.removeItem(at: meta)
                continue
            }
            let artwork = meta.deletingPathExtension()
            guard fileManager.fileExists(atPath: artwork.path) else {
                try? fileManager.removeItem(at: meta)
                continue
            }
            outcomes.append(await install(stagedURL: artwork, metadata: metadata))
        }
        return outcomes
    }

    private func retainDeferred(stagedURL: URL, metadata: WatchArtworkFileMetadata) throws {
        let id = metadata.artworkID.lowercased()
        let artwork = stagingDirectory.appendingPathComponent(id).appendingPathExtension(
            stagedURL.pathExtension.lowercased())
        if fileManager.fileExists(atPath: artwork.path) { try fileManager.removeItem(at: artwork) }
        try fileManager.moveItem(at: stagedURL, to: artwork)
        try JSONEncoder().encode(metadata.dictionary).write(to: artwork.appendingPathExtension("meta"), options: .atomic)
    }

    private func removeDeferred(artworkID: String) throws {
        let prefix = artworkID.lowercased()
        guard let entries = try? fileManager.contentsOfDirectory(at: stagingDirectory,
                                                                   includingPropertiesForKeys: nil,
                                                                   options: [.skipsHiddenFiles]) else { return }
        for entry in entries where entry.deletingPathExtension().lastPathComponent == prefix
            || entry.deletingPathExtension().deletingPathExtension().lastPathComponent == prefix {
            try? fileManager.removeItem(at: entry)
        }
    }
}
