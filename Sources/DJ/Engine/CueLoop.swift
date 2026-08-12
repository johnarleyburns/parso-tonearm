import Foundation

/// Pure cue/loop playhead arithmetic (§33). Renders as a combination of these
/// functions plus `Scheduler` inside the deck's callback — no allocation, no
/// I/O (§33.1).
public enum CueLoop {

    /// Loop `[start, end)` from a start sample and a length in beats (§33.2).
    /// The `end` snaps to the grid via `samplesPerBeat`, so beat-aligned loops
    /// wrap seamlessly.
    public static func loopEnd(start: Int64, beats: Double, grid: DeckGrid) -> Int64 {
        start + Int64((beats * grid.samplesPerBeat).rounded())
    }

    /// True when the playhead has reached or passed the loop's half-open end.
    public static func reachedEnd(_ playhead: Double, loopEnd: Int64) -> Bool {
        playhead >= Double(loopEnd)
    }

    /// Wrap `end → start`, preserving any fractional overshoot across the wrap
    /// so a deck with `rate > 1` stays sample-exact (§33.2, §30.2).
    public static func wrap(_ playhead: Double, loopStart: Int64, loopEnd: Int64) -> Double {
        Double(loopStart) + (playhead - Double(loopEnd))
    }
}

/// The temporary CDJ-style cue state machine (§33.1): press → jump to the cue
/// point and preview while held; release → return to the pre-preview position
/// and pause. Purely a value; the deck's render state drives the playhead from
/// the values this returns.
public struct TempCueState: Sendable {
    public var pointSample: Int64 = 0
    public var hasPoint = false
    public var previewStartSample: Int64 = 0
    public var previewing = false

    public init() {}

    /// Set the temporary cue point at an explicit track sample.
    public mutating func setPoint(_ sample: Int64) {
        pointSample = sample
        hasPoint = true
    }

    /// Press the CUE transport at the current playhead.
    ///
    /// With a point set: enter preview — the caller must jump the playhead to
    /// `pointSample` and play. Without one: set the point at the playhead (the
    /// classic first-press behavior) and stay where you are.
    ///
    /// - Returns: `true` when previewing (caller jumps to `pointSample` and
    ///   plays), `false` when the point was just set.
    public mutating func press(at playhead: Int64) -> Bool {
        if hasPoint {
            previewStartSample = playhead
            previewing = true
            return true
        } else {
            pointSample = playhead
            hasPoint = true
            previewing = false
            return false
        }
    }

    /// Release the CUE transport.
    ///
    /// - Returns: the pre-preview playhead to restore, or `nil` when not
    ///   previewing (nothing to do).
    public mutating func release() -> Int64? {
        guard previewing else { return nil }
        previewing = false
        return previewStartSample
    }
}
