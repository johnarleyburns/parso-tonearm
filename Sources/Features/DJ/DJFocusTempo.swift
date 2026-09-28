import SwiftUI
import TonearmCore

struct DJFocusTempoRow: View {
    @ObservedObject var model: DJPerformanceModel
    let onOptions: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button("−") { decrement() }
                .frame(width: 38, height: 38)
                .accessibilityIdentifier("dj.focus.tempo.down")
            Text(tempoText)
                .font(.caption.monospaced())
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
                .gesture(DragGesture().onChanged { value in dragTempo(value.translation.width) })
                .simultaneousGesture(TapGesture(count: 2).onEnded { resetTempo() })
            Button("+") { increment() }
                .frame(width: 38, height: 38)
                .accessibilityIdentifier("dj.focus.tempo.up")
            Button(action: toggleMasterTempo) {
                Label(keyText, systemImage: masterTempo ? "lock.fill" : "lock.open")
                    .font(.caption2.monospaced())
                    .frame(minHeight: 44)
            }
            .onLongPressGesture(minimumDuration: 0.6) {
                model.setPadMode(model.activeDeck, mode: .keyShift)
            }
            .accessibilityIdentifier("dj.focus.key")
            Button(action: onOptions) {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
            }
        }
        .accessibilityIdentifier("dj.focus.tempo")
    }

    private func decrement() {
        let deck = model.deck(model.activeDeck)
        model.setTempoPercent(deck.id, value: deck.tempoPercent - 0.1)
    }

    private func increment() {
        let deck = model.deck(model.activeDeck)
        model.setTempoPercent(deck.id, value: deck.tempoPercent + 0.1)
    }

    private var activeDeck: DJDeckState { model.deck(model.activeDeck) }
    private var tempoText: String {
        if activeDeck.syncEnabled { return String(format: "%.1f BPM · SYNC", activeDeck.tempo) }
        return String(format: "%.1f BPM · %+.1f%%", activeDeck.tempo, activeDeck.tempoPercent)
    }
    private var keyText: String { DJKeyFormatter.shifted(activeDeck.key, semitones: activeDeck.keyShiftSemitones) }
    private var masterTempo: Bool { activeDeck.masterTempo }

    private func toggleMasterTempo() { model.toggleMasterTempo(model.activeDeck) }
    private func resetTempo() { model.resetTempo(model.activeDeck) }
    private func dragTempo(_ width: CGFloat) {
        let deck = model.deck(model.activeDeck)
        model.setTempoPercent(deck.id, value: deck.tempoPercent + Double(width / 100))
    }
}
