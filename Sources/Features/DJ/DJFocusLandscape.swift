import SwiftUI
import TonearmCore

struct DJFocusLandscape: View {
    @ObservedObject var model: DJPerformanceModel
    let onBack: () -> Void
    let onInfo: () -> Void
    let onLoad: (DJDeckID) -> Void
    let onMixer: () -> Void
    let onOptions: (DJDeckID) -> Void

    var body: some View {
        VStack(spacing: 10) {
            DJFocusWaveformCard(model: model)
                .frame(height: 96)
            HStack(spacing: 12) {
                DJLandscapeDeck(model: model, deckID: .a, onOptions: onOptions)
                DJLandscapeMiddle(model: model, onMixer: onMixer)
                DJLandscapeDeck(model: model, deckID: .b, onOptions: onOptions)
            }
        }
        .padding(14)
        .background(Palette.bg)
        .foregroundStyle(Palette.ink)
    }
}

private struct DJLandscapeDeck: View {
    @ObservedObject var model: DJPerformanceModel
    let deckID: DJDeckID
    let onOptions: (DJDeckID) -> Void

    var body: some View {
        let deck = model.deck(deckID)
        VStack(spacing: 8) {
            HStack {
                Text(deckID.rawValue).foregroundStyle(deck.accent).fontWeight(.black)
                Text(deck.title).lineLimit(1)
                Spacer()
                Button("•••") { onOptions(deckID) }
                    .accessibilityIdentifier("dj.focus.landscape.options.\(deckID.rawValue.lowercased())")
            }
            DJFocusJog(deck: deck, model: model)
            DJFocusLandscapePads(model: model, deckID: deckID)
            HStack {
                Button("CUE") { cue() }
                    .accessibilityIdentifier("dj.focus.landscape.cue.\(deckID.rawValue.lowercased())")
                Button(deck.isPlaying ? "Pause" : "Play") { model.toggle(deckID) }
                    .accessibilityIdentifier("dj.focus.landscape.play.\(deckID.rawValue.lowercased())")
                Button("SYNC") { model.toggleSync(deckID) }
                    .accessibilityIdentifier("dj.focus.landscape.sync.\(deckID.rawValue.lowercased())")
            }
            .buttonStyle(.bordered)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .djFocusGlass(cornerRadius: 22)
    }

    private func cue() {
        model.cueDown(deckID)
        model.cueUp(deckID)
    }
}

private struct DJLandscapeMiddle: View {
    @ObservedObject var model: DJPerformanceModel
    let onMixer: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("MIXER").font(.caption.monospaced())
            Button("Mixer", action: onMixer)
                .accessibilityIdentifier("dj.focus.landscape.mixer")
            Slider(value: binding)
                .tint(Palette.brass)
        }
        .padding(12)
        .frame(width: 150)
        .djFocusGlass(cornerRadius: 22)
    }

    private var binding: Binding<Double> {
        Binding(get: { model.crossfader }, set: { model.setCrossfader($0) })
    }
}
