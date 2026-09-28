import SwiftUI
import TonearmCore

struct DJDeckOptionsSheet: View {
    @ObservedObject var model: DJPerformanceModel
    let deck: DJDeckID
    let onInfo: () -> Void
    let onReanalyze: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let state = model.deck(deck)
        NavigationStack {
            Form {
                Section { Toggle("Key lock", isOn: Binding(get: { state.masterTempo }, set: { _ in model.toggleMasterTempo(deck) })); Toggle("Slip", isOn: Binding(get: { state.slip }, set: { _ in model.toggleDeckMode(deck, .slip) })); Toggle("Quantize", isOn: Binding(get: { state.quantize }, set: { _ in model.toggleDeckMode(deck, .quantize) })) }
                    .headerProminence(.increased)
                Section("Tempo range") {
                    Picker("Tempo range", selection: Binding(get: { state.tempoRange }, set: { state.tempoRange = $0 })) {
                        Text("±6").tag(6.0); Text("±10").tag(10.0); Text("±16").tag(16.0); Text("Wide").tag(100.0)
                    }.pickerStyle(.segmented)
                    HStack {
                        Button("Tap BPM") { model.tapTempo(deck) }.accessibilityIdentifier("dj.focus.options.tap")
                        Spacer()
                        Button("Reset tempo") { model.resetTempo(deck) }.accessibilityIdentifier("dj.focus.options.reset")
                        Spacer()
                        Button("Reverse") { model.toggleDeckMode(deck, .reverse) }
                            .tint(state.reverse ? Palette.brass : nil)
                            .accessibilityIdentifier("dj.focus.options.reverse")
                    }
                }
                Section("Waveform touch") {
                    Picker("Waveform touch", selection: Binding(get: { state.vinyl }, set: { _ in model.toggleDeckMode(deck, .vinyl) })) { Text("Nudge").tag(false); Text("Scratch").tag(true) }.pickerStyle(.segmented)
                }
                Section("Key") {
                    HStack { Button("−") { model.shiftKey(deck, by: -1) }; Text(DJKeyFormatter.shifted(state.key, semitones: state.keyShiftSemitones)).frame(maxWidth: .infinity); Button("+") { model.shiftKey(deck, by: 1) }; Button("Match \(deck == .a ? "B" : "A")") { model.toggleKeySync(deck) }.buttonStyle(.bordered) }
                    Button("Key shift pads…") { dismiss(); model.setPadMode(deck, mode: .keyShift) }
                        .accessibilityIdentifier("dj.focus.options.keyShift")
                }
                Section("Track") {
                    Button("Beat grid…") { dismiss(); model.setPadMode(deck, mode: .grid) }
                        .accessibilityIdentifier("dj.focus.options.grid")
                    Button("Reanalyze track") { dismiss(); onReanalyze() }
                        .accessibilityIdentifier("dj.focus.options.reanalyze")
                }
                Section {
                    Button("Help & gestures") { dismiss(); onInfo() }
                        .accessibilityIdentifier("dj.focus.options.help")
                }
            }
            .navigationTitle("Deck \(deck.rawValue)")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Palette.bg)
        .foregroundStyle(Palette.ink)
    }

}
