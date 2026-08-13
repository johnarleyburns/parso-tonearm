import Foundation
import GRDB

/// The SQL writers for the §19.4 persisted analysis artifacts — **the single
/// source of truth for the row shapes**. Both callers use the same helpers so
/// the two write paths can never drift apart:
///
/// - `AnalysisCoordinator.persist` calls these inside its one `pool.write`
///   transaction, so a track's whole analysis lands atomically (NFR-REL-1,
///   §19.4 "in one GRDB transaction").
/// - `DJLibraryStore`'s §10.1 façade (`savePhrases` / `saveBeatGrid` /
///   `saveDownbeats` / `saveWaveform` / `saveEnergyCurve`) calls them from
///   their own transactions.
///
/// Every writer is **idempotent per (track, version)**: multi-row tables
/// (`phrase`, `downbeat`) are DELETE-then-INSERT, single-row tables are
/// `INSERT OR REPLACE` on the `trackID` primary key (§19.4 rule 2). Grid
/// corrections never pass through here — the `grid_correction` log replays
/// over these immutable rows at read time (§19.4 rule 3, §23.3).
internal enum AnalysisArtifacts {

    // MARK: - Beat grid (header + per-beat blob)

    /// Writes the detected `beat_grid` header with **real** `firstBeatSample` /
    /// `beatCount` and the per-beat `beat_blob` (§19.4 — placeholder zeros were
    /// the pre-M5 defect). `source = 'detected'` always: corrections live in the
    /// `grid_correction` log, never here.
    static func writeBeatGrid(_ grid: BeatGrid, trackID: Int64,
                              db: Database, updatedAt: Date) throws {
        let meanConfidence = grid.confidence.isEmpty
            ? nil
            : Double(grid.confidence.reduce(0, +)) / Double(grid.confidence.count)
        try db.execute(sql: """
            INSERT OR REPLACE INTO beat_grid
            (trackID, syncID, bpm, firstBeatSample, beatCount, isConstantTempo,
             source, confidence, version, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, 'detected', ?, ?, ?)
            """, arguments: [trackID, "g-\(trackID)", grid.bpm, grid.firstBeatSample,
                             grid.beatSamples.count, grid.isConstantTempo,
                             meanConfidence, AnalysisVersions.beat, updatedAt])

        let blob = AnalysisBlobLayouts.encodeBeatBlob(grid.beatSamples,
                                                      confidence: grid.confidence,
                                                      version: AnalysisVersions.beat)
        try db.execute(sql: "INSERT OR REPLACE INTO beat_blob (trackID, blob) VALUES (?, ?)",
                       arguments: [trackID, blob])
    }

    // MARK: - Downbeats

    /// One row per bar start — the anchor for phrase display and bar numbering
    /// (§19.4, §15.3). Replaced wholesale on re-analysis.
    static func writeDownbeats(_ indices: [Int], beatGrid: BeatGrid,
                               trackID: Int64, db: Database) throws {
        try db.execute(sql: "DELETE FROM downbeat WHERE trackID = ?", arguments: [trackID])
        for (barNumber, index) in indices.enumerated() {
            guard index >= 0, index < beatGrid.beatSamples.count else { continue }
            let confidence = index < beatGrid.confidence.count
                ? Double(beatGrid.confidence[index])
                : nil
            try db.execute(sql: """
                INSERT INTO downbeat (trackID, beatIndex, samplePosition, barNumber, confidence)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [trackID, index, beatGrid.beatSamples[index],
                                 barNumber + 1, confidence])
        }
    }

    // MARK: - Phrases

    /// One row per §25 phrase (§19.4). Replaced wholesale on re-analysis.
    static func writePhrases(_ phrases: [Phrase], trackID: Int64,
                             db: Database) throws {
        try db.execute(sql: "DELETE FROM phrase WHERE trackID = ?", arguments: [trackID])
        for (i, phrase) in phrases.enumerated() {
            try db.execute(sql: """
                INSERT INTO phrase
                (syncID, trackID, startSample, endSample, startBeat, lengthBeats,
                 type, energy, confidence, version)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: ["p-\(trackID)-\(i)", trackID,
                                 phrase.startSample, phrase.endSample,
                                 phrase.startBeat, phrase.lengthBeats,
                                 phrase.type.rawValue,
                                 Double(phrase.energy), phrase.confidence,
                                 AnalysisVersions.phrase])
        }
    }

    // MARK: - Waveform pyramid

    /// The packed multi-level, band-split pyramid (§19.4, §26). FR-WAVE-2 has no
    /// other source — the low/mid/high RMS rides inside the blob.
    static func writeWaveform(_ pyramid: WaveformPyramid, trackID: Int64,
                              db: Database) throws {
        let blob = AnalysisBlobLayouts.encodeWaveformPyramid(pyramid,
                                                             version: AnalysisVersions.waveform)
        try db.execute(sql: """
            INSERT OR REPLACE INTO waveform_pyramid
            (trackID, levels, baseSamplesPerBin, channelLayout, blob, version)
            VALUES (?, ?, ?, 'mono', ?, ?)
            """, arguments: [trackID, pyramid.levels.count,
                             pyramid.baseSamplesPerBin, blob,
                             AnalysisVersions.waveform])
    }

    // MARK: - Energy curve

    /// The per-beat energy curve BLOB backing the prep energy display (§19.4).
    static func writeEnergyCurve(_ curve: [Float], hopSeconds: Double,
                                 trackID: Int64, db: Database) throws {
        let blob = AnalysisBlobLayouts.encodeEnergyCurve(curve,
                                                         hopSeconds: hopSeconds,
                                                         version: AnalysisVersions.beat)
        try db.execute(sql: """
            INSERT OR REPLACE INTO energy_curve
            (trackID, resolution, count, blob, version)
            VALUES (?, 'beat', ?, ?, ?)
            """, arguments: [trackID, curve.count, blob, AnalysisVersions.beat])
    }
}
