import Foundation
import ParsoAudioStreaming
import SwiftUI
import TonearmCore
import UIKit

extension AppState {
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
            await cacheCompletedDownload(cacheKey: cacheKey, remoteURL: remoteURL, asset: asset, source: source)
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
            activePhoneDownloads.insert(row.id)
            do {
                defer { activePhoneDownloads.remove(row.id) }
                await cacheCompletedDownload(cacheKey: cacheKey, remoteURL: remoteURL, asset: asset, source: row.source)
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

    /// Shared by `makeOffline(source:)` and `download(rows:)`. Two real reports, both from a
    /// track that genuinely couldn't be fetched (an expired Dropbox/pCloud temp link, a revoked
    /// token):
    /// 1. The fetch's HTTP status was never checked, so a 401/403/410 error-page body got
    ///    written to disk and `adoptCompleteFile`'d anyway — a poisoned, permanently "downloaded"
    ///    entry that fails every later play and is never retried.
    /// 2. "Already downloaded, skip the fetch" was decided from bare `FileManager` file
    ///    existence at the cache path, not from whether the entry is actually complete — a track
    ///    mid-stream or mid-prefetch (a genuinely partial blob sitting at that same path,
    ///    `CachingResourceLoader` writes to it incrementally) got adopted as a finished download
    ///    purely because *some* file was there.
    /// `AudioCache.completeCacheExists` is the one check that already tracks real completeness
    /// (`SparseCacheStore`'s own byte-range bookkeeping, not a file-existence guess) — trust it
    /// instead of re-deriving "complete" from whatever happens to be on disk right now.
    private func cacheCompletedDownload(cacheKey: String, remoteURL: URL, asset: Asset, source: Source?) async {
        if AudioCache.completeCacheExists(for: remoteURL) {
            await AudioCache.shared.setDurable(true, for: cacheKey)
            return
        }
        guard let request = await fetchRequest(for: asset, source: source),
              let (data, response) = try? await downloadSession.data(for: request),
              let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode)
        else { return }
        let destURL = AudioCache.fileURL(for: cacheKey)
        try? FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: destURL, options: .atomic)
        await AudioCache.shared.adoptCompleteFile(byteCount: Int64(data.count), for: cacheKey, durable: true)
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
    ///
    /// Real report: re-browsing to and replaying/favoriting the same remote file in quick
    /// succession (e.g. a double-tap, or tapping again before the first attempt's UI feedback
    /// arrives) could create a genuine duplicate track — a second call for the same provider
    /// node could start, read `existingRows`, and insert a new row before the first call's own
    /// insert had committed, so neither one ever saw the other's row. A second call for the same
    /// identity now awaits the first call's own in-flight work instead of racing it.
    func persistRemoteTrack(_ row: TrackRow) async -> TrackRow? {
        guard row.id < 0, let asset = row.asset, let rawURL = asset.remoteURL else { return row }
        let identityKey = "\(row.source?.id ?? -1):\(asset.remoteNodeID ?? rawURL)"
        if let inFlight = pendingRemotePersists[identityKey] {
            return await inFlight.value
        }
        let task = Task { @MainActor [weak self] () -> TrackRow? in
            await self?.performPersistRemoteTrack(row)
        }
        pendingRemotePersists[identityKey] = task
        let result = await task.value
        pendingRemotePersists[identityKey] = nil
        return result
    }

    private func performPersistRemoteTrack(_ row: TrackRow) async -> TrackRow? {
        guard row.id < 0, var source = row.source, let asset = row.asset,
              let rawURL = asset.remoteURL, let url = URL(string: rawURL) else { return row }
        // Ad-hoc Jamendo browsing uses a synthetic source. Persist/reuse it
        // before ingest: RemotePlaylistIngest cannot save tracks without a source ID.
        if source.id == nil {
            if let existing = (try? await store.allSources())?.first(where: {
                $0.kind == source.kind && $0.iaIdentifier == source.iaIdentifier && $0.originalURL == source.originalURL
            }) {
                source = existing
            } else {
                guard let inserted = try? await store.insertSource(source) else { return nil }
                source = inserted
            }
        }
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
                              durationSec: row.track.durationSec,
                              contentType: asset.remoteContentType)
        let resolved = ResolvedAsset(url: url, headers: asset.transientRemoteHeaders,
                                     supportsByteRanges: asset.transientRemoteSupportsByteRanges,
                                     sizeBytes: asset.sizeBytes)
        let result = await RemotePlaylistIngest.persist(nodes: [node], resolve: { _ in resolved },
                                                        source: source, store: store)
        guard let id = result.trackIDs.first,
              var persisted = try? await store.tracks(forSource: source.id ?? -1).first(where: { $0.id == id })
        else { return nil }
        // Real report: a track played fine straight from browsing but then failed to actually
        // play — the re-fetched `persisted` row's `Asset.transientRemoteHeaders`/
        // `transientRemoteSupportsByteRanges` reset to empty/default, because those fields are
        // deliberately NOT persisted columns (confirmed by `RemotePlaylistIngestTests`'s own
        // "transient credentials" assertion) — this function's own doc comment says it retains
        // "its transient authorization long enough to pin the bytes," but the DB round-trip above
        // silently threw that authorization away for whoever plays the RETURNED row (every
        // `playRemote`/`toggleFavorite` caller). Carry the original, just-resolved row's transient
        // fields forward onto the durable one.
        if var persistedAsset = persisted.asset {
            persistedAsset.transientRemoteHeaders = asset.transientRemoteHeaders
            persistedAsset.transientRemoteSupportsByteRanges = asset.transientRemoteSupportsByteRanges
            persisted.asset = persistedAsset
        }
        _ = await download(rows: [row])
        await reload()
        return persisted
    }

    /// Persist one ad-hoc Jamendo result into a durable library source, cache
    /// its bytes for immediate DJ use, and queue its full analysis.
    @discardableResult
    func importJamendoTrack(node: RemoteNode) async -> Bool {
        guard node.kind == .audio else { return false }
        let source: Source
        if let existing = (try? await store.allSources())?.first(where: {
            $0.kind == .jamendoGenre && $0.iaIdentifier == JamendoImportPolicy.sourceIdentifier
        }) {
            source = existing
        } else {
            guard let inserted = try? await store.insertSource(Source(
                id: nil, kind: .jamendoGenre, iaIdentifier: JamendoImportPolicy.sourceIdentifier,
                originalURL: nil, title: JamendoImportPolicy.sourceTitle, addedAt: Date(),
                lastResolvedAt: Date(), followUpdates: false,
                licenseText: "Creative Commons — attribution kept", memberCapHit: false
            )) else { return false }
            source = inserted
        }

        let provider = JamendoGenreProvider(clientID: JamendoAppConfig.clientID)
        let result = await RemotePlaylistIngest.persist(
            nodes: [node], resolve: { try await provider.resolve(node: $0) },
            source: source, store: store)
        guard let trackID = result.trackIDs.first,
              let row = try? await store.tracks(forSource: source.id ?? -1)
                .first(where: { $0.id == trackID }) else { return false }

        _ = await download(rows: [row])
        await DiscoveryRuntimeController.shared.analyzeTrack(trackID)
        await reload()
        return true
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
        tab = .myMusic
    }

    func remoteProvider(for source: Source) throws -> any RemoteLibraryProvider {
        try RemoteLibraryProviderFactory.provider(for: source)
    }

    /// Re-resolves a persisted remote track's stream URL/auth headers fresh from its provider
    /// right before playback, instead of trusting whatever was loaded from the database.
    ///
    /// Real report: a favorited Google Drive/Dropbox track played fine once, then stopped
    /// playing entirely. Root cause: `Asset.transientRemoteHeaders`/
    /// `transientRemoteSupportsByteRanges` are deliberately NOT persisted (confirmed by
    /// `RemotePlaylistIngestTests`'s own "transient credentials" assertion) — they're only ever
    /// correct in the exact in-memory session that first resolved them. Google Drive/OneDrive/
    /// Box's URLs are direct, bearer-auth-required links (no header survives a relaunch); Dropbox/
    /// pCloud's stored `remoteURL` is itself a temp link that expires after a few hours
    /// regardless of headers. Jamendo already has its own dedicated re-resolution path
    /// (`JamendoLocatorResolver`); this gives every other remote provider the same safety net at
    /// the one call site most real plays go through (`TrackDetailCard`'s Play Now/Play Next/Add
    /// to Queue — Favorites, Jump Back In, Mood results, Top 10 all route through it per its own
    /// doc comment). Falls back to the row completely unchanged on any failure — this can only
    /// ever help, never make a play attempt worse than it already was.
    ///
    /// Skips re-resolving entirely when the track is already fully cached under its EXISTING
    /// URL: Dropbox/pCloud/Yandex's resolved URL is a fresh, differently-signed temp link on
    /// every single call (confirmed from `CloudDriveAPI`'s own per-provider resolve behavior) —
    /// overwriting `asset.remoteURL` before checking the cache would change
    /// `AudioCache.key(for:)`'s hash input, making an already-downloaded file's cache key no
    /// longer match and silently breaking playback that worked fine before this function
    /// existed. A genuinely complete local file needs no network/URL at all.
    func freshenedForPlayback(_ row: TrackRow) async -> TrackRow {
        guard let asset = row.asset, asset.kind == .remote,
              let source = row.source, source.kind != .jamendoGenre,
              let nodeID = asset.remoteNodeID, !nodeID.isEmpty
        else { return row }
        if let existingURLString = asset.remoteURL, let existingURL = URL(string: existingURLString),
           AudioCache.completeCacheExists(for: existingURL),
           FileManager.default.fileExists(atPath: AudioCache.fileURL(for: AudioCache.key(for: existingURL)).path) {
            return row
        }
        guard let provider = try? remoteProvider(for: source) else { return row }
        let node = RemoteNode(id: nodeID, title: row.track.title,
                              path: asset.remoteNodePath ?? nodeID, kind: .audio,
                              sizeBytes: asset.sizeBytes, durationSec: row.track.durationSec)
        guard let resolved = try? await provider.resolve(node: node) else { return row }
        var freshAsset = asset
        freshAsset.remoteURL = resolved.url.absoluteString
        freshAsset.transientRemoteHeaders = resolved.headers
        freshAsset.transientRemoteSupportsByteRanges = resolved.supportsByteRanges
        var freshRow = row
        freshRow.asset = freshAsset
        return freshRow
    }

    /// `freshenedForPlayback(_:)`, applied to just the row a multi-track queue is about to start
    /// on — the one `AudioPlayer` loads immediately, where a stale URL/missing header would be
    /// felt as "nothing happens" right now. Tracks later in the queue aren't freshened here (that
    /// needs re-resolution woven into `AudioPlayer`'s own track-advance path, not done yet); this
    /// unblocks the immediate, most common case — tapping a track/album/"Play all" — cheaply.
    func freshenedQueueStart(_ rows: [TrackRow], startAt: Int) async -> [TrackRow] {
        guard rows.indices.contains(startAt) else { return rows }
        var updated = rows
        updated[startAt] = await freshenedForPlayback(rows[startAt])
        return updated
    }

}
