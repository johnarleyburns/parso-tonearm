import SwiftUI
import TonearmCore

struct DJMixerSheet: View {
    @ObservedObject var model: DJPerformanceModel
    @State private var page = 0

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Mixer").font(.title2.bold())
                Spacer()
                Toggle("Auto Gain", isOn: autoGainBinding)
                    .toggleStyle(.button)
                    .accessibilityIdentifier("dj.focus.mixer.autoGain")
                Button("Done") { dismiss() }
            }
            Picker("Mixer page", selection: $page) {
                Text("Channels").tag(0)
                Text("Master").tag(1)
            }
            .pickerStyle(.segmented)
            if page == 0 {
                DJMixerChannels(model: model)
            } else {
                DJMixerMaster(model: model)
            }
            Spacer()
        }
        .padding(18)
        .background(Palette.bg)
        .foregroundStyle(Palette.ink)
        .presentationDetents([.fraction(0.78), .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.78)))
        .presentationDragIndicator(.visible)
    }

    @Environment(\.dismiss) private var dismiss

    private var autoGainBinding: Binding<Bool> {
        Binding(get: { model.autoGain }, set: { model.autoGain = $0 })
    }
}

private struct DJMixerChannels: View {
    @ObservedObject var model: DJPerformanceModel

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                DJMixerChannel(model: model, deckID: .a)
                DJMixerChannel(model: model, deckID: .b)
            }
            Text("Master").font(.caption.monospaced())
            mixerSlider("Master", value: masterBinding)
            Text("Headphones").font(.caption.monospaced())
            mixerSlider("Headphones", value: headphoneBinding)
            mixerSlider("Cue ⇄ Master", value: cueMasterBinding)
        }
    }

    private func mixerSlider(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label).font(.caption.monospaced()).frame(width: 100, alignment: .leading)
            Slider(value: value)
            Text(String(format: "%d%%", Int(value.wrappedValue * 100)))
                .font(.caption.monospacedDigit()).frame(width: 48, alignment: .trailing)
        }
    }

    private var masterBinding: Binding<Double> {
        Binding(get: { model.masterLevel }, set: { model.setMasterLevel($0) })
    }

    private var headphoneBinding: Binding<Double> {
        Binding(get: { model.headphoneLevel }, set: { model.setHeadphoneLevel($0) })
    }

    private var cueMasterBinding: Binding<Double> {
        Binding(get: { model.cueMasterMix }, set: { model.setCueMasterMix(DJFaderMapping.snapped($0)) })
    }
}

private struct DJMixerChannel: View {
    @ObservedObject var model: DJPerformanceModel
    let deckID: DJDeckID

    var body: some View {
        let deck = model.deck(deckID)
        VStack(spacing: 8) {
            HStack {
                Text(deckID.rawValue).foregroundStyle(deck.accent).fontWeight(.black)
                Text(deck.title).lineLimit(1).font(.caption)
            }
            DJFocusKnob(label: "TRIM", value: deck.trim, color: deck.accent) { value in
                model.setTrim(deckID, value: value)
            }
            DJFocusKnob(label: "HI", value: deck.eqHigh, color: deck.accent) { value in
                model.setEQ(deckID, high: value)
            }
            DJFocusKnob(label: "MID", value: deck.eqMid, color: deck.accent) { value in
                model.setEQ(deckID, mid: value)
            }
            DJFocusKnob(label: "LOW", value: deck.eqLow, color: deck.accent) { value in
                model.setEQ(deckID, low: value)
            }
            DJFocusKnob(label: "FILTER", value: deck.colorFX, color: deck.accent) { value in
                model.setColorFX(deckID, value: value)
            }
            HStack(alignment: .center, spacing: 8) {
                DJFocusMeter(value: deck.peakMeter, hold: deck.peakHold)
                Slider(value: channelBinding(deck), in: 0...1)
                    .tint(deck.accent)
                    .rotationEffect(.degrees(-90))
                    .frame(width: 78, height: 28)
            }
            Button {
                model.toggleCue(deckID)
            } label: {
                Label((deckID == .a ? model.cueA : model.cueB) ? "Cue · listening" : "Cue", systemImage: "headphones")
                    .font(.caption2.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.bordered)
            .tint(deck.accent)
            .accessibilityIdentifier("dj.focus.mixer.cue.\(deckID.rawValue.lowercased())")
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
    }

    private func channelBinding(_ deck: DJDeckState) -> Binding<Double> {
        Binding(get: { deck.channelLevel }, set: { model.setChannelLevel(deckID, value: $0) })
    }
}

private struct DJMixerMaster: View {
    @ObservedObject var model: DJPerformanceModel

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                DJFocusKnob(label: "LOW", value: model.isolatorLow, color: Palette.brass) { value in
                    model.setIsolator(0, value: value)
                }
                DJFocusKnob(label: "MID", value: model.isolatorMid, color: Palette.brass) { value in
                    model.setIsolator(1, value: value)
                }
                DJFocusKnob(label: "HI", value: model.isolatorHigh, color: Palette.brass) { value in
                    model.setIsolator(2, value: value)
                }
            }
            .padding(10)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
            Button("Reset") { model.flatMix() }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("dj.focus.mixer.master.reset")
            Slider(value: bassBinding)
            Text("Swap basslines without touching the crossfader")
                .font(.caption2)
                .foregroundStyle(Palette.ink3)
            Picker("Output", selection: outputBinding) {
                ForEach(DJOutputMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text(model.outputMode.helpText).font(.caption2).foregroundStyle(Palette.ink3)
            Toggle("Record mix", isOn: recordingBinding)
            Text("Saved to Files › Platterhead").font(.caption2).foregroundStyle(Palette.ink3)
        }
    }

    private var bassBinding: Binding<Double> {
        Binding(get: { model.bassFader }, set: { model.setBass($0) })
    }

    private var outputBinding: Binding<DJOutputMode> {
        Binding(get: { model.outputMode }, set: { model.setOutputMode($0) })
    }

    private var recordingBinding: Binding<Bool> {
        Binding(get: { model.recording }, set: { _ in model.toggleRecording() })
    }
}

private struct DJFocusMeter: View {
    let value: Double
    let hold: Double

    var body: some View {
        VStack(spacing: 1) {
            ForEach((0..<16).reversed(), id: \.self) { index in
                let threshold = Double(index + 1) / 16
                Capsule()
                    .fill(color(for: index).opacity(threshold <= max(value, hold) ? 0.95 : 0.15))
                    .frame(width: 8, height: 4)
            }
        }
        .accessibilityLabel("Peak meter")
        .accessibilityValue(String(format: "%d%%", Int(max(value, hold) * 100)))
    }

    private func color(for index: Int) -> Color {
        if index >= 14 { return .red }
        if index >= 11 { return .yellow }
        return .green
    }
}

struct DJFocusKnob: View {
    let label: String
    let value: Double
    let color: Color
    let onChange: (Double) -> Void
    @State private var draft: Double
    @State private var sliderPresented = false

    init(label: String, value: Double, color: Color, onChange: @escaping (Double) -> Void) {
        self.label = label
        self.value = value
        self.color = color
        self.onChange = onChange
        _draft = State(initialValue: value)
    }

    var body: some View {
        VStack(spacing: 2) {
            Circle()
                .stroke(color, lineWidth: 3)
                .frame(width: 42, height: 42)
                .overlay(Text(DJKnobMapping.display(value)).font(.caption2.monospaced()))
                .gesture(DragGesture().onChanged { gesture in
                    let next = max(0, min(1, value - Double(gesture.translation.height / 120)))
                    onChange(next)
                })
                .onTapGesture(count: 2) { onChange(0.5) }
                .onLongPressGesture(minimumDuration: 0.35) {
                    draft = value
                    sliderPresented = true
                }
                .popover(isPresented: $sliderPresented) {
                    VStack(spacing: 10) {
                        Text(label).font(.caption.monospaced())
                        Slider(value: sliderBinding, in: 0...1)
                            .tint(color)
                            .frame(width: 180)
                        Text(DJKnobMapping.display(draft)).font(.caption.monospaced())
                    }
                    .padding(16)
                }
                .accessibilityLabel(label)
                .accessibilityValue(DJKnobMapping.display(value))
                .accessibilityAdjustableAction { direction in
                    let step = direction == .increment ? 0.01 : -0.01
                    onChange(max(0, min(1, value + step)))
                }
            Text(label).font(.caption2.monospaced())
        }
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { draft },
            set: { next in
                draft = next
                onChange(next)
            }
        )
    }
}
