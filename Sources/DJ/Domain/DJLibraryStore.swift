import Foundation
import GRDB
import TonearmCore

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

/// `DJLibraryStore`'s own small write failure — currently only `saveCrate`'s
/// (the crate/playlist row insert). Not a catalog-import error: C02 retired
/// the duplicate catalog this store used to write (`importFolder`,
/// `DJTrack`/`DJArtist`/`DJAlbum`/`DJAsset`) — see dj_v12 and
/// `IMPLEMENT_CLAP_PLAN.md`'s C02 entry.
public enum DJStoreError: LocalizedError {
    case failedToInsertPlaylist

    public var errorDescription: String? {
        switch self {
        case .failedToInsertPlaylist: return "Could not save the crate playlist"
        }
    }
}

/// The DJ-local supplementary-data store (§10.1, §18.4): grid corrections,
/// analysis artifacts, the stem-cache-adjacent reads, the crate/playlist
/// tables, and the §37.3 mix-recording journal. This is **not** a music
/// catalog — every method here is keyed by a **core** `LibraryStore` track
/// id (`Sources/Data/LibraryStore.swift` is the one place track/artist/
/// album/asset identity lives, per C02). Writes are serialized by the actor;
/// a multi-row write (e.g. `finalizeRecordingMix`) is one GRDB transaction so
/// a crash leaves either the whole write or none (NFR-REL-1).
///
/// This type used to also be the DJ database's **catalog** writer
/// (`importFolder`, `DJTrack`/`DJArtist`/`DJAlbum`/`DJAsset`) — a second,
/// duplicate copy of what core `LibraryStore` already owns. That surface had
/// zero production callers (`LibraryModel.importFolder` was rewired onto
/// core `IngestService.addFolder` in session 14) and was deleted in C02
/// (dj_v12); kept the `DJLibraryStore` name rather than renaming, since
/// every DJ feature call site (`RecordingService`, `GridCorrectionRepository`,
/// `MixRepository`, `PlaylistCrateImporter`, `DeckLoader`, `WorkspaceModel`)
/// still refers to "the DJ database," and a rename would touch all of them
/// for a cosmetic-only gain.
public actor DJLibraryStore {
    public static let shared: DJLibraryStore = try! DJLibraryStore()

    public nonisolated let pool: DatabasePool

    public init(pool: DatabasePool) {
        self.pool = pool
    }

    public init(path: URL) throws {
        pool = try DJDatabase.open(at: path)
    }

    public init() throws {
        pool = try DJDatabase.open(at: DJDatabase.defaultDatabaseURL())
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
    /// real header, the asset's real size, and the §37.4 timeline's
    /// `mix_track_event` rows — all in **one** transaction (§37.5 step 1,
    /// NFR-REL-1). `events` replaces any prior rows (idempotent re-finalize).
    /// Returns the finished row (the finish screen opens from it).
    @discardableResult
    public func finalizeRecordingMix(mixID: Int64,
                                     durationSec: Double,
                                     sizeBytes: Int64,
                                     events: [DJMixTrackEvent]) throws -> DJMix? {
        try pool.write { db in
            guard var mix = try DJMix.fetchOne(db, key: mixID) else { return nil }
            mix.localState = MixLocalState.complete.rawValue
            mix.durationSec = durationSec
            mix.sizeBytes = sizeBytes
            mix.trackCount = events.count
            try mix.update(db)
            if var asset = try DJMixAsset.fetchOne(db, key: mixID) {
                asset.totalBytes = sizeBytes
                try asset.update(db)
            }
            try DJMixTrackEvent.filter(Column("mixID") == mixID).deleteAll(db)
            for event in events {
                var event = event
                try event.insert(db)
            }
            return mix
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

    // MARK: - Mix library (§41.12, FR-REC-1/5; plan 5.12)

    /// Every finished mix — `complete` and `corrupt` — newest first (§41.12's
    /// "Recorded Mixes"). A `corrupt` row is shown honestly (never silently
    /// dropped, §46.2) with its state and a delete affordance.
    public func completedMixes() throws -> [DJMix] {
        try pool.read { db in
            try DJMix
                .filter(Column("localState") != MixLocalState.recording.rawValue)
                .order(Column("recordedAt").desc)
                .fetchAll(db)
        }
    }

    /// The total on-device size of finished mixes — the §41.12 "Mixes on this
    /// iPad" readout (recordings are user content, never evicted, §43.6).
    public func mixStorageBytes() throws -> Int64 {
        try pool.read { db in
            try Int64.fetchOne(db, sql: """
                SELECT COALESCE(SUM(sizeBytes), 0) FROM mix
                WHERE localState != ?
                """, arguments: [MixLocalState.recording.rawValue]) ?? 0
        }
    }

    /// A mix's §37.4 timeline rows in `position` order — the finish screen's
    /// tracklist and the review-listen markers (§41.11).
    public func mixTrackEvents(mixID: Int64) throws -> [DJMixTrackEvent] {
        try pool.read { db in
            try DJMixTrackEvent
                .filter(Column("mixID") == mixID)
                .order(Column("position"))
                .fetchAll(db)
        }
    }

    /// The title/notes a finished mix keeps — FR-REC-1's "title and annotate".
    public func updateMix(mixID: Int64, title: String, notes: String?) throws {
        try pool.write { db in
            guard var mix = try DJMix.fetchOne(db, key: mixID) else { return }
            mix.title = title
            mix.notes = notes
            try mix.update(db)
        }
    }

    /// Remove a mix row (cascade-deleting its `mix_track_event`/`mix_asset`
    /// rows). Returns the asset's `localRelPath` so the caller can delete the
    /// user-content file (the file is not the store's concern).
    @discardableResult
    public func deleteMix(mixID: Int64) throws -> String? {
        try pool.write { db in
            let path = try DJMixAsset.fetchOne(db, key: mixID)?.localRelPath
            try DJMix.filter(key: mixID).deleteAll(db)
            return path
        }
    }

    // MARK: - Crate playlists (§18A.4, C02)

    /// Save (or replace) a crate playlist: a `DJPlaylist` named `title` holding
    /// exactly `trackIDs` (**core** `LibraryStore` track ids — C02) in order.
    /// Re-saving the same title replaces the old row so a re-import never
    /// stacks duplicate crates.
    public func saveCrate(title: String, trackIDs: [Int64]) async throws -> Int64 {
        try await pool.write { db in
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let effective = trimmed.isEmpty ? "Crate" : trimmed
            let now = Date()
            if let existing = try DJPlaylist.filter(Column("title") == effective).fetchOne(db),
               let existingID = existing.id {
                try DJPlaylistItem.filter(Column("playlistID") == existingID).deleteAll(db)
                for (position, trackID) in trackIDs.enumerated() {
                    var item = DJPlaylistItem(playlistID: existingID,
                                              trackID: trackID,
                                              position: position)
                    try item.insert(db)
                }
                var updated = existing
                updated.title = effective
                updated.updatedAt = now
                try updated.update(db)
                return existingID
            }
            var playlist = DJPlaylist(syncID: UUID().uuidString,
                                      title: effective,
                                      kind: "manual",
                                      createdAt: now,
                                      updatedAt: now)
            try playlist.insert(db)
            guard let playlistID = playlist.id else { throw DJStoreError.failedToInsertPlaylist }
            for (position, trackID) in trackIDs.enumerated() {
                var item = DJPlaylistItem(playlistID: playlistID,
                                          trackID: trackID,
                                          position: position)
                try item.insert(db)
            }
            return playlistID
        }
    }
}
