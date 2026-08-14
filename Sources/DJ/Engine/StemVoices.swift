import Foundation

/// The four-voice stem set a deck reads when stems are armed (§35.1, plan
/// decision 3): the four `DeckSource`s of one track at the shared playhead,
/// summed with per-voice smoothed gains before the deck's EQ/filter/fader/
/// crossfader chain.
///
/// Like `DeckSource`, `StemSet` is a **pure value** — no references, no ARC —
/// so it crosses the RT boundary safely: the control side boxes it into a heap
/// allocation and hands the raw pointer over via `armStemSet`; the render
/// thread reads it with `UnsafeRawPointer.load(as: StemSet.self)`, a plain
/// memory load with no allocation, no lock and no retain (§12.3).
///
/// All four voices are the same track in the same sample space, so they share
/// one length and one grid (the deck's grid). A deck with **no** stem set is
/// byte-for-byte the current single-source reader — the full mix (§35.1,
/// plan decision 3: "a deck with no stem set is byte-for-byte the current
/// reader").
///
/// `@unchecked Sendable`: the contained `UnsafeRawPointer`s are not themselves
/// `Sendable`, but the value is immutable and never touches ARC, so crossing
/// the boundary as a raw pointer is exactly the intended transfer (§12.2).
public struct StemSet: @unchecked Sendable {
    public let vocals: DeckSource
    public let drums: DeckSource
    public let bass: DeckSource
    public let other: DeckSource

    public init(vocals: DeckSource, drums: DeckSource, bass: DeckSource,
                other: DeckSource) {
        precondition(vocals.frameCount == drums.frameCount
                     && vocals.frameCount == bass.frameCount
                     && vocals.frameCount == other.frameCount,
                     "the four stem voices of one track must have equal length")
        precondition(vocals.sampleRate == drums.sampleRate
                     && vocals.sampleRate == bass.sampleRate
                     && vocals.sampleRate == other.sampleRate,
                     "the four stem voices of one track must share a sample rate")
        self.vocals = vocals
        self.drums = drums
        self.bass = bass
        self.other = other
    }

    public func source(_ kind: StemKind) -> DeckSource {
        switch kind {
        case .vocals: return vocals
        case .drums: return drums
        case .bass: return bass
        case .other: return other
        }
    }

    /// The four voices' shared length (frames).
    public var frameCount: Int64 { vocals.frameCount }

    /// The set's grid — all four voices are the same track in the same sample
    /// space, so any voice's grid is the deck's grid. The loader builds every
    /// voice with the deck's authoritative grid (the `DeckSource` the full mix
    /// plays with), so this is the deck's grid exactly.
    public var grid: DeckGrid { vocals.grid }
}
