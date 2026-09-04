import Foundation

/// Which of the two decks a call addresses. Extracted from the GPLv3
/// `PerformanceEngine.Deck` ahead of the Phase 6d cutover
/// (`parso-audio-engine/docs/phase6-parity.md`, "6c — carried into 6d" item 1)
/// so the `WorkspaceEngine` seam and `PAEWorkspaceEngine` no longer name a
/// type that lives on the deleted renderer.
public enum Deck: UInt8, Sendable, Hashable {
    case a = 0
    case b = 1
}
