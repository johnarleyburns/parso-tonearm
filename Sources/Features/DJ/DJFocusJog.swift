import SwiftUI
import TonearmCore

struct DJFocusJog: View {
    @ObservedObject var deck: DJDeckState
    let model: DJPerformanceModel
    @State private var lastAngle: Double = 0

    var body: some View {
        Circle()
            .fill(Color.black.opacity(0.55))
            .overlay(Circle().stroke(deck.accent, lineWidth: 3))
            .overlay(Text(timeText).font(.caption.monospaced()))
            .frame(width: 140, height: 140)
            .gesture(DragGesture().onChanged { value in
                let angle = atan2(value.location.y - 70, value.location.x - 70)
                model.jog(deck.id, angle: angle - lastAngle, outerRing: false)
                lastAngle = angle
            }.onEnded { _ in lastAngle = 0 })
            .accessibilityLabel("Deck \(deck.id.rawValue) jog wheel")
            .accessibilityIdentifier("dj.focus.jog.\(deck.id.rawValue.lowercased())")
    }

    private var timeText: String {
        let seconds = max(0, Int(deck.position))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
