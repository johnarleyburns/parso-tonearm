import Foundation

/// Deterministic 64-bit SplitMix64 PRNG — moved here from the DJ-mixer-era
/// `PlaylistSequencer.swift` (deleted as orphaned dead code, never reachable
/// from the live app) when that file was removed. Several still-live test
/// suites (`DSPTests`, `StemCacheTests`, `StemSeparatorTests`,
/// `RecallGateTests`) use it purely for reproducible synthetic fixtures —
/// same seed, same bytes, never ambient entropy — so it stays as shared test
/// infrastructure rather than product code now that nothing under
/// `Sources/DJ` constructs it.
struct SplitMix64: Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension SplitMix64: RandomNumberGenerator {
    /// SplitMix64's `next()` already yields full 64-bit words, so the type is
    /// a drop-in `RandomNumberGenerator` — the standard `random(in:using:)`
    /// family becomes deterministic too.
}
