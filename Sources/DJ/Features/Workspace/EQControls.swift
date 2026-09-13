import SwiftUI

/// A deck's three EQ knobs (§41.9b — the compact surfaces' EQ bank keeps the
/// three-in-a-row form where the full channel strip does not fit). The knobs
/// carry the §53.11 per-band identifiers for the deck they belong to.
struct EQGroup: View {
    let title: String
    let deckID: String
    let low: Float
    let mid: Float
    let high: Float
    let onChanged: (Float, Float, Float) -> Void

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.secondary)
            HStack(spacing: 7) {
                EQKnob(label: "HI", value: high,
                       identifier: "dj.deck.\(deckID).eq.high") { onChanged(low, mid, $0) }
                EQKnob(label: "MID", value: mid,
                       identifier: "dj.deck.\(deckID).eq.mid") { onChanged(low, $0, high) }
                EQKnob(label: "LOW", value: low,
                       identifier: "dj.deck.\(deckID).eq.low") { onChanged($0, mid, high) }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// A 44 pt minimum rotary knob driven by a vertical drag. The dial renders
/// −1 … +1 across ±135°; the centre detent (kill→unity→+6 dB) is §35.2's
/// mapping — the knob itself is linear knob position. `identifier` carries the
/// §53.11 accessibility identifier on performance surfaces.
struct EQKnob: View {
    let label: String
    let value: Float
    var identifier: String?
    let onChanged: (Float) -> Void

    @State private var dragStart: Float?

    var body: some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.08))
                Circle()
                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 2, height: 9)
                    .offset(y: -13)
                    .rotationEffect(.degrees(Double(value) * 135))
            }
            .frame(width: 40, height: 40)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if dragStart == nil { dragStart = value }
                        let start = dragStart ?? value
                        let delta = Float(gesture.translation.height) / 60
                        let clamped = min(1, max(-1, start - delta))
                        onChanged(clamped)
                    }
                    .onEnded { _ in dragStart = nil }
            )
        }
        .frame(width: 44, height: 44)
        .performanceControl(identifier, label: label, value: value)
        .coachGlow(identifier: identifier)
    }
}

/// A vertical drag fader for the channel strips (§35.4) and the compact
/// surface's filter bank (plan 4.7). `identifier` carries the §53.11
/// accessibility identifier on performance surfaces.
struct VerticalSlider: View {
    let value: Float
    var identifier: String?
    let onChanged: (Float) -> Void

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(Color.accentColor.opacity(0.85))
                    .frame(height: max(4, height * CGFloat(clamp(0, (value + 1) / 2, 1))))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { gesture in
                    let t = 1 - gesture.location.y / height
                    onChanged(clamp(-1, Float(t) * 2 - 1, 1))
                }
            )
        }
        .performanceControl(identifier, label: "Fader", value: value)
        .coachGlow(identifier: identifier)
    }
}
private func clamp<T: Comparable>(_ minimum: T, _ value: T, _ maximum: T) -> T {
    min(max(value, minimum), maximum)
}
