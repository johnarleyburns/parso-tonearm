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
                    .accessibilityIdentifier("dj.both.layout")
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
        HStack(spacing: 8) {
            DJFocusKnob(label: "FILTER A", value: model.deckA.colorFX, color: model.deckA.accent) {
                model.setColorFX(.a, value: $0)
            }
            VStack(spacing: 4) {
                Text("A     CROSSFADER     B").font(.caption2.monospaced())
                Slider(value: binding)
                    .tint(Palette.brass)
                    .accessibilityIdentifier("dj.both.crossfader")
            }
            DJFocusKnob(label: "FILTER B", value: model.deckB.colorFX, color: model.deckB.accent) {
                model.setColorFX(.b, value: $0)
            }
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
                VStack(alignment: .leading, spacing: 1) {
                    Text(deck.title).lineLimit(1)
                    Text(deck.artist.isEmpty ? "Unknown artist" : deck.artist)
                        .font(.caption2).foregroundStyle(Palette.ink3).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(deck.bpm.map { String(format: "%.1f BPM", $0) } ?? "— BPM")
                        .font(.caption.monospacedDigit()).foregroundStyle(deck.accent)
                    Text("−" + remaining(deck.duration - deck.position))
                        .font(.caption2.monospacedDigit()).foregroundStyle(Palette.ink3)
                }
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
                    .disabled(!DJSyncAvailabilityPolicy.canSync(bpm: deck.bpm))
                    .accessibilityIdentifier("dj.both.sync.\(deckID.rawValue.lowercased())")
            }
            .buttonStyle(.bordered)
            HStack(spacing: 6) {
                ForEach(1...4, id: \.self) { slot in
                    Button(deck.hotCues[slot] == nil ? "(slot)" : "●") {
                        model.activateCue(slot, deck: deckID)
                    }
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(deck.hotCues[slot] == nil ? Color.white.opacity(0.06) : deck.accent,
                                in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(deck.hotCues[slot] == nil ? Palette.ink2 : Palette.bg)
                    .accessibilityIdentifier("dj.both.pad.\(deckID.rawValue.lowercased()).\(slot)")
                }
            }
        }
        .padding(12)
        .djFocusGlass(cornerRadius: 22)
    }

    private func cue() {
        model.cueDown(deckID)
        model.cueUp(deckID)
    }

    private func remaining(_ value: Double) -> String {
        let total = max(0, Int(value))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
