#if !os(watchOS)
import Foundation
import UIKit
import TonearmCore
import TonearmWatchProtocol

/// Binds the §8 phone transfer manager's seams to the real library, cache, and WatchConnectivity.
///
/// Kept in `Sources/App/Watch` because it touches `LibraryStore`, `CacheStore` and `WCSession`
/// (via `WatchSessionWriter`) — none of which the SPM test target compiles. It holds no protocol
/// logic: `PhoneWatchDownloadManager` and `PhoneWatchDownloadPlanner` do, and both are host-tested.
///
/// Unwired until Phase 6 constructs it from `AppState`.

// MARK: - Audio resolution

/// Resolves a watch track ID to a phone-local audio file. §8.1: "resolve remote audio into the
/// existing phone cache before transfer." This phase resolves *already-local* audio — an imported
/// asset or a complete stream-cache entry. Fetching a remote-only track on demand is Phase 8.
public struct PhoneWatchLibraryAudioResolver: PhoneWatchAudioResolving {
    private let store: LibraryStore

    public init(store: LibraryStore) {
        self.store = store
    }

    public func resolve(trackID: WatchTrackID) async -> PhoneWatchAudioResolution {
        guard let row = try? await resolveRow(trackID), let asset = row.asset else {
            return .unavailable
        }
        if let reason = asset.unsupportedReason {
            return .unsupported(reason: reason)
        }
        guard let url = Self.localURL(for: asset), FileManager.default.fileExists(atPath: url.path) else {
            return .unavailable
        }
        return .cached(url, bytes: Self.byteCount(of: url) ?? asset.sizeBytes ?? 0, sha256: nil)
    }

    public func transferability(trackID: WatchTrackID) async -> PhoneWatchTransferability {
        guard let row = try? await resolveRow(trackID), let asset = row.asset else {
            return .unavailable
        }
        if let reason = asset.unsupportedReason {
            return .unsupported(reason: reason)
        }
        guard let url = Self.localURL(for: asset), FileManager.default.fileExists(atPath: url.path) else {
            return .unavailable
        }
        return .ready(bytes: Self.byteCount(of: url) ?? asset.sizeBytes, sha256: nil)
    }

    private func resolveRow(_ id: WatchTrackID) async throws -> TrackRow? {
        if let rowID = PhoneWatchID.trackRowID(id) {
            return try await store.trackRow(id: rowID)
        }
        return try await store.trackRow(syncID: id.rawValue)
    }

    /// Mirrors `AppState.resolveLocalURL` plus a complete-stream-cache fallback.
    static func localURL(for asset: Asset) -> URL? {
        if let bookmark = asset.bookmark, let (url, _) = BookmarkVault.resolve(bookmark) {
            return url
        }
        if let remote = asset.remoteURL.flatMap(URL.init(string:)), remote.isFileURL {
            return remote
        }
        if let relPath = asset.relPath {
            let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: false)
            return base?.appendingPathComponent(relPath)
        }
        if let remote = asset.remoteURL.flatMap(URL.init(string:)),
           AudioCache.completeCacheExists(for: remote) {
            return AudioCache.fileURL(for: AudioCache.key(for: remote))
        }
        return nil
    }

    private static func byteCount(of url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }
}

/// Resolves catalog/custom artwork only when a desired track is about to be sent. The resolver
/// always produces a deterministic JPEG derivative, so the ID exposed to the watch is the hash of
/// the exact bytes delivered there rather than an IA identifier or the phone's UUID-backed source.
public struct PhoneWatchLibraryArtworkResolver: PhoneWatchArtworkResolving {
    private let store: LibraryStore

    public init(store: LibraryStore) { self.store = store }

    public func resolveArtwork(trackID: WatchTrackID) async -> PhoneWatchArtworkResolution? {
        guard let row = try? await resolveRow(trackID) else { return nil }
        var coverID: String?
        var customID: String?
        var transfers: [PhoneWatchArtworkTransfer] = []

        var rawCustom: String?
        if let localID = row.track.id { rawCustom = try? await store.customArtworkId(for: localID) }
        if let rawCustom, !rawCustom.isEmpty,
           let sourceURL = await ArtworkStore.shared.fileURLIfPresent(id: rawCustom) {
            if let exact = Self.exactDerivativeTransfer(sourceURL: sourceURL, artworkID: rawCustom, role: .custom) {
                customID = exact.artworkID
                transfers.append(exact)
            } else if let derivative = try? WatchArtworkVariant.make(from: sourceURL),
                      let transfer = Self.transfer(from: derivative, role: .custom) {
                customID = derivative.artworkID
                transfers.append(transfer)

                // Assignment may have predated the watch pipeline and therefore used the phone's
                // UUID-backed source ID. Make the durable binding derivative-backed now.
                if rawCustom.lowercased() != derivative.artworkID.lowercased(), let localID = row.track.id {
                    let derivativeData = (try? Data(contentsOf: derivative.fileURL)) ?? Data()
                    if await ArtworkStore.shared.storeWatchVariant(derivativeData, artworkID: derivative.artworkID) {
                        try? await store.setCustomArtwork(trackId: localID, artworkId: derivative.artworkID)
                        let remaining = (try? await store.allCustomArtworkIds()) ?? []
                        if !remaining.contains(rawCustom) { await ArtworkStore.shared.delete(id: rawCustom) }
                    }
                }
            }
        }

        // IA's metadata/file picker remains the source of truth for catalog covers. For providers
        // without an IA album identifier, use the existing track artwork resolver as its fallback.
        let coverImage: UIImage?
        if let sourceID = row.album?.artworkId, !sourceID.isEmpty {
            coverImage = await ArtworkService.shared.artwork(forIdentifier: sourceID)
        } else if customID == nil {
            coverImage = await ArtworkService.shared.trackArtwork(forTrackRow: row)?.image
        } else {
            coverImage = nil
        }
        if let coverImage, let derivative = try? WatchArtworkVariant.make(image: coverImage),
           let transfer = Self.transfer(from: derivative, role: .cover) {
            coverID = derivative.artworkID
            transfers.append(transfer)
        }

        guard coverID != nil || customID != nil else { return nil }
        return PhoneWatchArtworkResolution(coverArtworkID: coverID, customArtworkID: customID,
                                           transfers: transfers)
    }

    private func resolveRow(_ id: WatchTrackID) async throws -> TrackRow? {
        if let rowID = PhoneWatchID.trackRowID(id) { return try await store.trackRow(id: rowID) }
        return try await store.trackRow(syncID: id.rawValue)
    }

    private static func transfer(from result: WatchArtworkVariant.Result,
                                 role: WatchArtworkRole) -> PhoneWatchArtworkTransfer? {
        guard result.bytes > 0 else { return nil }
        return PhoneWatchArtworkTransfer(fileURL: result.fileURL, artworkID: result.artworkID,
                                         role: role, expectedBytes: result.bytes,
                                         sha256: result.artworkID)
    }

    private static func exactDerivativeTransfer(sourceURL: URL, artworkID: String,
                                                role: WatchArtworkRole) -> PhoneWatchArtworkTransfer? {
        let id = artworkID.lowercased()
        guard id.count == 64, id.allSatisfy({ $0.isHexDigit }),
              let digest = try? WatchFileDigest.measure(sourceURL),
              digest.sha256.lowercased() == id, digest.bytes > 0 else { return nil }
        return PhoneWatchArtworkTransfer(fileURL: sourceURL, artworkID: id, role: role,
                                         expectedBytes: digest.bytes, sha256: id)
    }
}

// MARK: - File transfer

/// Sends a resolved file to the watch through the §5 transport seam. The metadata rides as the
/// property-list-safe `WatchAudioFileMetadata` dictionary — IDs, size, checksum, pin intent — which
/// the watch's `WatchFileInstaller` is the sole reader of.
///
/// `outstandingTransfers()` returns nothing: rehydrating `WCSession.outstandingFileTransfers` into
/// job identity is a later refinement. A relaunch conservatively re-queues any job the store left
/// `transferring`, which the watch manifest then dedupes.
public struct PhoneWatchSessionFileTransfer: PhoneWatchFileTransferring {
    let transport: any WatchProtocolTransport
    let phoneRevision: @Sendable () async -> Int64

    public init(transport: any WatchProtocolTransport,
                phoneRevision: @escaping @Sendable () async -> Int64 = { 0 }) {
        self.transport = transport
        self.phoneRevision = phoneRevision
    }

    public func transfer(fileURL: URL, trackID: WatchTrackID,
                         expectedBytes: Int64, sha256: String?) async throws {
        let metadata = WatchAudioFileMetadata(
            trackID: trackID, expectedBytes: expectedBytes, sha256: sha256,
            pinned: true, phoneRevision: await phoneRevision())
        await transport.transferFile(fileURL, metadata: metadata.dictionary)
    }

    public func outstandingTransfers() async -> [WatchTrackID] { [] }

    public func cancelTransfer(trackID: WatchTrackID) async {}
}

extension PhoneWatchSessionFileTransfer: PhoneWatchArtworkTransferring {
    public func transferArtwork(_ transfer: PhoneWatchArtworkTransfer) async throws {
        let metadata = WatchArtworkFileMetadata(
            artworkID: transfer.artworkID, expectedBytes: transfer.expectedBytes,
            sha256: transfer.sha256, role: transfer.role,
            phoneRevision: await phoneRevision())
        await transport.transferFile(transfer.fileURL, metadata: metadata.dictionary)
    }
}

// MARK: - Network gate

/// Answers §8.2's Wi-Fi question from an injected policy closure (the phone's `NetworkPolicy` /
/// cellular-downloads setting, supplied by `AppState`).
public struct PhoneWatchPolicyNetworkGate: PhoneWatchNetworkGate {
    private let allow: @Sendable () async -> Bool

    public init(allow: @escaping @Sendable () async -> Bool) {
        self.allow = allow
    }

    public func canTransferNow() async -> Bool { await allow() }
}

/// Deterministic ≤300 px JPEG derivative used for watch artwork transfers.
public enum WatchArtworkVariant {
    public static let defaultMaxEdge: CGFloat = 300
    public static let jpegQuality: CGFloat = 0.78
    public struct Result: Sendable, Equatable {
        public let fileURL: URL
        public let artworkID: String
        public let bytes: Int64
    }

    public static func make(from sourceURL: URL, maxEdge: CGFloat = defaultMaxEdge) throws -> Result {
        guard let image = UIImage(contentsOfFile: sourceURL.path), image.size.width > 0, image.size.height > 0,
              let data = encoded(image: image, maxEdge: maxEdge) else { throw CocoaError(.fileReadCorruptFile) }
        return try write(data)
    }

    public static func make(image: UIImage, maxEdge: CGFloat = defaultMaxEdge) throws -> Result {
        guard image.size.width > 0, image.size.height > 0,
              let data = encoded(image: image, maxEdge: maxEdge) else { throw CocoaError(.fileReadCorruptFile) }
        return try write(data)
    }

    private static func write(_ data: Data) throws -> Result {
        let id = WatchFileDigest.hex(data)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("watch-art-\(id).jpg")
        try data.write(to: url, options: .atomic)
        return Result(fileURL: url, artworkID: id, bytes: Int64(data.count))
    }

    private static func encoded(image: UIImage, maxEdge: CGFloat) -> Data? {
        let edge = max(1, maxEdge), scale = min(1, edge / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.jpegData(compressionQuality: jpegQuality)
    }
}

public extension PhoneWatchSessionFileTransfer {
    /// Compatibility wrapper for callers that used the pre-manager helper. New production code
    /// goes through `PhoneWatchArtworkTransferring` so capability/network gating is centralized.
    func transferArtwork(fileURL: URL, artworkID: String, role: WatchArtworkRole,
                         expectedBytes: Int64, sha256: String? = nil,
                         artworkCapability: Bool = true) async -> Bool {
        guard artworkCapability else { return false }
        do {
            try await transferArtwork(PhoneWatchArtworkTransfer(
                fileURL: fileURL, artworkID: artworkID, role: role,
                expectedBytes: expectedBytes, sha256: sha256 ?? artworkID))
            return true
        } catch {
            return false
        }
    }
}
#endif
