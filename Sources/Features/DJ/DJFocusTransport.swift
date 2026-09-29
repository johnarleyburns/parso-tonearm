import SwiftUI
import TonearmCore

struct DJFocusTransportRow: View {
    @ObservedObject var model: DJPerformanceModel

    var body: some View {
        HStack(spacing: 10) {
            Button { } label: {
                Label("CUE", systemImage: "headphones")
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
                .frame(maxWidth: .infinity, minHeight: 64)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in model.cueDown(model.activeDeck) }
                        .onEnded { _ in model.cueUp(model.activeDeck) }
                )
                .accessibilityAction { cue() }
                .accessibilityIdentifier("dj.focus.cue")
            Button("PLAY") { model.toggle(model.activeDeck) }
                .frame(maxWidth: .infinity, minHeight: 64)
                .accessibilityIdentifier("dj.focus.play")
            Button("SYNC") { model.toggleSync(model.activeDeck) }
                .frame(maxWidth: .infinity, minHeight: 64)
                .disabled(!DJSyncAvailabilityPolicy.canSync(bpm: model.deck(model.activeDeck).bpm))
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.6)
                        .onEnded { _ in model.makeMaster(model.activeDeck) }
                )
                .accessibilityIdentifier("dj.focus.sync")
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("dj.focus.transport")
    }

    private func cue() {
        model.cueDown(model.activeDeck)
        model.cueUp(model.activeDeck)
    }
}
