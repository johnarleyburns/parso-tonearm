import SwiftUI

/// A horizontal fader for the §41.9a per-deck jog sensitivity (§40.7.4,
/// 0.5–2.0). Maps the value linearly onto the track; the whole strip is the
/// drag surface. Compact so it sits under the §41.9b pad block without
/// disturbing the club geometry.
struct JogSensitivitySlider: View {
    let value: Double
    let onChanged: (Double) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("JOG")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
            GeometryReader { proxy in
                let width = proxy.size.width
                let t = CGFloat((value - 0.5) / 1.5)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10)).frame(height: 6)
                    Capsule().fill(Color.accentColor.opacity(0.9))
                        .frame(width: 18, height: 18)
                        .offset(x: max(0, min(width - 18, width * t - 9)))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { gesture in
                        let u = Self.clampUnit(gesture.location.x / width)
                        onChanged(0.5 + 1.5 * Double(u))
                    }
                )
            }
            .frame(height: 24)
            Text(String(format: "%.1f", value))
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 22)
        }
    }

    private static func clampUnit(_ value: CGFloat) -> CGFloat {
        max(0, min(1, value))
    }
}
