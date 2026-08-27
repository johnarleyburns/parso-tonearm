#if !os(watchOS)
import Foundation
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
           CacheStore.completeCacheExists(for: remote) {
            return CacheStore.fileURL(for: CacheKeyGenerator.key(for: remote))
        }
        return nil
    }

    private static func byteCount(of url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
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
    private let transport: any WatchProtocolTransport
    private let phoneRevision: @Sendable () async -> Int64

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
#endif
