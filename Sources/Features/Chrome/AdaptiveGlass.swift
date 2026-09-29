import SwiftUI

/// Liquid Glass chrome lives only under Features/Chrome.
struct AdaptiveGlass: ViewModifier {
    var cornerRadius: CGFloat = 26
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Palette.surfaceRaised)
                    .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Palette.hairline, lineWidth: 1))
            )
        } else {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 8) {
                    content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                }
            } else {
                content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
            }
        }
    }
}

extension View {
    func adaptiveGlass(cornerRadius: CGFloat = 26) -> some View {
        modifier(AdaptiveGlass(cornerRadius: cornerRadius))
    }
}
