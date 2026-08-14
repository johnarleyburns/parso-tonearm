import Foundation
import AVFoundation
import CryptoKit
import GRDB
import TonearmCore

public enum DJImportError: LocalizedError {
    case failedToCreateBookmark
    case failedToInsertFolder
    case noAudioFiles

    public var errorDescription: String? {
        switch self {
        case .failedToCreateBookmark: return "Could not secure access to the folder"
        case .failedToInsertFolder: return "Could not register the folder in the library"
        case .noAudioFiles: return "No audio files found in this folder"
        }
    }
}

/// The §37.3 journal's DB-side failure (plan 5.11). Small and internal — the
/// journal's file-side failures are `RecordingService`'s, not the store's.
public enum RecordingJournalError: LocalizedError {
    case missingMixID

    public var errorDescription: String? {
        switch self {
        case .missingMixID: return "The recording journal row did not receive an id."
        }
    }
}

public struct ImportSummary: Sendable, Equatable {
    public let added: Int
    public let updated: Int
    public let skipped: Int
    public let failed: [URL]

    public init(added: Int = 0, updated: Int = 0, skipped: Int = 0, failed: [URL] = []) {
        self.added = added
        self.updated = updated
        self.skipped = skipped
        self.failed = failed
    }

    public func adding(_ other: ImportSummary) -> ImportSummary {
        ImportSummary(added: added + other.added,
                      updated: updated + other.updated,
                      skipped: skipped + other.skipped,
                      failed: failed + other.failed)
    }
}

/// The single writer to the DJ database (§10.1, §18.4). Writes are serialized by
/// the actor; every import is one GRDB transaction so a crash leaves either the
/// whole folder imported or none (NFR-REL-1). Reads use GRDB's own concurrency,
/// and reactive listings go through `DJTrackRepository`.
public actor DJLibraryStore {
    public static let shared: DJLibraryStore = try! DJLibraryStore()

    public nonisolated let pool: DatabasePool
    private let repository: DJTrackRepository

    public init(pool: DatabasePool) {
        self.pool = pool
        repository = DJTrackRepository(pool: pool)
    }

    public init(path: URL) throws {
        let openedPool = try DJDatabase.open(at: path)
        pool = openedPool
        repository = DJTrackRepository(pool: openedPool)
    }

    public init() throws {
        let openedPool = try DJDatabase.open(at: DJDatabase.defaultDatabaseURL())
        pool = openedPool
        repository = DJTrackRepository(pool: openedPool)
    }

    // MARK: - Tracks & folders

    public func tracks(matching query: LibraryQuery) throws -> [DJTrackRow] {
        try repository.tracks(matching: query)
    }

    public func trackCount() throws -> Int {
        try repository.trackCount()
    }

    public func folders() throws -> [DJFolder] {
        try pool.read { db in
            try DJFolder.order(Column("addedAt")).fetchAll(db)
        }
    }

    // MARK: - Grid corrections (§14.3, FR-ANL-5, §23.3)

    /// The stored grid corrections for a track, in replay order (`appliedAt`,
    /// then `id`) — the deterministic log §23.3 replays over the detected grid.
    public func gridCorrections(trackID: Int64) throws -> [GridCorrection] {
        try pool.read { db in
            try GridCorrection
                .filter(Column("trackID") == trackID)
                .order(Column("appliedAt"), Column("id"))
                .fetchAll(db)
        }
    }

    /// Append one grid correction to the authoritative override log (FR-ANL-5,
    /// FR-PREP-5). The detected analysis is never touched — the correction
    /// replays over it (§23.3). Returns the persisted row.
    @discardableResult
    public func appendGridCorrection(trackID: Int64,
                                     op: GridCorrectionOp,
                                     valueDouble: Double? = nil,
                                     valueInt: Int64? = nil) throws -> GridCorrection {
        var correction = GridCorrection(syncID: UUID().uuidString,
                                        trackID: trackID,
                                        op: op.rawValue,
                                        valueDouble: valueDouble,
                                        valueInt: valueInt,
                                        appliedAt: Date())
        try pool.write { db in
            try correction.insert(db)
        }
        return correction
    }

    /// Pop the newest grid correction for a track — the prep surface's "undo"
    /// (FR-PREP-5's correction undo). Because the log replays over the detected
    /// grid, removing an entry restores exactly the prior authoritative grid.
    @discardableResult
    public func undoLastGridCorrection(trackID: Int64) throws -> GridCorrection? {
        try pool.write { db in
            guard let newest = try GridCorrection
                .filter(Column("trackID") == trackID)
                .order(Column("appliedAt").desc, Column("id").desc)
                .fetchOne(db) else { return nil }
            try newest.delete(db)
            return newest
        }
    }

    /// Reactive track listing (§18.3). Non-isolated because it touches only the
    /// immutable, Sendable `repository`.
    public nonisolated func observeTracks(_ query: LibraryQuery) -> AsyncStream<[DJTrackRow]> {
        repository.observeAll(query)
    }

    // MARK: - Analysis artifacts (§19.4, §10.1 façade)

    /// Replace a track's `phrase` rows — DELETE-then-INSERT in one transaction,
    /// so re-analysis is idempotent per (track, version) and never appends
    /// (§19.4 rule 2).
    public func savePhrases(_ phrases: [Phrase], for trackID: Int64) throws {
        try pool.write { db in
            try AnalysisArtifacts.writePhrases(phrases, trackID: trackID, db: db)
        }
    }

    /// Replace the detected `beat_grid` header + `beat_blob` — real
    /// `firstBeatSample`/`beatCount`, never placeholders (§19.4).
    public func saveBeatGrid(_ grid: BeatGrid, for trackID: Int64) throws {
        try pool.write { db in
            try AnalysisArtifacts.writeBeatGrid(grid, trackID: trackID,
                                                db: db, updatedAt: Date())
        }
    }

    /// Replace a track's `downbeat` rows (§19.4).
    public func saveDownbeats(_ downbeats: [Int], beatGrid: BeatGrid,
                              for trackID: Int64) throws {
        try pool.write { db in
            try AnalysisArtifacts.writeDownbeats(downbeats, beatGrid: beatGrid,
                                                 trackID: trackID, db: db)
        }
    }

    /// Replace the band-split waveform pyramid BLOB (§19.4).
    public func saveWaveform(_ pyramid: WaveformPyramid, for trackID: Int64) throws {
        try pool.write { db in
            try AnalysisArtifacts.writeWaveform(pyramid, trackID: trackID, db: db)
        }
    }

    /// Replace the per-beat energy curve BLOB (§19.4).
    public func saveEnergyCurve(_ curve: [Float], hopSeconds: Double,
                                for trackID: Int64) throws {
        try pool.write { db in
            try AnalysisArtifacts.writeEnergyCurve(curve, hopSeconds: hopSeconds,
                                                   trackID: trackID, db: db)
        }
    }

    // MARK: - Analysis artifact reads (§19.4 — the `WaveformRepository` seam)

    /// The track's stored phrases in beat order — the ribbon's spans and bar
    /// counts (§26A.4). Empty when the track has not been analysed.
    public func phrases(trackID: Int64) throws -> [Phrase] {
        try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT startSample, endSample, startBeat, lengthBeats, type, energy, confidence
                FROM phrase WHERE trackID = ? ORDER BY startBeat, id
                """, arguments: [trackID]).map { row in
                Phrase(startSample: row["startSample"] as? Int64 ?? 0,
                       endSample: row["endSample"] as? Int64 ?? 0,
                       startBeat: Int(row["startBeat"] as? Int64 ?? 0),
                       lengthBeats: Int(row["lengthBeats"] as? Int64 ?? 0),
                       type: PhraseType(rawValue: row["type"] as? String ?? "") ?? .build,
                       energy: Float(row["energy"] as? Double ?? 0),
                       confidence: row["confidence"] as? Double ?? 0)
            }
        }
    }

    /// The detected beat grid (header + decoded `beat_blob`). `nil` when the
    /// track has no grid. Corrections are NOT composed here — the read side
    /// replays `grid_correction` over this (§23.3, §19.4 rule 3).
    public func beatGrid(trackID: Int64) throws -> BeatGrid? {
        try pool.read { db in
            guard let header = try Row.fetchOne(db, sql: """
                SELECT bpm, firstBeatSample, isConstantTempo
                FROM beat_grid WHERE trackID = ?
                """, arguments: [trackID]) else { return nil }
            let bpm = header["bpm"] as? Double ?? 0
            let firstBeat = header["firstBeatSample"] as? Int64 ?? 0
            let constant = (header["isConstantTempo"] as? Int64 ?? 1) != 0
            var samples: [Int64] = []
            var confidence: [Float] = []
            if let blob = try Data.fetchOne(db, sql: """
                SELECT blob FROM beat_blob WHERE trackID = ?
                """, arguments: [trackID]),
               let decoded = try? AnalysisBlobLayouts.decodeBeatBlob(blob) {
                samples = decoded.samples
                confidence = decoded.confidence
            }
            return BeatGrid(firstBeatSample: firstBeat, bpm: bpm,
                            beatSamples: samples, confidence: confidence,
                            isConstantTempo: constant)
        }
    }

    /// The track's bar-start rows, in beat order (§19.4).
    public func downbeats(trackID: Int64) throws -> [DownbeatRecord] {
        try pool.read { db in
            try DownbeatRecord.fetchAll(db, sql: """
                SELECT beatIndex, samplePosition, barNumber, confidence
                FROM downbeat WHERE trackID = ? ORDER BY beatIndex
                """, arguments: [trackID])
        }
    }

    /// The decoded band-split waveform pyramid, or `nil` for an unanalysed
    /// track (§26A.1 — an honest empty state, never synthetic geometry).
    public func waveformPyramid(trackID: Int64) throws -> WaveformPyramid? {
        try pool.read { db in
            guard let blob = try Data.fetchOne(db, sql: """
                SELECT blob FROM waveform_pyramid WHERE trackID = ?
                """, arguments: [trackID]) else { return nil }
            let decoded = try AnalysisBlobLayouts.decodeWaveformPyramid(blob)
            return WaveformPyramid(levels: decoded.levels,
                                   sampleRate: decoded.sampleRate,
                                   baseSamplesPerBin: decoded.baseSamplesPerBin)
        }
    }

    /// The decoded per-beat energy curve, or `nil` for an unanalysed track.
    public func energyCurve(trackID: Int64) throws -> EnergyCurve? {
        try pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT resolution, blob FROM energy_curve WHERE trackID = ?
                """, arguments: [trackID]),
                  let blob = row["blob"] as? Data else { return nil }
            let decoded = try AnalysisBlobLayouts.decodeEnergyCurve(blob)
            return EnergyCurve(resolution: row["resolution"] as? String ?? "beat",
                               values: decoded.values,
                               hopSeconds: decoded.hopSeconds)
        }
    }

    // MARK: - Recording journal (§37.3, NFR-REL-2; plan 5.11)

    /// Open the §37.3 recording journal: the `mix` row **in-progress**
    /// (`localState = "recording"`) plus its `mix_asset` row, in one transaction
    /// (NFR-REL-1). `localRelPath` is the eventual joined M4A relative to
    /// `DJDatabase.mixesDirectory` (e.g. `<sessionUUID>/mix.m4a`). Returns the
    /// `mix` row's id — the handle `finalize`/`reconcile` update.
    @discardableResult
    public func beginRecordingMix(syncID: String,
                                  title: String,
                                  format: String,
                                  bitrateKbps: Int?,
                                  localRelPath: String,
                                  recordedAt: Date) throws -> Int64 {
        try pool.write { db in
            var mix = DJMix(syncID: syncID,
                            title: title,
                            durationSec: 0,
                            trackCount: 0,
                            format: format,
                            bitrateKbps: bitrateKbps,
                            recordedAt: recordedAt,
                            localState: MixLocalState.recording.rawValue)
            try mix.insert(db)
            guard let mixID = mix.id else {
                throw RecordingJournalError.missingMixID
            }
            var asset = DJMixAsset(mixID: mixID,
                                   localRelPath: localRelPath,
                                   totalBytes: 0)
            try asset.insert(db)
            return mixID
        }
    }

    /// Promote a journal `recording` row to `complete` with the finished mix's
    /// real header + the asset's real size, in one transaction (§37.5 step 1).
    public func finalizeRecordingMix(mixID: Int64,
                                     durationSec: Double,
                                     sizeBytes: Int64,
                                     trackCount: Int) throws {
        try pool.write { db in
            guard var mix = try DJMix.fetchOne(db, key: mixID) else { return }
            mix.localState = MixLocalState.complete.rawValue
            mix.durationSec = durationSec
            mix.sizeBytes = sizeBytes
            mix.trackCount = trackCount
            try mix.update(db)
            if var asset = try DJMixAsset.fetchOne(db, key: mixID) {
                asset.totalBytes = sizeBytes
                try asset.update(db)
            }
        }
    }

    /// Mark a journal row `corrupt` — the recording could not be salvaged
    /// (nothing recoverable on disk, or the join failed). Honest, never a
    /// silently-dropped row (§37.3, §46.2's no-silent-fallback rule).
    public func markRecordingMixCorrupt(mixID: Int64) throws {
        try pool.write { db in
            guard var mix = try DJMix.fetchOne(db, key: mixID) else { return }
            mix.localState = MixLocalState.corrupt.rawValue
            try mix.update(db)
        }
    }

    /// Every journal row still marked `recording` — a crash or interrupted
    /// stop left them in-flight. `reconcile()`'s input (§37.3).
    public func staleRecordingMixes() throws -> [DJMix] {
        try pool.read { db in
            try DJMix
                .filter(Column("localState") == MixLocalState.recording.rawValue)
                .order(Column("recordedAt"))
                .fetchAll(db)
        }
    }

    /// A mix's asset row — `reconcile` resolves the session directory from it.
    public func mixAsset(mixID: Int64) throws -> DJMixAsset? {
        try pool.read { db in
            try DJMixAsset.fetchOne(db, key: mixID)
        }
    }

    /// A mix row by id — the post-`finalize`/`reconcile` read (the journal's
    /// finished state, for the Mixes view and the tests).
    public func mix(mixID: Int64) throws -> DJMix? {
        try pool.read { db in
            try DJMix.fetchOne(db, key: mixID)
        }
    }

    // MARK: - Folder import

    /// Imports a music folder by reference (§13.1, FR-LIB-1): a security-scoped
    /// bookmark is stored, files are scanned and hashed, and `folder`/`track`/
    /// `artist`/`album`/`asset`/`import_event` rows are written in one
    /// transaction. Re-importing the same folder skips files that are already
    /// tracked (keyed by folder + relative path), so folder-watch rescans never
    /// duplicate (FR-LIB-2).
    public func importFolder(_ folderURL: URL, includeSubfolders: Bool = true,
                             watch: Bool = true) async throws -> ImportSummary {
        guard let bookmark = BookmarkVault.makeBookmark(for: folderURL) else {
            throw DJImportError.failedToCreateBookmark
        }
        let scanned = IngestService().scanFolder(folderURL, includeSubfolders: includeSubfolders)
        guard !scanned.isEmpty else { throw DJImportError.noAudioFiles }

        var collected: [FolderEntry] = []
        collected.reserveCapacity(scanned.count)
        for file in scanned {
            let metadata = await extractMetadata(file.url)
            collected.append(FolderEntry(url: file.url,
                                         relPath: Self.relPath(file.url, relativeTo: folderURL),
                                         metadata: metadata,
                                         contentHash: Self.sha256(of: file.url),
                                         bookmark: BookmarkVault.makeBookmark(for: file.url),
                                         sizeBytes: Self.fileSize(of: file.url),
                                         fileModifiedAt: Self.modificationDate(of: file.url)))
        }
        let entries = collected

        return try await pool.write { db in
            let folder = try Self.upsertFolder(in: db, folderURL: folderURL,
                                               bookmark: bookmark, watch: watch)
            guard let folderID = folder.id else { throw DJImportError.failedToInsertFolder }
            var summary = ImportSummary()
            for entry in entries {
                summary = summary.adding(try Self.importEntry(entry, folderID: folderID, in: db))
            }
            return summary
        }
    }

    // MARK: - Metadata

    /// AVFoundation common-metadata with filename fallback, mirroring
    /// `IngestService` (FR-LIB-3). Never throws: an unreadable file still
    /// imports by filename. A local `Sendable` shape so the whole folder
    /// import can run through one `DatabasePool.write` transaction.
    private struct ImportMetadata: Sendable {
        var title: String?
        var artist: String?
        var albumTitle: String?
        var albumArtist: String?
        var durationSec: Double?
    }

    private func extractMetadata(_ url: URL) async -> ImportMetadata {
        let asset = AVURLAsset(url: url)
        var meta = ImportMetadata()
        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                guard let value = try? await item.load(.stringValue), !value.isEmpty else { continue }
                if item.commonKey == .commonKeyTitle, meta.title == nil {
                    meta.title = value
                } else if item.commonKey == .commonKeyArtist, meta.artist == nil {
                    meta.artist = value
                } else if item.commonKey == .commonKeyAlbumName, meta.albumTitle == nil {
                    meta.albumTitle = value
                }
            }
        }
        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds > 0 { meta.durationSec = seconds }
        }
        return meta
    }

    // MARK: - Import transaction (pure DB work)

    private struct FolderEntry: Sendable {
        let url: URL
        let relPath: String
        let metadata: ImportMetadata
        let contentHash: String?
        let bookmark: Data?
        let sizeBytes: Int64?
        let fileModifiedAt: Date?
    }

    private static func upsertFolder(in db: Database, folderURL: URL,
                                     bookmark: Data, watch: Bool) throws -> DJFolder {
        let standardizedPath = folderURL.standardizedFileURL.path
        let now = Date()
        if let existing = try DJFolder.filter(Column("displayPath") == standardizedPath).fetchOne(db) {
            var updated = existing
            updated.watching = watch
            updated.bookmark = bookmark
            updated.lastScanAt = now
            try updated.update(db)
            return updated
        }
        var folder = DJFolder(syncID: UUID().uuidString,
                              displayPath: standardizedPath,
                              bookmark: bookmark,
                              watching: watch,
                              addedAt: now,
                              lastScanAt: now)
        try folder.insert(db)
        return folder
    }

    private static func importEntry(_ entry: FolderEntry, folderID: Int64,
                                    in db: Database) throws -> ImportSummary {
        let alreadyTracked = try DJAsset
            .filter(Column("folderID") == folderID && Column("relPath") == entry.relPath)
            .fetchCount(db) > 0
        if alreadyTracked {
            return ImportSummary(added: 0, updated: 0, skipped: 1, failed: [])
        }

        let now = Date()
        let trackID: Int64
        if let hash = entry.contentHash,
           let existing = try DJTrack.filter(Column("contentHash") == hash).fetchOne(db),
           let id = existing.id {
            trackID = id
        } else {
            var track = DJTrack(
                syncID: UUID().uuidString,
                title: entry.metadata.title ?? entry.url.deletingPathExtension().lastPathComponent,
                durationSec: entry.metadata.durationSec,
                codec: entry.url.pathExtension.uppercased(),
                contentHash: entry.contentHash ?? "missing",
                sortKey: entry.url.lastPathComponent,
                addedAt: now,
                updatedAt: now)
            track.albumID = try albumID(for: entry, in: db)
            try track.insert(db)
            guard let id = track.id else { return ImportSummary(failed: [entry.url]) }
            trackID = id
            try attachArtists(to: trackID, metadata: entry.metadata, in: db)
            var event = DJImportEvent(trackID: trackID, kind: "import", detail: "folder", at: now)
            try event.insert(db)
        }

        var asset = DJAsset(trackID: trackID,
                            folderID: folderID,
                            bookmark: entry.bookmark,
                            relPath: entry.relPath,
                            sizeBytes: entry.sizeBytes,
                            fileModifiedAt: entry.fileModifiedAt,
                            unsupportedReason: nil)
        try asset.insert(db)
        return ImportSummary(added: 1, updated: 0, skipped: 0, failed: [])
    }

    /// Find-or-create album; returns nil when the file carries no album tag.
    private static func albumID(for entry: FolderEntry, in db: Database) throws -> Int64? {
        guard let raw = entry.metadata.albumTitle else { return nil }
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        if let existing = try DJAlbum.filter(Column("title") == title).fetchOne(db) {
            return existing.id
        }
        var album = DJAlbum(syncID: UUID().uuidString,
                            title: title,
                            albumArtist: entry.metadata.albumArtist,
                            createdAt: Date())
        try album.insert(db)
        return album.id
    }

    /// Attaches ordered primary artists from the metadata's artist list.
    private static func attachArtists(to trackID: Int64, metadata: ImportMetadata,
                                      in db: Database) throws {
        let names = ArtistNamePolicy.artistNames(from: metadata.artist)
        for (index, rawName) in names.enumerated() {
            guard let name = ArtistNamePolicy.normalize(rawName) else { continue }
            let artistID: Int64
            if let existing = try DJArtist.filter(Column("name") == name).fetchOne(db),
               let id = existing.id {
                artistID = id
            } else {
                var artist = DJArtist(syncID: UUID().uuidString,
                                      name: name,
                                      sortName: ArtistNamePolicy.sortName(for: name),
                                      createdAt: Date())
                try artist.insert(db)
                artistID = artist.id!
            }
            try db.execute(sql: """
                INSERT INTO track_artist (trackID, artistID, role, position)
                VALUES (?, ?, 'primary', ?)
                """, arguments: [trackID, artistID, index])
        }
    }

    // MARK: - File helpers

    private static func relPath(_ url: URL, relativeTo folder: URL) -> String {
        let root = folder.standardizedFileURL.path
        let file = url.standardizedFileURL.path
        if file.hasPrefix(root + "/") {
            return String(file.dropFirst(root.count + 1))
        }
        return url.lastPathComponent
    }

    /// Streaming SHA-256 of file bytes, used as the change-detection identity
    /// (NFR-DET-2: no Swift `Hasher` for identity).
    private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fileSize(of url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attrs[.size] as? NSNumber)?.int64Value
    }

    private static func modificationDate(of url: URL) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return attrs[.modificationDate] as? Date
    }
}
