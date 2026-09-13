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
            guard let remoteStr = track.asset?.remoteURL,
                  let remoteURL = URL(string: remoteStr) else { continue }

            let cacheKey = AudioCache.key(for: remoteURL)
            let destURL = AudioCache.fileURL(for: cacheKey)

            if !FileManager.default.fileExists(atPath: destURL.path) {
                var request = URLRequest(url: remoteURL)
                if let headers = track.asset?.transientRemoteHeaders {
                    for (key, value) in headers {
                        request.setValue(value, forHTTPHeaderField: key)
                    }
                }
                if let (data, _) = try? await URLSession.shared.data(for: request) {
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
            guard let remoteStr = row.asset?.remoteURL,
                  let remoteURL = URL(string: remoteStr) else { continue }
            let cacheKey = AudioCache.key(for: remoteURL)
            let destURL = AudioCache.fileURL(for: cacheKey)
            activePhoneDownloads.insert(row.id)
            do {
                defer { activePhoneDownloads.remove(row.id) }
                if !FileManager.default.fileExists(atPath: destURL.path) {
                    var request = URLRequest(url: remoteURL)
                    if let headers = row.asset?.transientRemoteHeaders {
                        for (key, value) in headers {
                            request.setValue(value, forHTTPHeaderField: key)
                        }
                    }
                    if let (data, _) = try? await URLSession.shared.data(for: request) {
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
        let node = RemoteNode(id: "now-playing-\(abs(row.id))", title: row.track.title,
                              path: rawURL, kind: .audio, sizeBytes: asset.sizeBytes,
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
        tab = .sources
    }

    func remoteProvider(for source: Source) throws -> any RemoteLibraryProvider {
        try RemoteLibraryProviderFactory.provider(for: source)
    }

}
