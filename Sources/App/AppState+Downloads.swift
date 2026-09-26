import Foundation
import ParsoAudioStreaming
import SwiftUI
import TonearmCore
#if !os(macOS)
import UIKit
#endif

extension AppState {
    /// Resolves a track to bytes that the DJ engine can read. The normal player
    /// can stream a remote asset, but the DJ engine needs a complete local file
    /// before it can build its PCM buffer and waveform. Reuse the durable audio
    /// cache when possible and fetch the track on demand when it is not there.
    ///
    /// This is deliberately separate from `phoneDownloadState`: selecting a
    /// track in DJ is an explicit request to make it playable now, not a reason
    /// to reject the track because it has not been pre-downloaded.
    func djPlayableURL(for row: TrackRow) async throws -> URL {
        guard let asset = row.asset else { throw DJPlayableAssetError.missingAsset }

        if asset.kind == .builtIn, let channel = asset.relPath,
           let url = BuiltInContentProvider.bundledAudioURL(forChannelId: channel),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }

        if let bookmark = asset.bookmark,
           let (url, _) = BookmarkVault.resolve(bookmark),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }

        if let fileURL = asset.remoteURL.flatMap(URL.init(string:)), fileURL.isFileURL,
           FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL
        }

        if let relPath = asset.relPath {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false)
            let url = base.appendingPathComponent(relPath)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }

        guard asset.kind == .remote else { throw DJPlayableAssetError.noLocalBytes }

        let remoteURLs = [asset.remoteURL, asset.altRemoteURL]
            .compactMap { $0.flatMap(URL.init(string:)) }
        for remote in remoteURLs {
            let key = AudioCache.key(for: remote)
            let cached = AudioCache.fileURL(for: key)
            if AudioCache.completeCacheExists(for: remote),
               FileManager.default.fileExists(atPath: cached.path) {
                return cached
            }
        }

        guard let request = await fetchRequest(for: asset, source: row.source) else {
            throw DJPlayableAssetError.remoteRequestUnavailable
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw DJPlayableAssetError.remoteRequestFailed(http.statusCode)
        }

        guard let remote = asset.remoteURL.flatMap(URL.init(string:)) else {
            throw DJPlayableAssetError.missingRemoteURL
        }
        let key = AudioCache.key(for: remote)
        let destination = AudioCache.fileURL(for: key)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
        await AudioCache.shared.adoptCompleteFile(
            byteCount: Int64(data.count), for: key, durable: true)
        return destination
    }

    @discardableResult
    func makeOffline(source: Source) async -> Bool {
        guard let sourceID = source.id else { return false }
        guard let estimate = await offlineEstimate(for: source) else { return false }
        let check = offlineDiskCheck(requiredBytes: estimate.totalBytes)
        guard check.allowed else {
            offlineProgress = OfflineProgress(sourceID: sourceID, completed: 0, total: estimate.trackCount, failed: false, message: check.reason)
            return false
        }

        offlineSourceID = sourceID
        offlineProgress = OfflineProgress(sourceID: sourceID, completed: 0, total: estimate.trackCount, failed: false, message: nil)

        var completed = 0
        for track in (try? await store.tracks(forSource: sourceID)) ?? [] {
            guard offlineSourceID == sourceID else { break }
            guard let asset = track.asset, let remoteStr = asset.remoteURL,
                  let remoteURL = URL(string: remoteStr) else { continue }

            // Cache identity stays keyed on the STABLE persisted URL even
            // though the actual fetch below may use a different, freshly
            // re-resolved URL (Dropbox/pCloud issue a new signed link every
            // resolve) — keying on the fresh URL would fragment the cache
            // and defeat the "already downloaded" check on every call.
            let cacheKey = AudioCache.key(for: remoteURL)
            let destURL = AudioCache.fileURL(for: cacheKey)

            if !FileManager.default.fileExists(atPath: destURL.path) {
                if let request = await fetchRequest(for: asset, source: source),
                   let (data, _) = try? await URLSession.shared.data(for: request) {
                    try? FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data.write(to: destURL, options: .atomic)
                    await AudioCache.shared.adoptCompleteFile(byteCount: Int64(data.count), for: cacheKey, durable: true)
                }
            } else if let size = try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? NSNumber {
                await AudioCache.shared.adoptCompleteFile(byteCount: size.int64Value, for: cacheKey, durable: true)
            }
            completed += 1
            offlineProgress = OfflineProgress(sourceID: sourceID, completed: completed, total: estimate.trackCount, failed: false, message: nil)
        }

        offlineSourceID = nil
        return completed > 0
    }

    func cancelOffline() {
        offlineSourceID = nil
        offlineProgress = nil
    }

    @discardableResult
    func download(rows: [TrackRow]) async -> Int {
        var downloaded = 0
        for row in rows {
            guard let asset = row.asset, let remoteStr = asset.remoteURL,
                  let remoteURL = URL(string: remoteStr) else { continue }
            // See makeOffline(source:) above — cache identity is always keyed
            // on the stable persisted URL, never the possibly-fresh re-resolved
            // one.
            let cacheKey = AudioCache.key(for: remoteURL)
            let destURL = AudioCache.fileURL(for: cacheKey)
            activePhoneDownloads.insert(row.id)
            do {
                defer { activePhoneDownloads.remove(row.id) }
                if !FileManager.default.fileExists(atPath: destURL.path) {
                    if let request = await fetchRequest(for: asset, source: row.source),
                       let (data, _) = try? await URLSession.shared.data(for: request) {
                        try? FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data.write(to: destURL, options: .atomic)
                        await AudioCache.shared.adoptCompleteFile(byteCount: Int64(data.count), for: cacheKey, durable: true)
                    }
                } else if let size = try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? NSNumber {
                    await AudioCache.shared.adoptCompleteFile(byteCount: size.int64Value, for: cacheKey, durable: true)
                }
            }
            downloaded += 1
        }
        downloadRevision += 1
        return downloaded
    }

    /// Real bug fix: builds the request to actually fetch `asset`'s bytes,
    /// re-authenticating via the owning provider first when a persisted node
    /// reference exists — see `RemoteAssetRefetch`'s doc for why the plain
    /// persisted `remoteURL`/transient headers alone are not reliable once a
    /// row has been through a DB round trip. `source` may be `nil` (a
    /// `TrackRow` that lost its source join); falls back to the legacy
    /// remoteURL-only behavior in that case, same as when re-resolution fails.
    private func fetchRequest(for asset: Asset, source: Source?) async -> URLRequest? {
        guard let source, let provider = try? remoteProvider(for: source) else {
            return await RemoteAssetRefetch.request(for: asset) { _ in throw URLError(.unknown) }
        }
        return await RemoteAssetRefetch.request(for: asset) { node in
            try await provider.resolve(node: node)
        }
    }

    func phoneDownloadState(for row: TrackRow) -> PhoneDownloadState {
        if activePhoneDownloads.contains(row.id) { return .downloading(nil) }
        guard let asset = row.asset else { return .notDownloaded }
        if asset.kind == .localRef || asset.kind == .managedCopy || asset.kind == .builtIn {
            return .downloaded
        }
        guard asset.kind == .remote,
              let remoteStr = asset.remoteURL,
              let remoteURL = URL(string: remoteStr) else { return .notDownloaded }
        let cacheKey = AudioCache.key(for: remoteURL)
        let metaURL = AudioCache.metaURL(for: cacheKey)
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(SparseCacheStore.Meta.self, from: data) else {
            return .notDownloaded
        }
        if meta.isDurable || meta.complete {
            let destURL = AudioCache.fileURL(for: cacheKey)
            if FileManager.default.fileExists(atPath: destURL.path) {
                return .downloaded
            }
        }
        if meta.cachedBytes > 0 {
            let fraction = meta.totalBytes.map { $0 > 0 ? Double(meta.cachedBytes) / Double($0) : 0.05 } ?? 0.05
            return .downloading(fraction)
        }
        return .notDownloaded
    }

    func removeDownloadFromPhone(rows: [TrackRow]) async {
        for row in rows {
            guard let asset = row.asset, asset.kind == .remote,
                  let remoteStr = asset.remoteURL,
                  let remoteURL = URL(string: remoteStr) else { continue }
            let cacheKey = AudioCache.key(for: remoteURL)
            await AudioCache.shared.setDurable(false, for: cacheKey)
        }
        downloadRevision += 1
    }

    func remoteTrackRows(source: Source, nodes: [RemoteNode]) async throws -> [TrackRow] {
        let provider = try remoteProvider(for: source)
        var rows: [TrackRow] = []
        for (index, node) in nodes.filter({ $0.kind == .audio }).enumerated() {
            let resolved = try await provider.resolve(node: node)
            rows.append(RemoteTrackRowFactory.row(source: source, node: node, resolved: resolved, index: index))
        }
        return rows
    }

    /// Turns an in-memory browsed row into a durable library row while retaining
    /// its transient authorization long enough to pin the bytes.
    func persistRemoteTrack(_ row: TrackRow) async -> TrackRow? {
        guard row.id < 0, let source = row.source, let asset = row.asset,
              let rawURL = asset.remoteURL, let url = URL(string: rawURL) else { return row }
        // Prefer the REAL provider node reference `RemoteTrackRowFactory.row`
        // already attached to this in-memory asset — falling back to the old
        // resolved-URL-as-path placeholder only when it's genuinely absent
        // (this closure ignores `node` for resolution either way, since
        // `resolved` below is already known; what matters is what gets
        // PERSISTED, so a later re-resolve is possible — see
        // `Asset.remoteNodeID`'s doc).
        let node = RemoteNode(id: asset.remoteNodeID ?? "now-playing-\(abs(row.id))",
                              title: row.track.title,
                              path: asset.remoteNodePath ?? rawURL, kind: .audio,
                              sizeBytes: asset.sizeBytes,
                              durationSec: row.track.durationSec)
        let resolved = ResolvedAsset(url: url, headers: asset.transientRemoteHeaders,
                                     supportsByteRanges: asset.transientRemoteSupportsByteRanges,
                                     sizeBytes: asset.sizeBytes)
        let result = await RemotePlaylistIngest.persist(nodes: [node], resolve: { _ in resolved },
                                                        source: source, store: store)
        guard let id = result.trackIDs.first,
              let persisted = try? await store.tracks(forSource: source.id ?? -1).first(where: { $0.id == id })
        else { return nil }
        _ = await download(rows: [row])
        await reload()
        return persisted
    }

    func insertRemoteSource(kind: SourceKind,
                                    title: String,
                                    originalURL: String?,
                                    iaIdentifier: String?,
                                    credential: Data,
                                    credentialAccount: (Int64) -> String) async throws {
        var source = Source(
            id: nil,
            kind: kind,
            iaIdentifier: iaIdentifier,
            originalURL: originalURL,
            title: title,
            addedAt: Date(),
            lastResolvedAt: Date(),
            followUpdates: false,
            licenseText: nil,
            memberCapHit: false
        )
        source = try await store.insertSource(source)
        guard let sourceID = source.id else { return }
        do {
            try CredentialStore().save(credential, account: credentialAccount(sourceID))
        } catch {
            try? await store.deleteSource(id: sourceID)
            throw error
        }
        await reload()
        tab = .settings
    }

    func remoteProvider(for source: Source) throws -> any RemoteLibraryProvider {
        try RemoteLibraryProviderFactory.provider(for: source)
    }

}

private enum DJPlayableAssetError: Error {
    case missingAsset
    case noLocalBytes
    case missingRemoteURL
    case remoteRequestUnavailable
    case remoteRequestFailed(Int)
}
