import SwiftUI

/// The mockup's one reusable knob visual, used for every knob (EQ, isolator, tempo, channel
/// volume) — only channel volume is interactive this pass (drag-to-adjust); the rest render at a
/// fixed rotation with no gesture at all. `value` is 0...1; `indicatorColor` matches the mockup's
/// two knob finishes (silver for most, warm gold for the isolator).
struct KnobView: View {
    var value: Double
    var indicatorColor: Color = .white
    /// The mockup's own size; callers in a tighter layout (a smaller landscape screen) pass a
    /// scaled-down value so the whole console still fits — see `DJConsoleView.scale(for:)`.
    var size: CGFloat = 28
    /// nil: static, no gesture. Non-nil: drag vertically to adjust (relative movement, not
    /// absolute position — per the interaction spec, a touch landing at the knob's edge must
    /// never jump the value).
    var onChange: ((Double) -> Void)?

    @State private var dragStartValue: Double?

    /// -135° at value 0 to +135° at value 1 (270° of travel), matching the mockup's dial.
    private var angle: Angle { .degrees(-135 + value * 270) }

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(colors: [Color(white: 0.9), Color(white: 0.4), Color(white: 0.18)],
                                   center: UnitPoint(x: 0.32, y: 0.25), startRadius: 0, endRadius: size * 20 / 28)
                )
                .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 1))
            Capsule()
                .fill(indicatorColor)
                .frame(width: 2, height: size * 10 / 28)
                .offset(y: -size * 8 / 28)
                .rotationEffect(angle)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { drag in
                    guard let onChange else { return }
                    let start = dragStartValue ?? value
                    if dragStartValue == nil { dragStartValue = value }
                    // 220pt of vertical travel for the full 0...1 range — a tuning starting
                    // point, not a spec (per the knob-interaction brief).
                    let delta = -drag.translation.height / 220
                    onChange(min(max(start + delta, 0), 1))
                }
                .onEnded { _ in dragStartValue = nil }
        )
        // Double-tap resets to the default, 12-o'clock position (value 0.5) — per the
        // knob-interaction brief. No-op on a static knob (no onChange).
        .onTapGesture(count: 2) { onChange?(0.5) }
    }
}
