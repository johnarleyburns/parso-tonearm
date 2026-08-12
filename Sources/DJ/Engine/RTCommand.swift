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
    }

    public var tag: Tag
    /// 0 = deck A, 1 = deck B (§12.2).
    public var deck: UInt8
    public var i0: Int64
    public var i1: Int64
    public var f0: Float
    public var f1: Float
    /// Ownership-transfer marker for an armed source (nil = none).
    public var ptr: UnsafeRawPointer?

    public init(tag: Tag = .play, deck: UInt8 = 0, i0: Int64 = 0, i1: Int64 = 0,
                f0: Float = 0, f1: Float = 0, ptr: UnsafeRawPointer? = nil) {
        self.tag = tag
        self.deck = deck
        self.i0 = i0
        self.i1 = i1
        self.f0 = f0
        self.f1 = f1
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
}
