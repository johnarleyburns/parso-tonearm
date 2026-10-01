import SwiftUI
import WatchKit

/// Watch redesign §3 — a round transport control. Play/pause is 58 pt and filled with `.primary`;
/// side buttons are 44 pt on a translucent fill. `isBusy` swaps the glyph for a spinner, so the face
/// never shows a pause icon before audio is confirmed (§2 principle 3).
struct WatchTransportButton: View {
    enum Role { case primary, side }

    let systemImage: String
    /// Required: an icon-only control is always labelled for VoiceOver.
    let label: Text
    var role: Role = .side
    var isBusy = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button {
            WKInterfaceDevice.current().play(.click)
            action()
        } label: {
            ZStack {
                Circle().fill(role == .primary ? AnyShapeStyle(Color.primary) : AnyShapeStyle(WatchPalette.control))
                if isBusy {
                    ProgressView()
                        .tint(role == .primary ? .black : .primary)
                } else {
                    Image(systemName: systemImage)
                        .font(role == .primary ? .title2.weight(.bold) : .title3.weight(.semibold))
                        .foregroundStyle(role == .primary ? Color.black : Color.primary)
                }
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .disabled(!isEnabled || isBusy)
        .opacity(isEnabled ? 1 : 0.35)
    }

    private var diameter: CGFloat {
        role == .primary ? WatchMetrics.playButton : WatchMetrics.sideButton
    }
}

/// A 30 pt round toolbar button for the Now Playing bottom bar (Output · Up Next · More).
struct WatchToolButton: View {
    let systemImage: String
    /// Required: an icon-only control is always labelled for VoiceOver.
    let label: Text
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isOn ? WatchPalette.accent : Color.primary)
                .frame(width: WatchMetrics.toolButton, height: WatchMetrics.toolButton)
                .background(Circle().fill(isOn ? WatchPalette.accentSoft : WatchPalette.control))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
