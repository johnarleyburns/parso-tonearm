import Foundation

/// The sole Pro capability. Everything else — local playback, audio tools,
/// smart playlists, tag editing, iCloud sync, iPad+Mac — is free, permanently.
public enum ProFeature: String, CaseIterable {
    case remoteLibraries

    /// True when the current install is entitled to this feature. Reads the
    /// cached, UserDefaults-persisted verification result so airplane-mode users
    /// keep Pro (the StoreKit-verified value is refreshed by `ProStore`).
    public static func isEnabled(_ feature: ProFeature) -> Bool {
        ProEntitlement.isActive
    }
}
