import Foundation

/// The §35A post-fader beat-synced echo's **per-deck control value** (the
/// pure, `Sendable` half of the kernel): `enabled`, `beats`, `depth`,
/// `feedback`, plus the clamp ranges the UI and `WorkspaceModel` read.
///
/// The Phase 6d cutover deleted the render-thread DSP half — `BeatEchoLine`,
/// the fixed-capacity delay ring that used to live alongside this struct
/// (GPLv3, `parso-audio-engine/docs/phase6-parity.md`, "6d backlog") — since
/// PAE's `ParsoDJEngine.Deck.setEcho` now owns the render-side echo entirely.
/// This struct is original work and stays: it is the pure control surface the
/// UI clamps against (`WorkspaceModel.setEchoBeats` and friends).
///
/// - Delay time is derived from the **master clock**, not a millisecond value:
///   `delayFrames = beats × 60/effectiveBPM × sampleRate`. A tempo change moves
///   the echo with it; a synced pair echoes in time with both decks (§35A.2).
/// - Feedback is hard-clamped below unity, so the tail always decays; a
///   self-oscillating echo is a defect, not a feature.
public struct BeatEcho: Sendable, Equatable {
    /// ON/OFF — momentary or latched (§35A.2).
    public var enabled: Bool
    /// 1/4, 1/2, 1, 2, 4 — delay time in beats (§35A.2).
    public var beats: Double
    /// 0…1 — wet mix.
    public var depth: Float
    /// 0…0.85, clamped — tail length.
    public var feedback: Float

    /// The §35A.2 beat lengths, matching `ClubGeometry.echoBeats`.
    public static let beatLengths: [Double] = [0.25, 0.5, 1, 2, 4]
    public static let minBeats: Double = 0.25
    public static let maxBeats: Double = 4
    public static let maxDepth: Float = 1
    public static let minFeedback: Float = 0
    /// Feedback is **hard-clamped below unity** so the tail always decays
    /// (§35A.2) — a self-oscillating echo is a defect, not a feature.
    public static let maxFeedback: Float = 0.85
    /// The nominal master tempo used before any deck is loaded — the delay
    /// stays well-defined while the master clock has no grid to read.
    public static let nominalBPM: Double = 120

    public init(enabled: Bool = false, beats: Double = 1,
                depth: Float = 0.6, feedback: Float = 0.7) {
        self.enabled = enabled
        self.beats = Self.clampBeats(beats)
        self.depth = min(Self.maxDepth, max(0, depth))
        self.feedback = min(Self.maxFeedback, max(Self.minFeedback, feedback))
    }

    /// The §35A.2 delay math: `beats × 60/BPM × sampleRate`, in frames. A
    /// missing or zero master clock reads the nominal tempo, so the delay is
    /// always well-defined (no division by zero).
    public static func delayFrames(beats: Double, bpm: Double, sampleRate: Double) -> Int {
        let effective = bpm > 0 ? bpm : nominalBPM
        return Int((clampBeats(beats) * (60.0 / effective) * sampleRate).rounded())
    }

    private static func clampBeats(_ beats: Double) -> Double {
        min(maxBeats, max(minBeats, beats))
    }
}
