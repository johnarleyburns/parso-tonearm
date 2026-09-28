import SwiftUI
import TonearmCore

struct DJBothDecksLayout: View {
    @ObservedObject var model: DJPerformanceModel
    let onBack: () -> Void
    let onLoad: (DJDeckID) -> Void
    let onMixer: () -> Void
    let onOptions: (DJDeckID) -> Void

    @AppStorage("dj.layout") private var layout = "both"
    @AppStorage("dj.coachTips") private var coachTips = true

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
                HStack {
                    Button("Close", action: onBack)
                        .accessibilityIdentifier("dj.both.close")
                    Spacer()
                    Picker("Layout", selection: $layout) {
                        Text("Focus").tag("focus")
                        Text("Both decks").tag("both")
                    }
                    .pickerStyle(.segmented)
                    Spacer()
                    Button("Mixer", action: onMixer)
                        .accessibilityIdentifier("dj.both.mixer")
                }
                DJBothDeckPanel(model: model, deckID: .a, onLoad: onLoad, onOptions: onOptions)
                DJBothDeckPanel(model: model, deckID: .b, onLoad: onLoad, onOptions: onOptions)
                DJBothCrossfader(model: model)
                if coachTips {
                    DJCoachCard(model: model)
                }
            }
            .padding(16)
            .padding(.bottom, 34)
        }
        .background(Palette.bg)
        .foregroundStyle(Palette.ink)
    }
}

private struct DJBothCrossfader: View {
    @ObservedObject var model: DJPerformanceModel

    var body: some View {
        VStack(spacing: 4) {
            Text("CROSSFADER").font(.caption2.monospaced())
            Slider(value: binding)
                .tint(Palette.brass)
                .accessibilityIdentifier("dj.both.crossfader")
        }
        .padding(12)
        .djFocusGlass(cornerRadius: 18)
    }

    private var binding: Binding<Double> {
        Binding(get: { model.crossfader }, set: { model.setCrossfader($0) })
    }
}

private struct DJBothDeckPanel: View {
    @ObservedObject var model: DJPerformanceModel
    let deckID: DJDeckID
    let onLoad: (DJDeckID) -> Void
    let onOptions: (DJDeckID) -> Void

    var body: some View {
        let deck = model.deck(deckID)
        VStack(spacing: 8) {
            HStack {
                Text(deckID.rawValue).fontWeight(.black).foregroundStyle(deck.accent)
                Text(deck.title).lineLimit(1)
                Spacer()
                Button("Load") { onLoad(deckID) }
                    .accessibilityIdentifier("dj.both.load.\(deckID.rawValue.lowercased())")
                Button("•••") { onOptions(deckID) }
                    .accessibilityIdentifier("dj.both.options.\(deckID.rawValue.lowercased())")
            }
            WaveformCanvas(
                bins: deck.waveform,
                position: deck.position,
                duration: deck.duration,
                hotCues: deck.hotCues,
                isPlaying: deck.isPlaying,
                accent: deck.accent
            )
            .frame(height: 64)
            HStack {
                Button("CUE") { cue() }
                    .accessibilityIdentifier("dj.both.cue.\(deckID.rawValue.lowercased())")
                Button(deck.isPlaying ? "Pause" : "Play") { model.toggle(deckID) }
                    .accessibilityIdentifier("dj.both.play.\(deckID.rawValue.lowercased())")
                Button("SYNC") { model.toggleSync(deckID) }
                    .accessibilityIdentifier("dj.both.sync.\(deckID.rawValue.lowercased())")
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .djFocusGlass(cornerRadius: 22)
    }

    private func cue() {
        model.cueDown(deckID)
        model.cueUp(deckID)
    }
}
