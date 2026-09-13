import Foundation
import GRDB


// MARK: - grid_correction (authoritative user override log; FR-ANL-5, §23.3)

/// One row of the authoritative user grid-override log (§14.3, FR-ANL-5).
/// Edits are **appended**, never in-place, so the immutable detected analysis
/// survives and the corrections replay deterministically over it (§23.3) to
/// produce the authoritative `beat_grid` (`source = corrected`).
public struct GridCorrection: Codable, Identifiable, FetchableRecord,
                              MutablePersistableRecord, Equatable, Sendable {
    public var id: Int64?
    public var syncID: String
    public var trackID: Int64
    /// The `GridCorrectionOp` raw value (`nudge|setDownbeat|doubleBPM|halveBPM|setBPM|shift`).
    public var op: String
    /// e.g. the new BPM for `setBPM`.
    public var valueDouble: Double?
    /// e.g. the sample offset for `nudge`/`shift`, the sample for `setDownbeat`.
    public var valueInt: Int64?
    public var appliedAt: Date

    public init(id: Int64? = nil,
                syncID: String,
                trackID: Int64,
                op: String,
                valueDouble: Double? = nil,
                valueInt: Int64? = nil,
                appliedAt: Date) {
        self.id = id
        self.syncID = syncID
        self.trackID = trackID
        self.op = op
        self.valueDouble = valueDouble
        self.valueInt = valueInt
        self.appliedAt = appliedAt
    }

    public static let databaseTableName = "grid_correction"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// The grid-correction operations the prep surface can append (FR-PREP-5,
/// §14.3): tap-to-set-downbeat, drag-to-nudge, ×2 / ÷2, set BPM (tempo tap)
/// and the two-finger shift. Raw values are the `grid_correction.op` column.
public enum GridCorrectionOp: String, CaseIterable, Sendable, Equatable {
    /// Drag-nudge: shift the grid by a sample delta (`valueInt`).
    case nudge
    /// Tap-to-set-downbeat: make `valueInt` the sample of grid beat 0.
    case setDownbeat
    /// ×2 BPM.
    case doubleBPM
    /// ÷2 BPM.
    case halveBPM
    /// Set an explicit BPM (tempo tap) — `valueDouble`.
    case setBPM
    /// Two-finger nudge: shift the grid by a sample delta (`valueInt`).
    case shift
}

// MARK: - Persisted analysis artifacts (read side; §19.4, §10.1 façade)

/// One `downbeat` row — a bar start, the anchor for phrase display and bar
/// numbering (§15.3, §19.4).
public struct DownbeatRecord: Codable, FetchableRecord, Equatable, Sendable {
    public var beatIndex: Int
    public var samplePosition: Int64
    /// 1-based bar number, in the order the downbeats appear in the track.
    public var barNumber: Int
    public var confidence: Double?

    public init(beatIndex: Int, samplePosition: Int64, barNumber: Int,
                confidence: Double? = nil) {
        self.beatIndex = beatIndex
        self.samplePosition = samplePosition
        self.barNumber = barNumber
        self.confidence = confidence
    }
}

/// The decoded `energy_curve` readout — the per-beat energy BLOB backing the
/// prep energy display (§19.4, §15.7 `kind=0x04`).
public struct EnergyCurve: Equatable, Sendable {
    /// `beat|frame` — M5's pipeline always writes the per-beat curve.
    public var resolution: String
    /// The curve in `0...1`.
    public var values: [Float]
    /// The STFT hop-seconds the curve was built at.
    public var hopSeconds: Double

    public init(resolution: String, values: [Float], hopSeconds: Double) {
        self.resolution = resolution
        self.values = values
        self.hopSeconds = hopSeconds
    }
}
