import SwiftUI

/// The §41.18 coach's highlight set — the §53.11 identifiers of the real
/// controls the selected transition moves. Empty while the coach is closed.
/// The performance surfaces set this from
/// `TransitionCoachModel.highlightedIdentifiers`; the shared controls read it
/// and draw the glowing ring around the controls they light (FR-TRANS-6,
/// "highlighted in place").
private struct CoachHighlightsKey: EnvironmentKey {
    static let defaultValue: Set<String> = []
}

extension EnvironmentValues {
    /// The §41.18 highlight set in effect — empty when the coach is closed.
    public var coachHighlights: Set<String> {
        get { self[CoachHighlightsKey.self] }
        set { self[CoachHighlightsKey.self] = newValue }
    }
}

/// The §41.18 "highlight the real control in place" treatment: a glowing ring
/// around a control whose §53.11 identifier is in the current
/// `coachHighlights` set. Draws nothing when the coach is closed (the set is
/// empty) or the identifier is not part of the selected lesson — so the glow
/// can never be wrong, only the controls the lesson names.
private struct CoachGlowModifier: ViewModifier {
    @Environment(\.coachHighlights) private var coachHighlights
    let identifier: String?

    func body(content: Content) -> some View {
        if let identifier, coachHighlights.contains(identifier) {
            content.overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(Color.accentColor.opacity(0.95), lineWidth: 2.5)
                    .shadow(color: Color.accentColor.opacity(0.75), radius: 5)
                    .padding(-4)
                    .allowsHitTesting(false)
            }
        } else {
            content
        }
    }
}

extension View {
    /// Light this control when its §53.11 identifier is in the coach's
    /// highlight set — the "real controls in place" teaching highlight
    /// (§41.18, FR-TRANS-6). Pass the same identifier the control already
    /// carries for accessibility; a nil identifier never highlights.
    public func coachGlow(identifier: String?) -> some View {
        modifier(CoachGlowModifier(identifier: identifier))
    }
}
