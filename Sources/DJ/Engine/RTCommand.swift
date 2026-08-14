import Foundation

/// The control word that crosses the main→render boundary (§12.2, normative).
///
/// `RTCommand` is a POD value: trivially copyable, fixed size, no ARC-managed
/// members. It is stored by value in `CommandRing`'s pre-allocated buffer and
/// is never locked or allocated by the render thread. The `UnsafeRawPointer`
/// payload is an ownership-transfer marker for a pre-armed source (deck PCM
/// buffer); the consumer owns the referenced memory for the duration of the
/// callback (§12.2, §46.2).
public struct RTCommand: @unchecked Sendable, Equatable {

    public enum Tag: UInt8, Sendable, Equatable {
        /// Start rendering the deck's armed source.
        case play
        /// Stop rendering; the deck's playhead freezes in place.
        case pause
        /// Set the deck's playback rate — `f0` carries the value (§31.1).
        case setRate
        /// Arm a pre-decoded source for the deck — `ptr` carries it (may be nil).
        case loadArm
        /// Move the playhead — `i0` = target track sample, `f0` = quantized flag.
        case seek
        /// Set the temporary CDJ cue point — `i0` = track sample (§33.1).
        case setCue
        /// Press the CUE transport: jump to the cue point and preview while held.
        case cuePress
        /// Release CUE: return to the pre-preview position and pause.
        case cueRelease
        /// Trigger a hot cue — `i0` = cue sample; honors the deck's quantize state.
        case triggerHotCue
        /// Engage a loop — `i0` = start, `i1` = end (half-open `[start, end)`).
        case setLoop
        /// Disengage the deck's loop; the playhead continues from the loop point.
        case exitLoop
        /// Set the deck's quantize state — `f0` = on, `f1` = resolution raw value.
        case setQuantize
        /// Set the deck's key-lock state — `f0` = locked (pitch held constant
        /// under tempo changes, §31.2).
        case setKeyLock
        /// Set the deck's independent musical key shift — `f0` = semitones
        /// (±N, §31.3).
        case setKeyShift
        /// Set the deck's 3-band EQ gains — `f0/f1/f2` = low/mid/high linear
        /// gains (§35.2).
        case setEQ
        /// Set the deck's sweep filter — `f0` = knob position (−1 … 1, §35.3).
        case setFilter
        /// Set the deck's channel fader (trim) — `f0` = gain (§35.4).
        case setFader
        /// Set the master crossfader — `f0` = position (−1 … 1), `f1` = curve
        /// raw value. Global; the deck slot is ignored.
        case setCrossfader
        /// Engage continuous beat sync — `f0` = master deck index (§32.1).
        /// While engaged the render thread re-derives the deck's rate each
        /// callback so its effective BPM tracks the master's.
        case sync
        /// Disengage sync; the deck returns to manual rate control.
        case unsync
        /// Phase-align nudge — `i0` = signed playhead shift in track samples
        /// (positive = forward). Applied as a scheduled, sample-accurate jump
        /// at the current callback boundary (§32.1).
        case syncNudge
        /// Set the deck's §35A echo on/off — `f0` = on (§35A.3).
        case setEchoEnabled
        /// Set the deck's §35A echo beat length — `f0` = beats (§35A.2).
        case setEchoBeats
        /// Set the deck's §35A echo wet depth — `f0` = depth, 0…1.
        case setEchoDepth
        /// Set the deck's §35A echo feedback — `f0` = tail length, 0…0.85.
        case setEchoFeedback
    }

    public var tag: Tag
    /// 0 = deck A, 1 = deck B (§12.2).
    public var deck: UInt8
    public var i0: Int64
    public var i1: Int64
    public var f0: Float
    public var f1: Float
    public var f2: Float
    /// Ownership-transfer marker for an armed source (nil = none).
    public var ptr: UnsafeRawPointer?

    public init(tag: Tag = .play, deck: UInt8 = 0, i0: Int64 = 0, i1: Int64 = 0,
                f0: Float = 0, f1: Float = 0, f2: Float = 0, ptr: UnsafeRawPointer? = nil) {
        self.tag = tag
        self.deck = deck
        self.i0 = i0
        self.i1 = i1
        self.f0 = f0
        self.f1 = f1
        self.f2 = f2
        self.ptr = ptr
    }

    public static func play(deck: UInt8) -> RTCommand {
        RTCommand(tag: .play, deck: deck)
    }

    public static func pause(deck: UInt8) -> RTCommand {
        RTCommand(tag: .pause, deck: deck)
    }

    /// `rate` is the deck's playback rate — 1.0 = normal, 2.0 = double speed
    /// (§31.1). The playhead advances `rate` track samples per output frame.
    public static func setRate(deck: UInt8, rate: Float) -> RTCommand {
        RTCommand(tag: .setRate, deck: deck, f0: rate)
    }

    public static func loadArm(deck: UInt8, source: UnsafeRawPointer?) -> RTCommand {
        RTCommand(tag: .loadArm, deck: deck, ptr: source)
    }

    public static func seek(deck: UInt8, toSample: Int64, quantized: Bool) -> RTCommand {
        RTCommand(tag: .seek, deck: deck, i0: toSample, f0: quantized ? 1 : 0)
    }

    public static func setCue(deck: UInt8, atSample: Int64) -> RTCommand {
        RTCommand(tag: .setCue, deck: deck, i0: atSample)
    }

    public static func cuePress(deck: UInt8) -> RTCommand {
        RTCommand(tag: .cuePress, deck: deck)
    }

    public static func cueRelease(deck: UInt8) -> RTCommand {
        RTCommand(tag: .cueRelease, deck: deck)
    }

    public static func triggerHotCue(deck: UInt8, atSample: Int64) -> RTCommand {
        RTCommand(tag: .triggerHotCue, deck: deck, i0: atSample)
    }

    public static func setLoop(deck: UInt8, start: Int64, end: Int64) -> RTCommand {
        RTCommand(tag: .setLoop, deck: deck, i0: start, i1: end)
    }

    public static func exitLoop(deck: UInt8) -> RTCommand {
        RTCommand(tag: .exitLoop, deck: deck)
    }

    public static func setQuantize(deck: UInt8, on: Bool, resolution: QuantizeResolution) -> RTCommand {
        RTCommand(tag: .setQuantize, deck: deck, f0: on ? 1 : 0, f1: Float(resolution.rawValue))
    }

    /// Set the deck's 3-band EQ gains — low/mid/high linear gains (§35.2).
    public static func setEQ(deck: UInt8, low: Float, mid: Float, high: Float) -> RTCommand {
        RTCommand(tag: .setEQ, deck: deck, f0: low, f1: mid, f2: high)
    }

    /// Set the deck's key-lock state — pitch held constant under tempo changes
    /// (§31.2).
    public static func setKeyLock(deck: UInt8, locked: Bool) -> RTCommand {
        RTCommand(tag: .setKeyLock, deck: deck, f0: locked ? 1 : 0)
    }

    /// Set the deck's independent musical key shift in semitones, rate held
    /// (§31.3).
    public static func setKeyShift(deck: UInt8, semitones: Float) -> RTCommand {
        RTCommand(tag: .setKeyShift, deck: deck, f0: semitones)
    }

    /// Set the deck's sweep filter knob (§35.3).
    public static func setFilter(deck: UInt8, knob: Float) -> RTCommand {
        RTCommand(tag: .setFilter, deck: deck, f0: knob)
    }

    /// Set the deck's channel fader (trim) gain (§35.4).
    public static func setFader(deck: UInt8, gain: Float) -> RTCommand {
        RTCommand(tag: .setFader, deck: deck, f0: gain)
    }

    /// Set the master crossfader position and curve (§35.4).
    public static func setCrossfader(position: Float, curve: CrossfaderCurve) -> RTCommand {
        RTCommand(tag: .setCrossfader, deck: 0, f0: position, f1: curve.rawValue)
    }

    /// Engage continuous beat sync for a deck, with `master` as the tempo and
    /// phase reference (§32.1).
    public static func sync(deck: UInt8, master: UInt8) -> RTCommand {
        RTCommand(tag: .sync, deck: deck, f0: Float(master))
    }

    /// Disengage sync; the deck returns to manual rate control (§32.1).
    public static func unsync(deck: UInt8) -> RTCommand {
        RTCommand(tag: .unsync, deck: deck)
    }

    /// Phase-align the deck with a signed playhead shift in track samples
    /// (§32.1).
    public static func syncNudge(deck: UInt8, shiftSamples: Int64) -> RTCommand {
        RTCommand(tag: .syncNudge, deck: deck, i0: shiftSamples)
    }

    /// Set the deck's §35A beat-synced echo on/off (§35A.3).
    public static func setEchoEnabled(deck: UInt8, enabled: Bool) -> RTCommand {
        RTCommand(tag: .setEchoEnabled, deck: deck, f0: enabled ? 1 : 0)
    }

    /// Set the deck's §35A echo beat length (1/4 … 4, §35A.2).
    public static func setEchoBeats(deck: UInt8, beats: Double) -> RTCommand {
        RTCommand(tag: .setEchoBeats, deck: deck, f0: Float(beats))
    }

    /// Set the deck's §35A echo wet depth (0…1, §35A.2).
    public static func setEchoDepth(deck: UInt8, depth: Float) -> RTCommand {
        RTCommand(tag: .setEchoDepth, deck: deck, f0: depth)
    }

    /// Set the deck's §35A echo feedback — tail length, 0…0.85 (clamped below
    /// unity, §35A.2).
    public static func setEchoFeedback(deck: UInt8, feedback: Float) -> RTCommand {
        RTCommand(tag: .setEchoFeedback, deck: deck, f0: feedback)
    }
}
