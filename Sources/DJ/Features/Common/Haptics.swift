import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Haptic confirmation for performance controls (NFR-A11Y-3: 44 pt minimum
/// targets, haptic confirm). A no-op on hosts without the Taptic engine —
/// macOS has no UIKit, so the SPM package still builds for the `swift test`
/// host (§2.5). Called from the main actor (the model's view-only actions,
/// never from a gesture on the render thread).
@MainActor
public enum Haptics {

    /// A brief medium-impact confirmation that a view-only action took.
    public static func confirm() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }

    /// A light transient fired per beat while a platter is held (§40.7.4).
    public static func beat() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    /// A heavier transient fired per downbeat while a platter is held
    /// (§40.7.4 — the accent that anchors the bar).
    public static func downbeat() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        #endif
    }
}
