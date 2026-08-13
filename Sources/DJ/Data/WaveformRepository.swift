import Foundation
import GRDB

// MARK: - §26A read model types

/// One §25 phrase as the ribbon draws it (§26A.4): a contiguous labelled span
/// whose length is shown in **bars**, not seconds, and whose low-confidence
/// boundary is marked (dashed) rather than hidden.
public struct PhraseSpan: Equatable, Sendable {
    /// Sample position of the span's first beat (`phrase.startSample`, §19.4).
    public var startSample: Int64
    /// Sample position of the span's last beat (`phrase.endSample`).
    public var endSample: Int64
    /// The span's length in bars (from `lengthBeats` ÷ `beatsPerBar`).
    public var barCount: Int
    /// The section label (intro/build/drop/chorus/breakdown/outro).
    public var type: PhraseType
    /// 0…1 boundary confidence.
    public var confidence: Double

    public init(startSample: Int64, endSample: Int64, barCount: Int,
                type: PhraseType, confidence: Double) {
        self.startSample = startSample
        self.endSample = endSample
        self.barCount = barCount
        self.type = type
        self.confidence = confidence
    }

    /// The §26A.4 display threshold: below it a span draws a dashed edge (the
    /// honest signal is "boundary uncertain", not silence) instead of being
    /// hidden.
    public static let lowConfidenceThreshold: Double = 0.5

    public var isLowConfidence: Bool { confidence < Self.lowConfidenceThreshold }
}

/// One hot cue as the waveform draws it (§26A.6): a full-height coloured
/// marker with its pad letter, at a sample-accurate position.
public struct CueMarker: Equatable, Sendable {
    public var sample: Int64
    public var label: String

    public init(sample: Int64, label: String) {
        self.sample = sample
        self.label = label
    }
}

/// An inclusive sample range — the active loop (§26A.6) drawn as a translucent
/// region with hard in/out edges.
public struct SampleRange: Equatable, Sendable {
    public var start: Int64
    public var end: Int64

    public init(start: Int64, end: Int64) {
        self.start = start
        self.end = end
    }
}

/// The §26A.1 data contract — the renderer never touches audio.
///
/// Assembled control-side by `WaveformRepository` from the §19.4 persisted
/// rows (the pyramid BLOB, `beat_grid` + `beat_blob`, `grid_correction`,
/// `phrase`, `cue_point`, `loop`). The renderer draws from this value: it
/// MUST NOT read the audio file, decode, or compute a reduction at draw time,
/// and it MUST NOT invent geometry when the model is absent — an unanalysed
/// track draws the honest empty state, never a synthetic wave (§26A.1).
public struct WaveformRenderModel: Equatable, Sendable {
    /// The decoded band-split pyramid — every level, so the renderer picks the
    /// §26A.7 level against the live strip width.
    public let pyramid: WaveformPyramid
    /// The per-level normalisation peak (max |min|,|max|) so bar heights stay
    /// stable while scrolling — computed once, never per frame.
    public let peaks: [Float]
    /// The authoritative beat sample positions (§23.3): the corrected grid a
    /// deck quantises to, so what the user sees is what the engine uses
    /// (§26A.3, AT-WAVE-3). Sample-accurate in the 48 kHz analysis space.
    public let beats: [Int64]
    /// The bar-start sample positions — every `beatsPerBar`-th beat.
    public let downbeats: [Int64]
    /// The bar number of the first downbeat (bar 1 = first downbeat, §26A.3).
    public let barNumberOrigin: Int
    /// The §25 phrase spans, in track order (§26A.4).
    public let phrases: [PhraseSpan]
    /// Hot cues, in pad order (§26A.6).
    public let cues: [CueMarker]
    /// The active loop, when one is set (§26A.6).
    public let activeLoop: SampleRange?
    /// The authoritative grid — the deck's quantise surface (§26A.3).
    public let grid: DeckGrid
    /// The track's duration in samples (48 kHz analysis space).
    public let durationSamples: Int64
    /// Whether the grid follows the stored per-beat positions rather than
    /// extrapolating from BPM (§26A.3).
    public let isConstantTempo: Bool

    public init(pyramid: WaveformPyramid,
                peaks: [Float],
                beats: [Int64],
                downbeats: [Int64],
                barNumberOrigin: Int,
                phrases: [PhraseSpan],
                cues: [CueMarker],
                activeLoop: SampleRange?,
                grid: DeckGrid,
                durationSamples: Int64,
                isConstantTempo: Bool) {
        self.pyramid = pyramid
        self.peaks = peaks
        self.beats = beats
        self.downbeats = downbeats
        self.barNumberOrigin = barNumberOrigin
        self.phrases = phrases
        self.cues = cues
        self.activeLoop = activeLoop
        self.grid = grid
        self.durationSamples = durationSamples
        self.isConstantTempo = isConstantTempo
    }

    /// The track has a pyramid to draw — `nil` from the repository means the
    /// honest empty state (§26A.1), never synthetic geometry.
    public var hasAnalysis: Bool { !pyramid.levels.isEmpty }
}

// MARK: - The read seam

/// The read side the waveform views draw from (§26A.1). `WaveformRepository`
/// conforms; tests inject a fake so the workspace/prep models' state is
/// exercised deterministically (§47.2).
public protocol WaveformRendering: Sendable {
    /// The render model for a track, or `nil` for an unanalysed track — the
    /// honest empty state (§26A.1).
    func renderModel(trackID: Int64) async throws -> WaveformRenderModel?
}

// MARK: - WaveformRepository

/// Reads the §19.4 persisted analysis artifacts and assembles the §26A.1
/// `WaveformRenderModel` — the single place that turns rows into the render
/// contract. Reads go straight through the pool (the rows are immutable
/// analysis; corrections replay over them §23.3); nothing here ever mutates.
public struct WaveformRepository: WaveformRendering, Sendable {
    /// The 48 kHz analysis space every persisted sample position lives in
    /// (§19.4, `AudioDecoder.workingSampleRate`).
    public static let sampleSpaceRate: Double = AudioDecoder.workingSampleRate

    public let pool: DatabasePool

    public init(pool: DatabasePool) {
        self.pool = pool
    }

    public func renderModel(trackID: Int64) async throws -> WaveformRenderModel? {
        try await pool.read { db in
            guard let track = try DJTrack.filter(key: trackID).fetchOne(db) else { return nil }
            guard let pyramid = try Self.readPyramid(trackID: trackID, in: db) else { return nil }

            let corrections = try Self.readCorrections(trackID: trackID, in: db)
            let detected = try Self.readDetectedGrid(trackID: trackID, in: db)
            let grid = GridReplay.authoritativeGridIfAnalyzed(base: detected?.grid,
                                                              corrections: corrections)

            let beatsPerBar = max(1, grid?.beatsPerBar ?? 4)
            let durationSamples = Self.durationSamples(track: track)

            let beats = Self.beats(detected: detected,
                                   grid: grid,
                                   durationSamples: durationSamples)
            let downbeats: [Int64] = beats.enumerated()
                .compactMap { index, sample in index % beatsPerBar == 0 ? sample : nil }

            let phraseRows = try Row.fetchAll(db, sql: """
                SELECT startSample, endSample, lengthBeats, type, confidence
                FROM phrase WHERE trackID = ? ORDER BY startBeat, id
                """, arguments: [trackID])
            let phrases = phraseRows.map { row -> PhraseSpan in
                let lengthBeats = Int(row["lengthBeats"] as? Int64 ?? 0)
                let bars = max(1, (lengthBeats + beatsPerBar - 1) / beatsPerBar)
                return PhraseSpan(startSample: row["startSample"] as? Int64 ?? 0,
                                  endSample: row["endSample"] as? Int64 ?? 0,
                                  barCount: bars,
                                  type: PhraseType(rawValue: row["type"] as? String ?? "") ?? .build,
                                  confidence: row["confidence"] as? Double ?? 0)
            }

            let cues = try Self.readCues(trackID: trackID, in: db)
            let activeLoop = try Self.readActiveLoop(trackID: trackID, in: db)
            let peaks = pyramid.levels.map { level in
                level.map { max(abs($0.min), abs($0.max)) }.max() ?? 1
            }

            return WaveformRenderModel(
                pyramid: pyramid,
                peaks: peaks,
                beats: beats,
                downbeats: downbeats,
                barNumberOrigin: 1,
                phrases: phrases,
                cues: cues,
                activeLoop: activeLoop,
                grid: grid ?? DeckGrid(sampleRate: Self.sampleSpaceRate),
                durationSamples: durationSamples,
                isConstantTempo: detected?.isConstantTempo ?? true)
        }
    }

    // MARK: - Reads

    /// The decoded band-split pyramid, or `nil` for an unanalysed track.
    /// `nil` is the honest empty state — the renderer never invents geometry.
    private static func readPyramid(trackID: Int64, in db: Database) throws -> WaveformPyramid? {
        guard let blob = try Data.fetchOne(db, sql: """
            SELECT blob FROM waveform_pyramid WHERE trackID = ?
            """, arguments: [trackID]) else { return nil }
        let decoded = try AnalysisBlobLayouts.decodeWaveformPyramid(blob)
        return WaveformPyramid(levels: decoded.levels,
                               sampleRate: decoded.sampleRate,
                               baseSamplesPerBin: decoded.baseSamplesPerBin)
    }

    /// The detected grid header + per-beat blob, or `nil` when the track has
    /// no grid yet. Corrections are NOT composed here — the §23.3 replay does
    /// that (`GridReplay.authoritativeGridIfAnalyzed`).
    private static func readDetectedGrid(trackID: Int64,
                                         in db: Database) throws -> (grid: DeckGrid, isConstantTempo: Bool, firstBeatSample: Int64, storedBeats: [Int64])? {
        guard let header = try Row.fetchOne(db, sql: """
            SELECT bpm, firstBeatSample, isConstantTempo FROM beat_grid WHERE trackID = ?
            """, arguments: [trackID]) else { return nil }
        let bpm = header["bpm"] as? Double ?? 120
        let firstBeat = header["firstBeatSample"] as? Int64 ?? 0
        let constant = (header["isConstantTempo"] as? Int64 ?? 1) != 0
        var stored: [Int64] = []
        if let blob = try Data.fetchOne(db, sql: """
            SELECT blob FROM beat_blob WHERE trackID = ?
            """, arguments: [trackID]),
           let decoded = try? AnalysisBlobLayouts.decodeBeatBlob(blob) {
            stored = decoded.samples
        }
        let grid = DeckGrid(referenceSample: Double(firstBeat),
                            bpm: bpm,
                            beatsPerBar: 4,
                            sampleRate: Self.sampleSpaceRate)
        return (grid, constant, firstBeat, stored)
    }

    /// The track's `grid_correction` log, in §23.3 replay order.
    private static func readCorrections(trackID: Int64, in db: Database) throws -> [GridCorrection] {
        try GridCorrection
            .filter(Column("trackID") == trackID)
            .order(Column("appliedAt"), Column("id"))
            .fetchAll(db)
    }

    /// The track's hot-cue markers, in pad order (§26A.6).
    private static func readCues(trackID: Int64, in db: Database) throws -> [CueMarker] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT samplePosition, label, hotIndex FROM cue_point
            WHERE trackID = ? AND kind = 'hot' ORDER BY hotIndex
            """, arguments: [trackID])
        return rows.map { row in
            let hotIndex = (row["hotIndex"] as? Int64).map { Int($0) }
            let label = row["label"] as? String
            return CueMarker(sample: row["samplePosition"] as? Int64 ?? 0,
                             label: label ?? hotIndex.map(Self.padLetter) ?? "")
        }
    }

    /// The active loop, when one is set (§26A.6).
    private static func readActiveLoop(trackID: Int64, in db: Database) throws -> SampleRange? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT startSample, endSample FROM loop
            WHERE trackID = ? AND isActive = 1 LIMIT 1
            """, arguments: [trackID]) else { return nil }
        return SampleRange(start: row["startSample"] as? Int64 ?? 0,
                           end: row["endSample"] as? Int64 ?? 0)
    }

    // MARK: - Beat math (§26A.3)

    /// The grid a deck actually quantises to: for a constant-tempo grid the
    /// authoritative grid's extrapolated beats (sample for sample what the
    /// engine uses, AT-WAVE-3); for a variable-tempo grid the stored per-beat
    /// positions re-anchored by the corrected reference (§26A.3).
    private static func beats(detected: (grid: DeckGrid, isConstantTempo: Bool, firstBeatSample: Int64, storedBeats: [Int64])?,
                              grid: DeckGrid?,
                              durationSamples: Int64) -> [Int64] {
        guard let grid else { return [] }
        if detected?.isConstantTempo ?? true {
            var generated: [Int64] = []
            var sample = grid.referenceSample
            let step = grid.samplesPerBeat
            let cap = durationSamples > 0 ? durationSamples : Int64.max
            // A safety cap so a corrupt grid can never produce an unbounded array.
            while sample <= Double(cap) && generated.count < 100_000 {
                generated.append(Int64(sample))
                sample += step
            }
            return generated
        }
        guard let detected, !detected.storedBeats.isEmpty else { return [] }
        let shift = Int64((grid.referenceSample - detected.grid.referenceSample).rounded())
        return detected.storedBeats.map { $0 + shift }
    }

    /// The track's duration in the 48 kHz analysis space.
    private static func durationSamples(track: DJTrack) -> Int64 {
        guard let seconds = track.durationSec, seconds > 0, seconds.isFinite else { return 0 }
        return Int64(seconds * Self.sampleSpaceRate)
    }

    /// The pad letter for a hot cue's `hotIndex` (0 → A, …, 7 → H).
    private static func padLetter(_ index: Int) -> String {
        guard (0..<8).contains(index) else { return "\(index + 1)" }
        return String(UnicodeScalar(65 + index) ?? "?")
    }
}
