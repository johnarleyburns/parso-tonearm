import SwiftUI
import TonearmCore

struct DJFocusWaveformCard: View {
    @ObservedObject var model: DJPerformanceModel
    var onBrowse: (() -> Void)? = nil
    var compact = false

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(activeTitle).foregroundStyle(activeAccent)
                Spacer()
                Text("BAR \(barText)")
            }
            .font(.caption.monospaced())
            emptyState
            DJFocusWaveformRow(model: model, deckID: .a, compact: compact)
            DJFocusWaveformRow(model: model, deckID: .b, compact: compact)
            if !compact {
                Text("Drag a waveform to nudge · press and hold to scratch")
                .font(.caption2)
                .foregroundStyle(Palette.ink3)
            }
        }
        .padding(10)
        .frame(height: compact ? 104 : 190)
        .djFocusGlass(cornerRadius: 24)
        .overlay(alignment: .center) {
            if model.deckA.waveform.isEmpty == false || model.deckB.waveform.isEmpty == false {
                Rectangle()
                    .fill(Palette.ink)
                    .frame(width: 2, height: compact ? 76 : 132)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityIdentifier("dj.focus.waveform")
    }

    private var activeDeck: DJDeckState { model.deck(model.activeDeck) }
    private var activeTitle: String { activeDeck.row == nil ? "" : "\(activeDeck.id.rawValue) · WAVEFORM" }
    private var activeAccent: Color { activeDeck.accent }
    private var barText: String {
        guard let bpm = activeDeck.bpm, bpm > 0 else { return "—" }
        return String(format: "%.1f", activeDeck.position * bpm / 60 + 1)
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.deckA.row == nil, model.deckB.row == nil {
            VStack(spacing: 4) {
                Text("Load two tracks to start mixing")
                    .font(.caption)
                if let onBrowse {
                    Button("Browse Library", action: onBrowse)
                        .font(.caption.weight(.semibold))
                }
            }
        }
    }
}

private struct DJFocusWaveformRow: View {
    @ObservedObject var model: DJPerformanceModel
    let deckID: DJDeckID
    let compact: Bool
    @State private var dragStart = Date()
    @State private var lastTranslation: CGFloat = 0
    @State private var window = 4.0
    @State private var scratchStarted = false

    private var deck: DJDeckState { model.deck(deckID) }

    var body: some View {
        WaveformCanvas(
            bins: deck.waveform,
            position: deck.position,
            duration: deck.duration,
            hotCues: deck.hotCues,
            isPlaying: deck.isPlaying,
            accent: deck.accent,
            window: window
        )
        .frame(height: compact ? 38 : 62)
        .contentShape(Rectangle())
        .gesture(waveformGesture)
        .simultaneousGesture(
            MagnificationGesture().onChanged { value in
                window = max(2, min(16, 4 / value))
            }
        )
        .onTapGesture { model.selectDeck(deckID) }
        .accessibilityLabel("Deck \(deckID.rawValue) waveform")
        .accessibilityIdentifier("dj.focus.waveform.\(deckID.rawValue.lowercased())")
    }

    private var waveformGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if value.translation == .zero {
                    dragStart = Date()
                    lastTranslation = 0
                }
                let held = Date().timeIntervalSince(dragStart)
                if held >= 0.35, deck.isPlaying, !scratchStarted {
                    scratchStarted = true
                    model.beginScratch(deckID)
                }
                let delta = value.translation.width - lastTranslation
                lastTranslation = value.translation.width
                let action = DJWaveformTouchPolicy.action(
                    phase: deck.position,
                    isPlaying: deck.isPlaying,
                    touchMode: deck.vinyl ? .scratch : .nudge,
                    heldFor: held,
                    translation: delta,
                    width: 300
                )
                apply(action: action)
            }
            .onEnded { value in
                if !deck.isPlaying, DJWaveformTouchPolicy.shouldFlick(
                    translation: value.translation.width,
                    predictedTranslation: value.predictedEndTranslation.width) {
                    model.flick(deckID, translation: value.translation.width,
                                predictedTranslation: value.predictedEndTranslation.width, width: 300)
                }
                model.endScratch(deckID)
                scratchStarted = false
                lastTranslation = 0
                model.selectDeck(deckID)
            }
    }

    private func apply(action: DJWaveformTouchAction) {
        switch action {
        case .seek(let amount), .frameSearch(let amount):
            model.movePaused(deckID, by: amount, width: 300)
        case .nudge(let amount):
            model.nudge(deckID, direction: Double(amount))
        case .scratch(let amount):
            model.scratch(deckID, by: amount, width: 300)
        case .focus:
            model.selectDeck(deckID)
        case .flick, .none:
            break
        }
    }
}
