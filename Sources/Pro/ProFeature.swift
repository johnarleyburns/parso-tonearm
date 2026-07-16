import Foundation

/// The set of Pro capabilities. On-device playback conveniences are deliberately
/// absent here and must never be gated.
public enum ProFeature: String, CaseIterable {
    case remoteLibraries
    case icloudSync
    case proAudioTools
    case smartPlaylists
    case tagEditor

    /// True when the current install is entitled to this feature. Reads the
    /// cached, UserDefaults-persisted verification result so airplane-mode users
    /// keep Pro (the StoreKit-verified value is refreshed by `ProStore`).
    public static func isEnabled(_ feature: ProFeature) -> Bool {
        ProEntitlement.isActive
    }
}
