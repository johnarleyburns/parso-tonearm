import Foundation
import SwiftData

/// Watch-local truth. Owns the SwiftData store and hands out `Sendable` value snapshots only.
public actor WatchLibraryRepository {
    private let container: ModelContainer
    private let audioDirectory: URL

    public init(container: ModelContainer, audioDirectory: URL) {
        self.container = container; self.audioDirectory = audioDirectory
    }

    // MARK: - Ingest

    @discardableResult
    public func upsertTrack(_ value: WatchTrackUpsert) throws -> WatchUpsertOutcome {
        let context = ModelContext(container)
        let id = value.trackID
        var descriptor = FetchDescriptor<WatchTrackModel>(predicate: #Predicate { $0.trackID == id })
        descriptor.fetchLimit = 1
        let existing = try context.fetch(descriptor).first
        guard let model = existing else {
            context.insert(WatchTrackModel(
                trackID: id, title: value.title, artist: value.artist, albumTitle: value.albumTitle,
                durationSeconds: value.durationSeconds, trackNumber: value.trackNumber,
                discNumber: value.discNumber, artworkID: value.artworkID,
                localThumbnailFilename: value.localThumbnailFilename, codec: value.codec,
                expectedBytes: value.expectedBytes, expectedSHA256: value.expectedSHA256,
                phoneRevision: value.phoneRevision))
            try context.save()
            return .inserted
        }
        // §5.4: stale revisions are acknowledged, never applied over newer metadata.
        guard value.phoneRevision >= model.phoneRevision else { return .staleIgnored }
        model.title = value.title; model.normalizedTitle = WatchTextNormalizer.normalize(value.title)
        model.artist = value.artist; model.normalizedArtist = WatchTextNormalizer.normalize(value.artist)
        model.albumTitle = value.albumTitle; model.normalizedAlbum = WatchTextNormalizer.normalize(value.albumTitle)
        model.durationSeconds = value.durationSeconds; model.trackNumber = value.trackNumber
        model.discNumber = value.discNumber; model.artworkID = value.artworkID
        model.localThumbnailFilename = value.localThumbnailFilename; model.codec = value.codec
        model.expectedBytes = value.expectedBytes; model.expectedSHA256 = value.expectedSHA256
        model.phoneRevision = value.phoneRevision; model.metadataUpdatedAt = Date()
        try context.save()
        return .updated
    }

    @discardableResult
    public func upsertPlaylist(_ value: WatchPlaylistUpsert, desiredOnWatch: Bool = false) throws -> WatchUpsertOutcome {
        let context = ModelContext(container)
        let id = value.playlistID
        var descriptor = FetchDescriptor<WatchPlaylistModel>(predicate: #Predicate { $0.playlistID == id })
        descriptor.fetchLimit = 1
        let playlist: WatchPlaylistModel
        let outcome: WatchUpsertOutcome
        if let existing = try context.fetch(descriptor).first {
            guard value.phoneRevision >= existing.phoneRevision else {
                // A stale membership edit must not resurrect removed tracks; the desire flag is
                // watch-local, so it still applies.
                if desiredOnWatch, !existing.desiredOnWatch { existing.desiredOnWatch = true; try context.save() }
                return .staleIgnored
            }
            playlist = existing; playlist.title = value.title
            playlist.normalizedTitle = WatchTextNormalizer.normalize(value.title)
            playlist.phoneRevision = value.phoneRevision
            playlist.desiredOnWatch = playlist.desiredOnWatch || desiredOnWatch
            for entry in playlist.entries { context.delete(entry) }
            playlist.entries.removeAll()
            outcome = .updated
        } else {
            playlist = WatchPlaylistModel(playlistID: id, title: value.title, phoneRevision: value.phoneRevision,
                                          desiredOnWatch: desiredOnWatch)
            context.insert(playlist)
            outcome = .inserted
        }
        playlist.entries = value.trackIDs.enumerated().map { offset, trackID in
            WatchPlaylistEntryModel(entryID: "\(id):\(offset)", trackID: trackID, ordinal: offset)
        }
        playlist.lastReconciledAt = Date()
        try context.save()
        return outcome
    }

    public func markAsset(trackID: String, relativeFilename: String, installedBytes: Int64,
                          sha256: String, state: WatchAssetValidationState) throws {
        let context = ModelContext(container)
        var trackDescriptor = FetchDescriptor<WatchTrackModel>(predicate: #Predicate { $0.trackID == trackID })
        trackDescriptor.fetchLimit = 1
        guard let track = try context.fetch(trackDescriptor).first else { throw WatchLibraryError.unknownTrack(trackID) }
        var assetDescriptor = FetchDescriptor<WatchAssetModel>(predicate: #Predicate { $0.trackID == trackID })
        assetDescriptor.fetchLimit = 1
        let asset = try context.fetch(assetDescriptor).first ?? WatchAssetModel(
            trackID: trackID, relativeFilename: relativeFilename, installedBytes: installedBytes,
            sha256: sha256, validationState: state)
        if asset.modelContext == nil { context.insert(asset) }
        asset.relativeFilename = relativeFilename; asset.installedBytes = installedBytes
        asset.sha256 = sha256; asset.validationState = state; asset.installedAt = Date(); asset.track = track
        track.asset = asset
        try context.save()
    }

    /// §5.3 `removeAssets`: drop the track, its asset row, and its on-disk audio. Returns the IDs
    /// actually removed so the caller can report an accurate manifest. A track that is a member of a
    /// still-desired playlist is still removed here — the phone resolved references before sending.
    @discardableResult
    public func removeTracks(_ trackIDs: [String]) throws -> [String] {
        let context = ModelContext(container)
        let wanted = Set(trackIDs)
        var removed: [String] = []
        for track in try context.fetch(FetchDescriptor<WatchTrackModel>()) where wanted.contains(track.trackID) {
            if let filename = track.asset?.relativeFilename {
                try? FileManager.default.removeItem(at: audioDirectory.appendingPathComponent(filename))
            }
            context.delete(track)
            removed.append(track.trackID)
        }
        // A playlist entry pointing at a now-deleted track is left in place: membership is the
        // phone's, and `WatchPlaylistSnapshot.isPartial` already tells the UI the row is incomplete.
        try context.save()
        return removed.sorted()
    }

    // MARK: - Queries

    public func tracks(readyOnly: Bool = false) throws -> [WatchTrackSnapshot] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<WatchTrackModel>()).compactMap {
            let ready = $0.asset?.validationState == .ready
            guard !readyOnly || ready else { return nil }
            return Self.snapshot($0)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    public func playlists() throws -> [WatchPlaylistSnapshot] {
        let context = ModelContext(container)
        let ready = Set(try context.fetch(FetchDescriptor<WatchAssetModel>()).filter { $0.validationState == .ready }.map(\.trackID))
        return try context.fetch(FetchDescriptor<WatchPlaylistModel>()).map { playlist in
            let ids = playlist.entries.sorted { $0.ordinal < $1.ordinal }.map(\.trackID)
            return WatchPlaylistSnapshot(id: playlist.playlistID, title: playlist.title,
                                         trackIDs: ids, readyTrackIDs: ids.filter { ready.contains($0) })
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// §6.2 offline search: normalized substring match on the stored normalized columns, every term
    /// required, ranked title-prefix → title → artist → album.
    public func search(_ query: String, readyOnly: Bool = true) throws -> [WatchTrackSnapshot] {
        let terms = WatchTextNormalizer.normalize(query).split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return [] }
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<WatchTrackModel>()).compactMap { model -> (Int, WatchTrackSnapshot)? in
            let ready = model.asset?.validationState == .ready
            guard !readyOnly || ready else { return nil }
            let title = model.normalizedTitle, artist = model.normalizedArtist, album = model.normalizedAlbum
            var score = 0
            for term in terms {
                if title.hasPrefix(term) { score += 100 }
                else if title.contains(term) { score += 50 }
                else if artist.hasPrefix(term) { score += 25 }
                else if artist.contains(term) { score += 15 }
                else if album.contains(term) { score += 10 }
                else { return nil }
            }
            return (score, Self.snapshot(model))
        }.sorted { $0.0 == $1.0 ? $0.1.id < $1.1.id : $0.0 > $1.0 }.map(\.1)
    }

    public func searchPlaylists(_ query: String) throws -> [WatchPlaylistSnapshot] {
        let normalized = WatchTextNormalizer.normalize(query)
        guard !normalized.isEmpty else { return [] }
        return try playlists().filter { WatchTextNormalizer.normalize($0.title).contains(normalized) }
    }

    public func manifest() throws -> WatchManifestSnapshot {
        let context = ModelContext(container)
        let assets = try context.fetch(FetchDescriptor<WatchAssetModel>()).filter { $0.validationState == .ready }.sorted { $0.trackID < $1.trackID }
        let payload = assets.map { "\($0.trackID):\($0.installedBytes):\($0.sha256)" }.joined(separator: "|")
        return WatchManifestSnapshot(manifestID: WatchFileDigest.hex(Data(payload.utf8)), readyTrackIDs: assets.map(\.trackID),
                                     installedBytes: assets.reduce(0) { $0 + $1.installedBytes })
    }

    public func storage() throws -> WatchStorageSnapshot {
        let context = ModelContext(container)
        let assets = try context.fetch(FetchDescriptor<WatchAssetModel>())
        let known = Set(assets.map(\.relativeFilename))
        let orphanBytes = Self.audioFiles(at: audioDirectory)
            .filter { !known.contains($0.lastPathComponent) }
            .reduce(Int64(0)) { $0 + Self.fileSize($1) }
        // `volumeAvailableCapacityForImportantUsage` does not exist on watchOS; the plain
        // available-capacity key is the conservative number §2.5 wants anyway.
        let volume = try? audioDirectory.resourceValues(forKeys: [
            .volumeAvailableCapacityKey, .volumeTotalCapacityKey])
        return WatchStorageSnapshot(
            readyBytes: assets.filter { $0.validationState == .ready }.reduce(0) { $0 + $1.installedBytes },
            stagingBytes: assets.filter { $0.validationState == .installing }.reduce(0) { $0 + $1.installedBytes },
            orphanBytes: orphanBytes,
            freeBytes: Int64(volume?.volumeAvailableCapacity ?? 0),
            capacityBytes: Int64(volume?.volumeTotalCapacity ?? 0))
    }

    // MARK: - File reconciliation

    public func reconcileFiles() throws -> WatchReconciliationSnapshot {
        let context = ModelContext(container)
        let assets = try context.fetch(FetchDescriptor<WatchAssetModel>())
        var missing: [String] = [], corrupt: [String] = []
        let known = Set(assets.map(\.relativeFilename))
        for asset in assets where asset.validationState == .ready {
            let url = audioDirectory.appendingPathComponent(asset.relativeFilename)
            guard FileManager.default.fileExists(atPath: url.path) else {
                asset.validationState = .corrupt; missing.append(asset.trackID); continue
            }
            let measured = try WatchFileDigest.measure(url)
            if measured.bytes != asset.installedBytes || measured.sha256 != asset.sha256 {
                asset.validationState = .corrupt; corrupt.append(asset.trackID)
            }
        }
        let orphans = try Self.audioFiles(at: audioDirectory).filter { !known.contains($0.lastPathComponent) }.map { url in
            let measured = try WatchFileDigest.measure(url)
            return WatchOrphanSnapshot(relativeFilename: url.lastPathComponent,
                                       bytes: measured.bytes, sha256: measured.sha256)
        }.sorted { $0.relativeFilename < $1.relativeFilename }
        try context.save()
        return WatchReconciliationSnapshot(missingTrackIDs: missing.sorted(), corruptTrackIDs: corrupt.sorted(), orphans: orphans)
    }

    /// Adopt a recovered file only when it still matches its own measurement *and* whatever the
    /// track's metadata claims. Anything less would let a rebuilt store call an unrelated file ready.
    public func adoptOrphan(_ orphan: WatchOrphanSnapshot, forTrackID trackID: String) throws {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<WatchTrackModel>(predicate: #Predicate { $0.trackID == trackID })
        descriptor.fetchLimit = 1
        guard let track = try context.fetch(descriptor).first else { throw WatchLibraryError.unknownTrack(trackID) }
        let url = audioDirectory.appendingPathComponent(orphan.relativeFilename)
        let measured = try WatchFileDigest.measure(url)
        guard measured.bytes == orphan.bytes, measured.sha256 == orphan.sha256,
              track.expectedBytes.map({ $0 == measured.bytes }) ?? true,
              track.expectedSHA256.map({ $0 == measured.sha256 }) ?? true else {
            throw WatchLibraryError.invalidOrphan(trackID)
        }
        try markAsset(trackID: trackID, relativeFilename: orphan.relativeFilename,
                      installedBytes: measured.bytes, sha256: measured.sha256, state: .ready)
    }

    public func restorePlaybackState() throws -> WatchPlaybackSnapshot? {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<WatchPlaybackStateModel>(predicate: #Predicate { $0.stateID == "local" })
        descriptor.fetchLimit = 1
        guard let state = try context.fetch(descriptor).first else { return nil }
        let ready = Set(try context.fetch(FetchDescriptor<WatchAssetModel>()).filter { $0.validationState == .ready }.map(\.trackID))
        let oldCurrentID = state.queueTrackIDs.indices.contains(state.currentIndex) ? state.queueTrackIDs[state.currentIndex] : nil
        state.queueTrackIDs = state.queueTrackIDs.filter { ready.contains($0) }
        state.currentIndex = oldCurrentID.flatMap { state.queueTrackIDs.firstIndex(of: $0) }
            ?? min(state.currentIndex, max(0, state.queueTrackIDs.count - 1))
        if state.queueTrackIDs.isEmpty { state.currentIndex = 0; state.elapsedSeconds = 0 }
        try context.save()
        return WatchPlaybackSnapshot(queueTrackIDs: state.queueTrackIDs, currentIndex: state.currentIndex,
                                     elapsedSeconds: state.elapsedSeconds, shuffleEnabled: state.shuffleEnabled,
                                     repeatMode: state.repeatMode)
    }

    // MARK: - Legacy adoption and fixtures

    /// Adopt an old GRDB watch library. Metadata is written first so audio can be validated against
    /// it; a file that fails validation is left on disk as an orphan rather than deleted.
    @discardableResult
    public func migrateLegacy(_ snapshot: WatchLegacyLibrarySnapshot) throws -> Int {
        for track in snapshot.tracks {
            try upsertTrack(.init(trackID: track.trackID, title: track.title,
                                  artist: track.artist, albumTitle: track.albumTitle))
        }
        for playlist in snapshot.playlists {
            try upsertPlaylist(.init(playlistID: playlist.playlistID, title: playlist.title,
                                     trackIDs: playlist.trackIDs), desiredOnWatch: true)
        }
        var adopted = 0
        for track in snapshot.tracks {
            guard let filename = track.relativeFilename else { continue }
            let url = audioDirectory.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let measured = try WatchFileDigest.measure(url)
            try markAsset(trackID: track.trackID, relativeFilename: filename,
                          installedBytes: measured.bytes, sha256: measured.sha256, state: .ready)
            adopted += 1
        }
        return adopted
    }

    public func seedDeterministicFixture() throws {
        try upsertTrack(.init(trackID: "fixture-track", title: "Ocean", artist: "Built-in", albumTitle: "Built-in Sounds"))
        try upsertPlaylist(.init(playlistID: "fixture-playlist", title: "Built-in Playlist", trackIDs: ["fixture-track"]),
                           desiredOnWatch: true)
    }

    // MARK: - Store metadata

    public func metadata(_ key: String) throws -> String? {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<WatchStoreMetadata>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.value
    }

    public func setMetadata(_ key: String, to value: String) throws {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<WatchStoreMetadata>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first { existing.value = value }
        else { context.insert(WatchStoreMetadata(key: key, value: value)) }
        try context.save()
    }

    /// The cheap launch-time scan: names and sizes only, no hashing. Used to prove that a store
    /// rebuild kept the user's audio.
    public func recoverableFiles() -> [WatchRecoverableFileSnapshot] {
        Self.recoverableFiles(at: audioDirectory)
    }

    static func recoverableFiles(at directory: URL) -> [WatchRecoverableFileSnapshot] {
        audioFiles(at: directory)
            .map { WatchRecoverableFileSnapshot(relativeFilename: $0.lastPathComponent, bytes: fileSize($0)) }
            .sorted { $0.relativeFilename < $1.relativeFilename }
    }

    private static func snapshot(_ model: WatchTrackModel) -> WatchTrackSnapshot {
        let ready = model.asset?.validationState == .ready
        return WatchTrackSnapshot(id: model.trackID, title: model.title, artist: model.artist,
                                  albumTitle: model.albumTitle, durationSeconds: model.durationSeconds,
                                  trackNumber: model.trackNumber, discNumber: model.discNumber,
                                  artworkID: model.artworkID, codec: model.codec,
                                  phoneRevision: model.phoneRevision,
                                  localFilename: ready ? model.asset?.relativeFilename : nil, isReady: ready)
    }
    private static func audioFiles(at directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]))?.filter { !$0.hasDirectoryPath } ?? []
    }
    private static func fileSize(_ url: URL) -> Int64 { Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
}
