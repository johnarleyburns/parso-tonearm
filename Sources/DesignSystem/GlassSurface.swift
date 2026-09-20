import SwiftUI

struct GlassSurface: ViewModifier {
    var cornerRadius: CGFloat = 18
    var strokeOpacity: Double = 0.13
    var fill: Color = Color.white.opacity(0.085)

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(reduceTransparency ? AnyShapeStyle(Color(hex: 0x1B1D22)) : AnyShapeStyle(.ultraThinMaterial))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(fill)
                    )
                    .allowsHitTesting(false)
            }
            .overlay {
                // Real report: "Settings -> Music Libraries does nothing" (also EQ,
                // Tools) — this stroke is purely decorative, but as a Shape-backed
                // overlay it otherwise sits above the card's own Button in z-order
                // and silently absorbs the tap before the Button's gesture ever
                // sees it, for any card where glassSurface wraps the Button/VStack
                // from the outside rather than living inside the label. Chrome must
                // never be hit-testable.
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(strokeOpacity), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension View {
    func glassSurface(cornerRadius: CGFloat = 18,
                      strokeOpacity: Double = 0.13,
                      fill: Color = Color.white.opacity(0.085)) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius, strokeOpacity: strokeOpacity, fill: fill))
    }
}
