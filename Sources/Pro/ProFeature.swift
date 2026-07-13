import Foundation

/// The set of Pro-gated *conveniences*. Identity features (formats incl. Opus,
/// near-gapless, IA sources, local import, privacy) are deliberately absent here
/// and must never be gated — `FreeTierRegistryTests` (T0.1) pins this contract.
enum ProFeature: String, CaseIterable {
    case cachePresets
    case prefetchDepth
    case folderWatch
    case eq
    case carplay
    case icloudSync

    /// True when the current install is entitled to this feature. Reads the
    /// cached, UserDefaults-persisted verification result so airplane-mode users
    /// keep Pro (the StoreKit-verified value is refreshed by `ProStore`).
    static func isEnabled(_ feature: ProFeature) -> Bool {
        ProEntitlement.isActive
    }
}
