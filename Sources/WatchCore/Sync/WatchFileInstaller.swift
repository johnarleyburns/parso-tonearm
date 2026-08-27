import Foundation
import TonearmWatchProtocol

/// The outcome of one §8.3 installation attempt. Every case is a fact the sync actor reports back
/// to the phone through a manifest acknowledgement; nothing here throws past the installer.
public enum WatchInstallOutcome: Equatable, Sendable {
    /// The asset is ready and every visible row for it now resolves to a valid local file.
    case installed(trackID: String, relativeFilename: String, bytes: Int64)
    /// §5.4 duplicate delivery: the ready asset already matches this file, so it was validated and
    /// acknowledged without a rewrite.
    case duplicateIgnored(trackID: String)
    /// §5.4 audio-before-metadata: no track row exists yet. The file is retained in staging and
    /// retried when metadata arrives.
    case deferredAwaitingMetadata(trackID: String)
    /// Validation or the atomic install failed. Staging is cleaned; the phone retries per policy.
    case rejected(trackID: String, WatchProtocolFault)
}

/// §8.3 steps 3–7: validate a staged audio file, move it atomically into place under a
/// content-addressed name, commit the asset in one SwiftData transaction, and clean staging.
///
/// Steps 1–2 (receive into the framework temp URL, copy into a unique staging file before the
/// delegate callback returns) belong to the transport adapter — by the time `install` runs, the
/// file is already the installer's to keep or delete.
public actor WatchFileInstaller {
    /// Container/codec forms watchOS `AVPlayer` can prepare. A file that is not one of these is a
    /// permanent skip (`unsupportedAudio`), never a retry.
    public static let supportedFileExtensions: Set<String> = [
        "mp3", "m4a", "aac", "alac", "wav", "aif", "aiff", "caf"
    ]
    public static let supportedCodecTokens: Set<String> = [
        "mp3", "aac", "alac", "pcm", "lpcm", "wav", "aiff", "alac", "aac-lc"
    ]

    private let repository: WatchLibraryRepository
    private let audioDirectory: URL
    private let stagingDirectory: URL
    private let fileManager: FileManager
    private let storageProvider: @Sendable () async -> WatchStorageSnapshot?

    public init(repository: WatchLibraryRepository, audioDirectory: URL,
                stagingDirectory: URL, fileManager: FileManager = .default,
                storageProvider: (@Sendable () async -> WatchStorageSnapshot?)? = nil) {
        self.repository = repository
        self.audioDirectory = audioDirectory
        self.stagingDirectory = stagingDirectory
        self.fileManager = fileManager
        self.storageProvider = storageProvider ?? { [repository] in try? await repository.storage() }
    }

    // MARK: - Install

    /// Install one freshly-delivered file. `stagedURL` is consumed: on every return path it has
    /// either been moved into place, moved into deferred staging, or deleted.
    @discardableResult
    public func install(stagedURL: URL, metadata rawMetadata: [String: String]) async -> WatchInstallOutcome {
        try? fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)

        guard let metadata = WatchAudioFileMetadata(dictionary: rawMetadata) else {
            // Nothing to attribute the file to — it cannot even be deferred.
            try? fileManager.removeItem(at: stagedURL)
            return .rejected(trackID: rawMetadata["trackID"] ?? "",
                             WatchProtocolFault(code: .installationFailed))
        }
        return await install(stagedURL: stagedURL, metadata: metadata)
    }

    @discardableResult
    func install(stagedURL: URL, metadata: WatchAudioFileMetadata) async -> WatchInstallOutcome {
        let trackID = metadata.trackID.rawValue

        // Step 3a: codec / container support is a permanent decision, checked before hashing.
        let ext = stagedURL.pathExtension.lowercased()
        let codecOK = metadata.codec.map { Self.supportedCodecTokens.contains($0.lowercased()) } ?? true
        guard (ext.isEmpty || Self.supportedFileExtensions.contains(ext)), codecOK else {
            try? fileManager.removeItem(at: stagedURL)
            try? removeDeferred(trackID: trackID)
            return .rejected(trackID: trackID, WatchProtocolFault(code: .unsupportedAudio))
        }

        // Step 3b: measure the bytes actually on disk.
        let measured: (sha256: String, bytes: Int64)
        do {
            measured = try WatchFileDigest.measure(stagedURL)
        } catch {
            try? fileManager.removeItem(at: stagedURL)
            return .rejected(trackID: trackID, WatchProtocolFault(code: .checksumMismatch))
        }

        // Step 3c: a truncated or corrupt file is rejected and staging is cleared (§5.5
        // checksumMismatch → "delete staging; explicit/bounded retry").
        if measured.bytes != metadata.expectedBytes
            || (metadata.sha256.map { $0.lowercased() != measured.sha256 } ?? false) {
            try? fileManager.removeItem(at: stagedURL)
            try? removeDeferred(trackID: trackID)
            return .rejected(trackID: trackID, WatchProtocolFault(code: .checksumMismatch))
        }

        // Step 3d: without a track row there is no metadata to bind the asset to. Retain the file
        // in deferred staging keyed by track ID and reconcile when metadata lands (§5.4).
        let hasTrack: Bool
        do {
            hasTrack = try await repository.tracks(readyOnly: false).contains { $0.id == trackID }
        } catch {
            hasTrack = false
        }
        guard hasTrack else {
            _ = try? retainDeferred(stagedURL: stagedURL, metadata: metadata)
            return .deferredAwaitingMetadata(trackID: trackID)
        }

        // §5.4 duplicate delivery: an already-ready asset with the same checksum is acknowledged
        // without touching the file that is already in place.
        if let existing = try? await repository.tracks(readyOnly: true).first(where: { $0.id == trackID }),
           existing.isReady, let existingName = existing.localFilename,
           existingName == Self.contentAddressedName(sha256: measured.sha256, ext: ext) {
            try? fileManager.removeItem(at: stagedURL)
            try? removeDeferred(trackID: trackID)
            return .duplicateIgnored(trackID: trackID)
        }

        // Step 3e: the §2.5 free-space reserve must survive accepting this file.
        if let storage = await storageProvider(), !storage.canAccept(bytes: measured.bytes) {
            try? fileManager.removeItem(at: stagedURL)
            try? removeDeferred(trackID: trackID)
            return .rejected(trackID: trackID, WatchProtocolFault(code: .insufficientWatchStorage))
        }

        // Step 4: atomic move into Application Support under a content-addressed filename. Two
        // deliveries of the same bytes converge on the same name, so a re-delivery is a no-op move.
        let relativeFilename = Self.contentAddressedName(sha256: measured.sha256, ext: ext)
        let destination = audioDirectory.appendingPathComponent(relativeFilename)
        let previousName = try? await repository.tracks(readyOnly: true)
            .first(where: { $0.id == trackID })?.localFilename

        do {
            if fileManager.fileExists(atPath: destination.path) {
                // Same content already present (idempotent re-delivery); drop the duplicate copy.
                try fileManager.removeItem(at: stagedURL)
            } else {
                try fileManager.moveItem(at: stagedURL, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: stagedURL)
            return .rejected(trackID: trackID, WatchProtocolFault(code: .installationFailed))
        }

        // Step 5: mark the asset ready in one transaction.
        do {
            try await repository.markAsset(trackID: trackID, relativeFilename: relativeFilename,
                                           installedBytes: measured.bytes, sha256: measured.sha256,
                                           state: .ready)
        } catch {
            // The store rejected the commit; leave the moved file for reconciliation to adopt or
            // sweep rather than deleting validated user audio (§8.3 "never delete … until …").
            return .rejected(trackID: trackID, WatchProtocolFault(code: .installationFailed))
        }

        // Step 7: staging cleanup, plus the superseded file — only now that the replacement is
        // committed (§8.3 "Never delete an existing ready asset until a replacement is installed
        // and committed").
        try? removeDeferred(trackID: trackID)
        if let previousName, previousName != relativeFilename {
            try? fileManager.removeItem(at: audioDirectory.appendingPathComponent(previousName))
        }

        return .installed(trackID: trackID, relativeFilename: relativeFilename, bytes: measured.bytes)
    }

    // MARK: - Deferred retry

    /// Re-attempt every file parked by a `deferredAwaitingMetadata` result. Called after any batch
    /// of metadata upserts and on reconciliation.
    @discardableResult
    public func retryDeferred() async -> [WatchInstallOutcome] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: stagingDirectory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return [] }
        var outcomes: [WatchInstallOutcome] = []
        for meta in entries where meta.pathExtension == "meta" {
            guard let data = try? Data(contentsOf: meta),
                  let dict = try? JSONDecoder().decode([String: String].self, from: data),
                  let metadata = WatchAudioFileMetadata(dictionary: dict) else {
                try? fileManager.removeItem(at: meta)
                continue
            }
            let audio = meta.deletingPathExtension()
            guard fileManager.fileExists(atPath: audio.path) else {
                try? fileManager.removeItem(at: meta)
                continue
            }
            outcomes.append(await install(stagedURL: audio, metadata: metadata))
        }
        return outcomes
    }

    public func deferredTrackIDs() -> [String] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: stagingDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return entries.filter { $0.pathExtension == "meta" }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? JSONDecoder().decode([String: String].self, from: $0) }
            .compactMap { $0["trackID"] }
            .sorted()
    }

    // MARK: - Private

    /// A deferred file lives at `staging/<trackID sanitised>.<ext>` with a `.meta` sidecar carrying
    /// the metadata dictionary, so `retryDeferred()` needs nothing from the store to replay it.
    private func retainDeferred(stagedURL: URL, metadata: WatchAudioFileMetadata) throws -> URL {
        let base = Self.sanitised(metadata.trackID.rawValue)
        let ext = stagedURL.pathExtension.isEmpty ? "audio" : stagedURL.pathExtension
        let audio = stagingDirectory.appendingPathComponent(base).appendingPathExtension(ext)
        if fileManager.fileExists(atPath: audio.path) { try fileManager.removeItem(at: audio) }
        try fileManager.moveItem(at: stagedURL, to: audio)
        let sidecar = audio.appendingPathExtension("meta")
        try JSONEncoder().encode(metadata.dictionary).write(to: sidecar, options: .atomic)
        return audio
    }

    private func removeDeferred(trackID: String) throws {
        let base = Self.sanitised(trackID)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: stagingDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        for url in entries where url.deletingPathExtension().lastPathComponent == base
            || url.deletingPathExtension().deletingPathExtension().lastPathComponent == base {
            try? fileManager.removeItem(at: url)
        }
    }

    static func contentAddressedName(sha256: String, ext: String) -> String {
        ext.isEmpty ? sha256 : "\(sha256).\(ext)"
    }

    private static func sanitised(_ trackID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = String(trackID.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return mapped.isEmpty ? "track" : mapped
    }
}
