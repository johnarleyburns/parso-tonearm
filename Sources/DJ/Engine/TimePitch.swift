import AudioToolbox
import AVFoundation
import Foundation

// MARK: - Pure time-pitch / key math (§31)

/// The pure cent↔rate conversions and the per-deck effective-pitch rule
/// (§31.1–31.3). All functions are deterministic and device-free so the
/// cent math is golden-pinned on every host (plan §5 commit 4.5).
public enum TimePitchMath {

    /// Playback rate for a tempo change in percent (`+1.2` → `1.012`, §31.1).
    public static func rateFromPercent(_ percent: Double) -> Double {
        1.0 + percent / 100.0
    }

    /// The pitch shift in cents a rate change implies — `1200·log2(r)` (§31.1).
    /// A deck reading PCM at `rate` sounds `centsFromRate(rate)` cents higher.
    public static func centsFromRate(_ rate: Double) -> Double {
        1200.0 * log2(max(rate, .leastNonzeroMagnitude))
    }

    /// Cents for an independent musical key shift in semitones (§31.3).
    public static func semitoneCents(_ semitones: Double) -> Double {
        100.0 * semitones
    }

    /// The `AVAudioUnitTimePitch.pitch` value (cents) a deck needs given its
    /// reader rate and key state.
    ///
    /// The deck reader is the tempo authority: it reads PCM at `rate`, which
    /// *also* shifts pitch up by `centsFromRate(rate)` — the vinyl behaviour
    /// (§31.1). The unit therefore carries only the **correction**:
    /// - key lock on — pitch held constant under tempo changes — applies the
    ///   inverse (`−centsFromRate(rate)`) so the reader's rate-pitch is
    ///   cancelled and the musical key stays put (§31.2);
    /// - key lock off — the vinyl behaviour — applies nothing (0 cents);
    /// - an independent key shift adds `100·semitones` on top, rate held
    ///   (§31.3).
    public static func pitchCents(rate: Double, keyLock: Bool,
                                  keyShiftSemitones: Double) -> Double {
        let lockCorrection = keyLock ? -centsFromRate(rate) : 0
        return lockCorrection + semitoneCents(keyShiftSemitones)
    }
}

// MARK: - Per-deck settings

/// The per-deck tempo/key state the render thread derives the time-pitch unit's
/// parameters from (§31). Pure value; only the render thread mutates the deck
/// state and reads this off it; the control side changes the deck state only
/// through `RTCommand`s.
public struct TimePitchSettings: Sendable, Equatable {
    /// The deck reader's playback rate (the tempo authority).
    public var rate: Double
    /// Key lock on — pitch held constant under tempo changes (§31.2).
    public var keyLock: Bool
    /// Independent musical key shift in semitones, rate held (§31.3).
    public var keyShiftSemitones: Double

    public init(rate: Double = 1, keyLock: Bool = false, keyShiftSemitones: Double = 0) {
        self.rate = rate
        self.keyLock = keyLock
        self.keyShiftSemitones = keyShiftSemitones
    }

    /// The `AVAudioUnitTimePitch.pitch` value in cents for these settings.
    public var unitPitchCents: Double {
        TimePitchMath.pitchCents(rate: rate, keyLock: keyLock,
                                 keyShiftSemitones: keyShiftSemitones)
    }

    /// The resulting key shift expressed as semitones (for the UI's Camelot
    /// hint, §31.3 / §28).
    public var effectiveKeyShiftSemitones: Double {
        unitPitchCents / 100.0
    }
}

// MARK: - The unit wrapper

/// One deck's `AVAudioUnitTimePitch` (§31, plan §5 commit 4.5).
///
/// The unit's **rate is held at 1.0**: the deck reader performs tempo
/// (frame-exact, §30.2) and the unit carries only the key compensation and key
/// shift (`pitch`). This is the frame-exact reader's contract (plan §2.5, 4.4
/// decision) reconciled with §31 — on a device graph that routes tempo through
/// the unit instead, the same `TimePitchMath` maps the controls, so the pure
/// math and the unit wrapper stay authoritative.
///
/// Parameters are set for music (§31.2): the unit's transient-preserving mode
/// is enabled explicitly and the overlap/smoothing is the music default.
/// `apply` is called from the render thread after commands are drained, so the
/// unit's pitch tracks the deck's current reader rate and key state at the
/// same callback boundary — the RT-safe AU-parameter path (no allocation, no
/// lock).
public final class TimePitchUnit: @unchecked Sendable {

    /// The engine node. Attach it to the `AVAudioEngine` and connect the deck
    /// source node through it (§29.1).
    public let node: AVAudioUnitTimePitch

    /// The pitch most recently applied — `apply` skips the AU set when nothing
    /// changed, so an idle deck costs no parameter traffic per callback.
    private var appliedPitch: Float?

    public init() {
        let node = AVAudioUnitTimePitch()
        node.rate = 1.0 // the deck reader is the tempo authority (see above)
        node.overlap = 8.0 // music overlap (§31.2)
        // Transient-preserving mode (§31.2) — default-on, asserted explicitly.
        if let tree = node.auAudioUnit.parameterTree {
            let parameters = tree.allParameters
            for parameter in parameters
            where parameter.address == UInt64(kNewTimePitchParam_EnableTransientPreservation) {
                parameter.setValue(1, originator: nil)
            }
        }
        self.node = node
    }

    /// Apply the deck's tempo/key state to the unit. Render-thread only.
    public func apply(_ settings: TimePitchSettings) {
        let pitch = Float(settings.unitPitchCents)
        if appliedPitch != pitch {
            node.pitch = pitch
            appliedPitch = pitch
        }
    }
}
