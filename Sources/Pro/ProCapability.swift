import Foundation

/// The Pro capability set (Appendix T.3). The gate is checked at intent
/// boundaries in view models — never inside the engine — and every capability
/// shares the single `EntitlementStore.isPro` boolean, because there is still
/// exactly one thing to buy.
///
/// Through M0 nothing is gated: the enum exists and `isPro` is observable,
/// nothing more (handoff §5.2, commit 0.5). A capability added here must land
/// in `FreeTierRegistryTests`' expected paid set and never on the free list
/// (Appendix T.5).
public enum ProCapability: String, CaseIterable, Sendable {
    case decks
    case mixer
    case stems
    case recording
    case hardware
    case preparation
    case gigCrates

    /// The single gate (T.3): a capability is enabled exactly when the user has
    /// Pro. Checked at intent boundaries, never on the real-time path.
    @MainActor
    public static func isEnabled(_ capability: ProCapability, _ store: EntitlementStore) -> Bool {
        store.isPro
    }
}
