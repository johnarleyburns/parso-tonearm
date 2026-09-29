import SwiftUI
import TonearmCore

private struct DJFocusTempoNudgeButton: View {
    let title: String
    let identifier: String
    let action: () -> Void
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        Text(title)
            .font(.body.weight(.semibold))
            .frame(width: 38, height: 38)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in startRepeating() }
                .onEnded { _ in stopRepeating() })
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier(identifier)
            .accessibilityAction { action() }
            .onDisappear { stopRepeating() }
    }

    private func startRepeating() {
        guard repeatTask == nil else { return }
        action()
        repeatTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(DJTempoNudgePolicy.repeatDelayMilliseconds))
            while !Task.isCancelled {
                action()
                try? await Task.sleep(for: .milliseconds(DJTempoNudgePolicy.repeatIntervalMilliseconds))
            }
        }
    }

    private func stopRepeating() {
        repeatTask?.cancel()
        repeatTask = nil
    }
}

struct DJFocusTempoRow: View {
    @ObservedObject var model: DJPerformanceModel
    let onOptions: () -> Void
    @State private var finePresented = false
    @State private var fineDraft = 0.0

    var body: some View {
        HStack(spacing: 8) {
            DJFocusTempoNudgeButton(title: "−", identifier: "dj.focus.tempo.down", action: decrement)
            Text(tempoText)
                .font(.caption.monospaced())
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
                .gesture(DragGesture().onChanged { value in dragTempo(value.translation.width) })
                .simultaneousGesture(TapGesture(count: 2).onEnded { resetTempo() })
                .onLongPressGesture(minimumDuration: 0.35) {
                    fineDraft = activeDeck.tempoPercent
                    finePresented = true
                }
                .popover(isPresented: $finePresented) {
                    VStack(spacing: 10) {
                        Text("Fine tempo").font(.caption.monospaced())
                        Slider(value: fineBinding, in: -activeDeck.tempoRange...activeDeck.tempoRange)
                        Text(String(format: "%+.2f%%", fineDraft)).font(.caption.monospaced())
                    }
                    .padding(16)
                    .frame(width: 220)
                }
            DJFocusTempoNudgeButton(title: "+", identifier: "dj.focus.tempo.up", action: increment)
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
        model.setTempoPercent(deck.id, value: DJTempoNudgePolicy.nudgedValue(
            current: deck.tempoPercent, direction: -1, range: deck.tempoRange))
    }

    private func increment() {
        let deck = model.deck(model.activeDeck)
        model.setTempoPercent(deck.id, value: DJTempoNudgePolicy.nudgedValue(
            current: deck.tempoPercent, direction: 1, range: deck.tempoRange))
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
        guard !activeDeck.syncEnabled else { return }
        let deck = model.deck(model.activeDeck)
        model.setTempoPercent(deck.id, value: deck.tempoPercent + Double(width / 100))
    }

    private var fineBinding: Binding<Double> {
        Binding(get: { fineDraft }, set: { value in
            fineDraft = value
            model.setTempoPercent(model.activeDeck, value: value)
        })
    }
}
