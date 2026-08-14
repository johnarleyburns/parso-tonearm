import Foundation

/// The §35A post-fader beat-synced echo — the one Beat FX the five beginner
/// transitions require (M5 commit 5.5). Echo Out depends on it: an echo used as
/// a *transition* must keep sounding after its source is removed, which is why
/// the echo sits **post-fader, pre-crossfader**, per channel (§35A.1) — a
/// pre-fader echo dies with the fader and Echo Out collapses into Fader Cut.
///
/// `BeatEcho` is the **per-deck control value** (the pure, `Sendable` half of
/// the kernel): `enabled`, `beats`, `depth`, `feedback`. The render-thread DSP
/// lives in `BeatEchoLine` (one per output channel), which owns the fixed
/// capacity delay ring allocated at graph construction. The two are split the
/// way the spec splits them — the struct is the §35A.2 control surface, the
/// line is the §12.3 no-allocation render state.
///
/// - Delay time is derived from the **master clock**, not a millisecond value:
///   `delayFrames = beats × 60/effectiveBPM × sampleRate`. A tempo change moves
///   the echo with it; a synced pair echoes in time with both decks (§35A.2).
/// - Changing the delay (a beats change, or a master tempo change)
///   **crossfades between read pointers over one buffer** rather than jumping —
///   a pointer jump clicks (§35A.2).
/// - Feedback is hard-clamped below unity, so the tail always decays; a
///   self-oscillating echo is a defect, not a feature.
/// - `enabled = false` **stops new input to the line but continues to read the
///   tail** until it decays below the noise floor, then bypasses entirely at
///   zero cost. This is what "echo out" means: the user turns the source off
///   and the tail finishes on its own.
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
    /// The slowest tempo the delay ring is sized for — 4 beats at this BPM.
    /// The analysis range floor is 60 BPM (§22.3); the ±8% tempo fader puts
    /// 55.2 BPM at the bottom, and 55 keeps a little headroom below that.
    public static let slowestSupportedBPM: Double = 55
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
    /// always well-defined on the render thread (no division by zero).
    public static func delayFrames(beats: Double, bpm: Double, sampleRate: Double) -> Int {
        let effective = bpm > 0 ? bpm : nominalBPM
        return Int((clampBeats(beats) * (60.0 / effective) * sampleRate).rounded())
    }

    /// The ring capacity: the longest supported delay — 4 beats at the slowest
    /// supported tempo. The ring is allocated at graph construction and the
    /// render thread never grows it (§12.3). The caller allocates `+ 1` so the
    /// maximum delay never aliases the write position.
    public static func maxDelayFrames(sampleRate: Double) -> Int {
        delayFrames(beats: maxBeats, bpm: slowestSupportedBPM, sampleRate: sampleRate)
    }

    private static func clampBeats(_ beats: Double) -> Double {
        min(maxBeats, max(minBeats, beats))
    }
}

/// One output channel's §35A.2 echo DSP — the render-thread half of the
/// kernel. A fixed-capacity ring allocated at construction, a read pointer that
/// **crossfades on delay changes**, and the disabled-path tail-then-bypass.
/// Only the render thread mutates it; the control side changes parameters
/// through `RTCommand`s applied by `DeckState` (which holds the `BeatEcho`
/// control value) and the per-callback master-tempo retune.
public final class BeatEchoLine: @unchecked Sendable {

    /// Below this the disabled line's tail is done: bypass entirely at zero
    /// cost (§35A.2). A whole buffer below the floor means the tail is gone.
    public static let noiseFloor: Float = 1e-4

    private let ring: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let sampleRate: Double
    /// The crossfade's length in frames — one buffer (§35A.2).
    private let crossfadeFrames: Int

    private var writeIndex = 0
    private var enabled = false
    private var beats: Double = 1
    private var depth: Float = 0.6
    private var feedback: Float = 0.7

    /// The delay currently being read, and the delay being ramped toward.
    private var readFrames: Int
    private var targetDelayFrames: Int
    private var crossfading = false
    private var crossfadeFrom = 0
    private var crossfadeTo = 0
    private var crossfadePosition = 0
    /// Consecutive samples the disabled line's wet signal has stayed below the
    /// noise floor — the tail-then-bypass trigger.
    private var quietSamples = 0
    /// The line bypasses while disabled and its tail is gone (§35A.2).
    private var isBypassed = false

    public init(capacity: Int, sampleRate: Double, crossfadeFrames: Int) {
        precondition(capacity > 1, "echo ring must hold at least one sample")
        self.capacity = capacity
        self.sampleRate = sampleRate
        self.crossfadeFrames = max(1, crossfadeFrames)
        ring = .allocate(capacity: capacity)
        ring.initialize(repeating: 0, count: capacity)
        // Start at a valid nominal delay: the ring is empty, so the first
        // delay retune crossfades silence to silence and is inaudible.
        let initial = BeatEcho.delayFrames(beats: 1, bpm: BeatEcho.nominalBPM,
                                           sampleRate: sampleRate)
        readFrames = min(initial, capacity - 1)
        targetDelayFrames = readFrames
    }

    deinit {
        ring.deinitialize(count: capacity)
        ring.deallocate()
    }

    /// Apply the deck's echo control value, clamped into the §35A.2 ranges.
    /// Re-enabling the line clears the bypass immediately.
    public func setParams(_ echo: BeatEcho) {
        enabled = echo.enabled
        beats = min(BeatEcho.maxBeats, max(BeatEcho.minBeats, echo.beats))
        depth = min(BeatEcho.maxDepth, max(0, echo.depth))
        feedback = min(BeatEcho.maxFeedback, max(BeatEcho.minFeedback, echo.feedback))
        if enabled {
            isBypassed = false
            quietSamples = 0
        }
    }

    /// Retune the delay from the master clock (§35A.2). A changed delay
    /// **crossfades between read pointers over `crossfadeFrames`** rather than
    /// jumping — a pointer jump clicks. Repeated identical calls are no-ops
    /// (the render path recomputes the delay every callback from the master
    /// tempo, and a tempo that has not moved must not start a ramp).
    public func setDelayFrames(_ frames: Int) {
        let target = min(max(1, frames), capacity - 1)
        guard target != targetDelayFrames else { return }
        // A retune mid-crossfade continues from the delay currently ramping
        // toward, so a quick tempo change never snaps.
        crossfadeFrom = crossfading ? crossfadeTo : readFrames
        crossfadeTo = target
        crossfading = true
        crossfadePosition = 0
        targetDelayFrames = target
    }

    /// Process one sample. The echo is **post-fader, pre-crossfader** (§35A.1):
    /// the dry input is the post-fader signal and the wet tail survives a
    /// channel-fader cut. While disabled the line stops feeding but keeps
    /// reading its tail until it decays below the noise floor, then bypasses.
    @inline(__always)
    public func process(_ x: Float) -> Float {
        if isBypassed { return x }
        let old = ring[(writeIndex - readFrames + capacity) % capacity]
        let wet: Float
        if crossfading {
            let newest = ring[(writeIndex - crossfadeTo + capacity) % capacity]
            let t = Float(crossfadePosition) / Float(crossfadeFrames)
            wet = old * (1 - t) + newest * t
            crossfadePosition += 1
            if crossfadePosition >= crossfadeFrames {
                crossfading = false
                readFrames = crossfadeTo
            }
        } else {
            wet = old
        }
        // Feedback re-injects a fraction of the wet signal — hard-clamped
        // below unity, so the tail always decays (§35A.2).
        let input = enabled ? x : 0
        ring[writeIndex] = input + feedback * wet
        writeIndex = (writeIndex + 1) % capacity
        // The disabled tail is "done" only after a **full delay period** of
        // silence — a delay line is legitimately silent between echoes, so a
        // shorter quiet window would bypass mid-tail. Once quiet for that long,
        // the line bypasses entirely at zero cost (§35A.2).
        if !enabled && abs(wet) < Self.noiseFloor {
            quietSamples += 1
            if quietSamples > max(crossfadeFrames, targetDelayFrames) {
                isBypassed = true
            }
        } else {
            quietSamples = 0
        }
        return x + depth * wet
    }
}
