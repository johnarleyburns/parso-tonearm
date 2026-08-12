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
        /// Set the deck's playback pitch/rate — `f0` carries the value.
        case setPitch
        /// Arm a pre-decoded source for the deck — `ptr` carries it (may be nil).
        case loadArm
    }

    public var tag: Tag
    /// 0 = deck A, 1 = deck B (§12.2).
    public var deck: UInt8
    public var i0: Int64
    public var f0: Float
    public var f1: Float
    /// Ownership-transfer marker for an armed source (nil = none).
    public var ptr: UnsafeRawPointer?

    public init(tag: Tag = .play, deck: UInt8 = 0, i0: Int64 = 0,
                f0: Float = 0, f1: Float = 0, ptr: UnsafeRawPointer? = nil) {
        self.tag = tag
        self.deck = deck
        self.i0 = i0
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

    /// `frequency` is a pitch/rate value in the command's owning domain (for
    /// the 4.1 harness: a sine frequency in Hz; later commits carry tempo rate).
    public static func setPitch(deck: UInt8, frequency: Float) -> RTCommand {
        RTCommand(tag: .setPitch, deck: deck, f0: frequency)
    }

    public static func loadArm(deck: UInt8, source: UnsafeRawPointer?) -> RTCommand {
        RTCommand(tag: .loadArm, deck: deck, ptr: source)
    }
}
