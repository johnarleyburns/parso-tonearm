import Foundation
import TonearmCore

final class WatchSyncHandler {
    static let shared = WatchSyncHandler()

    func setup() {
        let adapter = WatchSessionAdapter.shared
        adapter.activate()
        adapter.onCatalogReceived = { [weak self] catalog in
            self?.handleCatalog(catalog)
        }
        adapter.onAudioReceived = { [weak self] url, metadata in
            self?.handleAudio(url: url, metadata: metadata)
        }
        adapter.onDeleteTracks = { [weak self] keys in
            self?.handleDelete(keys)
        }
    }

    private func handleCatalog(_ catalog: WatchCatalogSnapshot) {
        Task {
            let store = LibraryStore.shared
            _ = try? await WatchCatalog.import(catalog, into: store)
        }
    }

    private func handleAudio(url: URL, metadata: WatchAudioMetadata) {
        Task {
            let store = LibraryStore.shared
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let ext = url.pathExtension
            let destName = "\(metadata.trackKey).\(ext.isEmpty ? "dat" : ext)"
            let destDir = metadata.pinned ? WatchStorage.watchAudioDirName : WatchStorage.cacheDirName
            let destDirURL = appSupport.appendingPathComponent(destDir)
            try? FileManager.default.createDirectory(at: destDirURL, withIntermediateDirectories: true)
            let destURL = destDirURL.appendingPathComponent(destName)
            try? FileManager.default.copyItem(at: url, to: destURL)
            let relPath = "\(destDir)/\(destName)"

            if let track = try? await store.trackBySyncID(metadata.trackKey), let tid = track.id {
                _ = try? await store.dbQueue.write { db in
                    try db.execute(sql: "DELETE FROM asset WHERE trackId = ?", arguments: [tid])
                    var asset = Asset(id: nil, trackId: tid, kind: .managedCopy,
                                      bookmark: nil, relPath: relPath,
                                      remoteURL: nil, altRemoteURL: nil,
                                      sizeBytes: metadata.bytes, unsupportedReason: nil)
                    _ = try asset.insertAndFetch(db)
                }
                _ = try? await store.dbQueue.write { db in
                    var entry = WatchManifestRecord(
                        trackKey: metadata.trackKey,
                        bytes: metadata.bytes,
                        pinned: metadata.pinned,
                        reportedAt: Date())
                    try entry.save(db)
                }
                await MainActor.run { WatchPlayer.shared.cancelFetch() }
            } else {
                let orphansDir = appSupport.appendingPathComponent(WatchStorage.orphansDirName)
                try? FileManager.default.createDirectory(at: orphansDir, withIntermediateDirectories: true)
                let orphanURL = orphansDir.appendingPathComponent(destName)
                try? FileManager.default.moveItem(at: url, to: orphanURL)
            }
        }
    }

    private func handleDelete(_ keys: [String]) {
        Task {
            let store = LibraryStore.shared
            for key in keys {
                if let track = try? await store.trackBySyncID(key), let tid = track.id {
                    try? await store.deleteTrack(id: tid)
                }
                _ = try? await store.dbQueue.write { db in
                    try WatchManifestRecord.deleteOne(db, key: key)
                }
            }
        }
    }
}
