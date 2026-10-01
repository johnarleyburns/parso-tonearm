import SwiftUI

/// Watch redesign §3 — a 40 pt capsule button (34 pt small). `.primary` is the accent fill with dark
/// ink; `.secondary` is the raised surface. Never an unstyled list row pretending to be a button.
struct WatchPillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }

    var kind: Kind = .secondary
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font((small ? Font.footnote : Font.body).weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: small ? WatchMetrics.smallPillHeight : WatchMetrics.pillHeight)
            .padding(.horizontal, 8)
            .background(Capsule().fill(background))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }

    private var foreground: Color {
        switch kind {
        case .primary: WatchPalette.accentInk
        case .secondary: .primary
        case .destructive: WatchPalette.failure
        }
    }

    private var background: Color {
        switch kind {
        case .primary: WatchPalette.accent
        case .secondary: WatchPalette.surfaceRaised
        case .destructive: WatchPalette.failure.opacity(0.16)
        }
    }
}

extension ButtonStyle where Self == WatchPillButtonStyle {
    static var watchPrimary: WatchPillButtonStyle { WatchPillButtonStyle(kind: .primary) }
    static var watchSecondary: WatchPillButtonStyle { WatchPillButtonStyle(kind: .secondary) }
    static var watchPrimarySmall: WatchPillButtonStyle { WatchPillButtonStyle(kind: .primary, small: true) }
    static var watchSecondarySmall: WatchPillButtonStyle { WatchPillButtonStyle(kind: .secondary, small: true) }
    static var watchDestructiveSmall: WatchPillButtonStyle { WatchPillButtonStyle(kind: .destructive, small: true) }
}
