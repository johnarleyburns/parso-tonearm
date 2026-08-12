import Foundation

/// A deck's clock state at a sync instant (§32.3) — the pure value the sync
/// math reads. Built by the control side from published telemetry plus the
/// deck's grid snapshot; never computed on the render thread.
public struct SyncClock: Sendable, Equatable {
    /// The deck's playhead, in the track's own sample space (§30.1).
    public var playheadSample: Double
    /// The deck's beat grid (from `beat_grid` + `grid_correction`).
    public var grid: DeckGrid
    /// The deck's current playback rate (1.0 = normal, §31.1).
    public var rate: Double

    public init(playheadSample: Double, grid: DeckGrid, rate: Double) {
        self.playheadSample = playheadSample
        self.grid = grid
        self.rate = rate
    }

    /// The deck's current effective BPM — grid BPM scaled by the playback rate.
    public var effectiveBPM: Double { grid.bpm * rate }

    /// Beat phase (0 ≤ p < 1) of `sample` within the deck's grid beat.
    public func beatPhase(at sample: Double) -> Double {
        grid.beatPhase(at: sample)
    }

    /// Bar phase (0 ≤ p < 1) of `sample` within the deck's grid bar (§32.2).
    public func barPhase(at sample: Double) -> Double {
        grid.barPhase(at: sample)
    }

    /// The shortest signed difference between two phases, in (−0.5, 0.5].
    public static func phaseDifference(_ a: Double, _ b: Double) -> Double {
        var delta = a - b
        if delta > 0.5 { delta -= 1 }
        if delta <= -0.5 { delta += 1 }
        return delta
    }
}

/// The pure output of a sync correction (§32.1). The render layer only applies
/// the returned rate and playhead shift — it never re-derives the math.
public struct SyncCorrection: Sendable, Equatable {
    /// The rate the synced deck must play at to tempo-match the master.
    public var setRate: Float
    /// The signed playhead shift in track samples that phase-aligns beats
    /// (positive = forward). Applied as a scheduled, sample-accurate jump
    /// (§32.1).
    public var playheadShiftSamples: Int64

    public init(setRate: Float, playheadShiftSamples: Int64) {
        self.setRate = setRate
        self.playheadShiftSamples = playheadShiftSamples
    }
}

/// Pure beat-sync math (§32, FR-ENG-4). No I/O, no allocation, deterministic —
/// the §32.3 pure kernel, unit-tested against known grids (AT-ENGINE-SYNC-\*).
/// The render layer only *applies* the returned rate and sample shift.
public enum SyncEngine {

    /// Beat sync: tempo-match `synced` to `master` and phase-align beats at the
    /// sync instant (§32.1).
    ///
    /// `atMasterSample` is the master-timeline sample the correction is
    /// anchored to — the frame at which the control side read both playheads.
    /// The phases are evaluated at the decks' own playheads (their grid is in
    /// track-sample space, §30.1); the anchor is what the render layer uses as
    /// the nudge's fire frame.
    public static func correction(master: SyncClock, synced: SyncClock,
                                  atMasterSample: Int64) -> SyncCorrection {
        let targetRate = master.effectiveBPM / synced.grid.bpm
        let masterPhase = master.beatPhase(at: master.playheadSample)
        let syncedPhase = synced.beatPhase(at: synced.playheadSample)
        let deltaBeats = SyncClock.phaseDifference(masterPhase, syncedPhase)
        let shift = Int64((deltaBeats * synced.grid.samplesPerBeat).rounded())
        return SyncCorrection(setRate: Float(targetRate), playheadShiftSamples: shift)
    }

    /// Downbeat-aware (bar) sync (§32.2): aligns downbeats — bar 1 to bar 1 —
    /// rather than beats, for phrase-aligned transitions. The synced deck's
    /// playhead shifts so its bar phase matches the master's.
    public static func downbeatCorrection(master: SyncClock, synced: SyncClock,
                                          atMasterSample: Int64) -> SyncCorrection {
        let targetRate = master.effectiveBPM / synced.grid.bpm
        let masterBarPhase = master.barPhase(at: master.playheadSample)
        let syncedBarPhase = synced.barPhase(at: synced.playheadSample)
        let deltaBars = SyncClock.phaseDifference(masterBarPhase, syncedBarPhase)
        let deltaBeats = deltaBars * Double(max(master.grid.beatsPerBar, 1))
        let shift = Int64((deltaBeats * synced.grid.samplesPerBeat).rounded())
        return SyncCorrection(setRate: Float(targetRate), playheadShiftSamples: shift)
    }

    /// Continuous rate tracking (§32.1): the synced deck's rate that keeps its
    /// effective BPM equal to the master's for the master's current rate. This
    /// is the render thread's per-callback computation while SYNC is engaged,
    /// so a master pitch change moves the synced deck with it.
    public static func continuousRate(masterRate: Double, masterBPM: Double,
                                      syncedBPM: Double) -> Double {
        guard syncedBPM > 0 else { return 1 }
        return masterRate * masterBPM / syncedBPM
    }
}
