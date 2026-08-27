import Foundation
import TonearmWatchLegacyCore
import TonearmWatchProtocol

final class WatchSyncHandler: @unchecked Sendable {
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
            try? await LegacyWatchLibraryStore.shared.importCatalog(catalog)
        }
    }

    private func handleAudio(url: URL, metadata: WatchAudioMetadata) {
        Task {
            let store = LegacyWatchLibraryStore.shared
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let ext = url.pathExtension
            let destName = "\(metadata.trackKey).\(ext.isEmpty ? "dat" : ext)"
            let destDir = metadata.pinned ? WatchStorage.watchAudioDirName : WatchStorage.cacheDirName
            let destDirURL = appSupport.appendingPathComponent(destDir)
            try? FileManager.default.createDirectory(at: destDirURL, withIntermediateDirectories: true)
            let destURL = destDirURL.appendingPathComponent(destName)
            if FileManager.default.fileExists(atPath: destURL.path) {
                try? FileManager.default.removeItem(at: destURL)
            }
            try? FileManager.default.copyItem(at: url, to: destURL)
            let relPath = "\(destDir)/\(destName)"

            if (try? await store.installAudio(key: metadata.trackKey, relativePath: relPath, metadata: metadata)) == true {
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
            let store = LegacyWatchLibraryStore.shared
            for key in keys {
                try? await store.deleteTrack(key: key)
                try? await store.removeManifest(keys: [key])
            }
        }
    }
}
