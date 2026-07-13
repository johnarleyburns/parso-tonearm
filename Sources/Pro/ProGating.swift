import Foundation

/// Thin entitlement read for Pro capabilities. Product decisions live in the
/// feature-specific pure policy types, not here.
enum ProGating {
    static func isEnabled(_ feature: ProFeature) -> Bool {
        ProFeature.isEnabled(feature)
    }
}
