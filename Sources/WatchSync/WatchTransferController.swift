import Foundation

public protocol WatchTransferFileProvider {
    func localFileURL(for trackKey: String) async -> URL?
    func downloadRemoteFile(for trackKey: String) async -> URL?
    func fileSize(for trackKey: String) -> Int64?
}

public protocol WatchSessionWriter {
    func transferFile(_ url: URL, metadata: WatchAudioMetadata) async throws
    func sendUserInfo(_ info: [String: Any]) async throws
    func sendCatalog(_ snapshot: WatchCatalogSnapshot) async throws
}

public actor WatchTransferController {
    private let store: LibraryStore
    private var queue: WatchTransferQueue
    private var currentItems: [WatchTransferItem] = []
    private let fileProvider: WatchTransferFileProvider

    public init(store: LibraryStore, fileProvider: WatchTransferFileProvider) {
        self.store = store
        self.queue = WatchTransferQueue()
        self.fileProvider = fileProvider
    }

    public func enqueue(keys: [String], origin: WatchTransferOrigin = .single,
                        originId: Int64? = nil) async {
        let plan = WatchTransferPlanner.plan(
            desiredKeys: Set(keys),
            manifestOnWatch: await manifestKeySet(),
            currentItems: currentItems)
        for e in plan.toEnqueue {
            queue.enqueue(key: e.key, originKind: e.origin, originId: e.originId)
        }
        for key in plan.toRetry {
            if queue.retry(key: key),
               let idx = currentItems.firstIndex(where: { $0.trackKey == key }) {
                var item = currentItems[idx]
                item.state = .queued
                item.errorText = nil
                currentItems[idx] = item
            }
        }
        await persistItems()
        if queue.state == .idle { queue.start() }
    }

    public func enqueuePlaylistTracks(playlistID: Int64) async {
        guard let items = try? await store.playlistItems(playlistId: playlistID) else { return }
        let keys = items.compactMap { $0.track.id }.map { WatchCatalog.key(for: $0) }
        await enqueue(keys: keys, origin: .playlist, originId: playlistID)
    }

    public func enqueueSourceTracks(sourceID: Int64) async {
        guard let tracks = try? await store.tracks(forSource: sourceID) else { return }
        let keys = tracks.compactMap { $0.track.id }.map { WatchCatalog.key(for: $0) }
        await enqueue(keys: keys, origin: .single, originId: sourceID)
    }

    public func retry(trackKey: String) async {
        if queue.retry(key: trackKey), queue.state == .idle { queue.start() }
        await persistItems()
    }

    public func cancel(trackKey: String) async {
        queue.cancel(key: trackKey)
        await persistItems()
    }

    public func pause() { queue.pause() }
    public func resume() { queue.start() }

    public func tick(sessionWriter: WatchSessionWriter) async {
        guard queue.state == .running else { return }
        let candidates = queue.nextCandidates()
        for key in candidates {
            _ = queue.markSending(key: key)

            let localURL = await fileProvider.localFileURL(for: key)
            let downloadURL = await fileProvider.downloadRemoteFile(for: key)
            guard let fileURL = localURL ?? downloadURL else {
                queue.markFailed(key: key, error: "No file available")
                await syncCurrentItems()
                continue
            }

            let size = fileProvider.fileSize(for: key) ?? 0
            let metadata = WatchAudioMetadata(trackKey: key, bytes: size,
                                              pinned: true, catalogVersion: 1)
            do {
                try await sessionWriter.transferFile(fileURL, metadata: metadata)
                _ = queue.markSent(key: key, bytes: size)
            } catch {
                queue.markFailed(key: key, error: error.localizedDescription)
            }
            await syncCurrentItems()
        }
    }

    public func ingestManifest(_ entries: [WatchManifestRecord]) async {
        try? await store.dbQueue.write { db in
            try WatchManifestRecord.deleteAll(db)
            for var entry in entries {
                try entry.insert(db)
            }
        }
    }

    public func manifestKeySet() async -> Set<String> {
        let records = (try? await store.dbQueue.read { db in
            try WatchManifestRecord.fetchAll(db)
        }) ?? []
        return Set(records.map { $0.trackKey })
    }

    public func manifestStats() async -> (trackCount: Int, bytes: Int64) {
        let records = (try? await store.dbQueue.read { db in
            try WatchManifestRecord.fetchAll(db)
        }) ?? []
        let bytes = records.reduce(0) { $0 + $1.bytes }
        return (records.count, bytes)
    }

    public func transferStats() -> WatchSessionSnapshot {
        let active = queue.activeCount
        let failed = queue.failedKeys.count
        return WatchSessionSnapshot(
            state: .reachable,
            transferQueueCount: active,
            transferFailedCount: failed)
    }

    public func removeAllFromWatch() async {
        queue.cancelAllActive()
        currentItems.removeAll()
        _ = try? await store.dbQueue.write { db in
            try WatchManifestRecord.deleteAll(db)
        }
    }

    public func removeKeysFromWatch(_ keys: [String]) async {
        for key in keys {
            queue.cancel(key: key)
            currentItems.removeAll { $0.trackKey == key }
        }
        _ = try? await store.dbQueue.write { db in
            for key in keys {
                try? WatchManifestRecord.deleteOne(db, key: key)
            }
        }
    }

    private func syncCurrentItems() async {
        currentItems = queue.items
        await persistItems()
    }

    private func persistItems() async {
        currentItems = queue.items
        let items = currentItems
        try? await store.dbQueue.write { db in
            try WatchTransferRecord.deleteAll(db)
            for item in items where item.state != .sent {
                var record = WatchTransferRecord(
                    trackId: 0,
                    state: item.state.rawValue,
                    originKind: item.originKind.rawValue,
                    originId: item.originId)
                if let b = item.bytes { record.bytes = b }
                if let err = item.errorText { record.errorText = err }
                try record.insert(db)
            }
        }
    }
}
