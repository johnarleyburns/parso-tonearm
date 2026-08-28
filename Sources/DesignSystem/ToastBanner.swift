import SwiftUI
import TonearmCore

/// The bottom-anchored pill `ToastCenter` renders. Keep it visually quiet — a capsule of
/// `.ultraThinMaterial`, an icon, one line of text.
struct ToastBanner: View {
    let toast: ToastCenter.Toast

    var body: some View {
        HStack(spacing: 9) {
            icon
            Text(toast.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.10)))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .padding(.horizontal, 20)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("toast")
    }

    @ViewBuilder
    private var icon: some View {
        switch toast.kind {
        case .progress:
            ProgressView().tint(Palette.brass).scaleEffect(0.8).frame(width: 16, height: 16)
        case .info:
            Image(systemName: toast.icon).font(.system(size: 14)).foregroundStyle(Palette.brass)
        case .success:
            Image(systemName: toast.icon).font(.system(size: 14)).foregroundStyle(Palette.ok)
        case .error:
            Image(systemName: toast.icon).font(.system(size: 14)).foregroundStyle(Palette.danger)
        }
    }
}

extension View {
    /// Overlays the current toast near the bottom edge, clear of the dock.
    func toastLayer(bottomInset: CGFloat) -> some View {
        modifier(ToastLayer(bottomInset: bottomInset))
    }
}

private struct ToastLayer: ViewModifier {
    @ObservedObject private var center = ToastCenter.shared
    let bottomInset: CGFloat

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let toast = center.current {
                ToastBanner(toast: toast)
                    .padding(.bottom, bottomInset)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: center.current)
    }
}
