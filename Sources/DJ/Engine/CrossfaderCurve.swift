import Foundation

/// The crossfader blend curve (§35.4). Extracted from the GPLv3 `Mixer.swift`
/// ahead of the Phase 6d cutover (`parso-audio-engine/docs/phase6-parity.md`,
/// "6d backlog") — the enum names are original work and stay; the render-side
/// `crossfaderGains(_:_:)` math it used to drive is GPLv3 and does not (PAE's
/// own crossfade-curve math is the reference post-cutover, per the Phase 6
/// author decision).
public enum CrossfaderCurve: Float, Sendable, CaseIterable {
    /// Equal-power blend: `gA² + gB² == 1` at every position.
    case constantPower = 0
    /// Equal-amplitude blend: `gA + gB == 1`.
    case linear = 1
    /// Hard cut with a small overlap for scratch-style chops.
    case sharp = 2
}
