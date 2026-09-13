import SwiftUI

/// A 44 pt-minimum transport button with press/release semantics (CUE is a
/// hold-to-preview control, §33.1). Shared by the iPad workspace and the
/// compact solo/twin-deck surfaces (plan 4.7). `identifier` carries the §53.11
/// accessibility identifier when the control is part of a performance surface
/// (plan decision 27).
struct TransportButton: View {
    let title: String
    var emphasized = false
    var identifier: String?
    let action: () -> Void
    let onRelease: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .background(
                    emphasized ? AnyShapeStyle(Color.accentColor)
                               : AnyShapeStyle(Color.white.opacity(0.08)),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .foregroundStyle(emphasized ? .white : .primary)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0).onEnded { _ in onRelease() }
        )
        .accessibilityIdentifierIfPresent(identifier)
        .coachGlow(identifier: identifier)
    }
}

/// Apply a §53.11 accessibility identifier only when one is supplied — the
/// non-performance controls (SYNC, LOOP, bank chips) keep SwiftUI's default
/// identity instead of carrying an empty identifier.
private extension View {
    func accessibilityIdentifierIfPresent(_ identifier: String?) -> some View {
        if let identifier {
            return AnyView(self.accessibilityIdentifier(identifier))
        }
        return AnyView(self)
    }
}
