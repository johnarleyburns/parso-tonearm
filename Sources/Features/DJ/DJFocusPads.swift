import SwiftUI
import TonearmCore

struct DJPadTabsAndGrid: View {
    @ObservedObject var model: DJPerformanceModel
    @State private var deleting: Int?
    var body: some View {
        let deck = model.deck(model.activeDeck)
        VStack(spacing: 8) {
            if deck.padMode == .keyShift || deck.padMode == .grid {
                HStack {
                    Text(deck.padMode == .keyShift ? "Key shift — Deck \(deck.id.rawValue)" : "Beat grid — Deck \(deck.id.rawValue)")
                    Spacer()
                    Button("Done") { model.setPadMode(deck.id, mode: deck.previousPadMode) }
                }
                .font(.system(size: 13, weight: .semibold)).padding(.horizontal, 13).frame(height: 40)
                .djFocusGlass(cornerRadius: 20)
            } else {
                HStack(spacing: 2) {
                    ForEach(DJPerformPages.tabs, id: \.mode) { tab in
                        Button(tab.title) { select(tab.mode, deck: deck) }
                            .font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 34)
                            .foregroundStyle(selected(tab.mode, current: deck.padMode) ? Palette.bg : Palette.ink2)
                            .background(selected(tab.mode, current: deck.padMode) ? Palette.ink : Color.clear, in: RoundedRectangle(cornerRadius: 17))
                            .accessibilityIdentifier("dj.focus.padtab.\(tab.mode.rawValue)")
                    }
                }
                .padding(3).djFocusGlass(cornerRadius: 20)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(0..<8, id: \.self) { index in pad(index, deck: deck) }
            }
            .opacity(deck.row == nil ? 0.4 : 1)
        }
        .animation(.easeInOut(duration: 0.18), value: deck.padMode)
    }

    private func selected(_ tab: DJPadMode, current: DJPadMode) -> Bool {
        switch tab { case .beatLoop: return current == .beatLoop || current == .loop; case .fx: return current == .fx || current == .beatFX; default: return tab == current }
    }

    private func select(_ mode: DJPadMode, deck: DJDeckState) {
        if mode == .beatLoop { model.setPadMode(deck.id, mode: deck.padMode == .beatLoop ? .loop : .beatLoop) }
        else if mode == .fx { model.setPadMode(deck.id, mode: .fx) }
        else { model.setPadMode(deck.id, mode: mode) }
    }

    private func pad(_ index: Int, deck: DJDeckState) -> some View {
        let state = DJPadLabelState(hotCuePosition: deck.hotCues[index + 1], activeLoopBeats: activeBeats(deck),
                                    loopLength: model.loopLengthLabel(deck.id), loopExitPending: deck.loopExitPending,
                                    echoOutArmed: deck.echoOutArmed, beatFXType: "Echo", beatFXOn: model.beatFXOn,
                                    beatFXDepth: model.beatFXDepth)
        let label = DJPerformPages.padLabel(mode: deck.padMode, index: index, state: state)
        return Button {
            model.setPadAction(deck.id, index: index)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(label.title).font(.system(size: 15, weight: .bold)).lineLimit(1)
                Spacer(minLength: 0)
                Text(label.caption).font(.system(size: 11, design: .monospaced)).lineLimit(1)
            }
            .foregroundStyle(padForeground(deck: deck, index: index))
            .padding(.horizontal, 11).padding(.vertical, 10).frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
            .background(padFill(deck: deck, index: index), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(padBorder(deck: deck, index: index), style: StrokeStyle(lineWidth: 1.5, dash: deck.padMode == .hotCue && deck.hotCues[index + 1] == nil ? [5] : [])))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(LongPressGesture(minimumDuration: 1).onEnded { _ in
            if deck.padMode == .hotCue, deck.hotCues[index + 1] != nil { deleting = index; model.deleteCue(index + 1, deck: deck.id) }
        })
        .accessibilityLabel("\(label.title), \(label.caption)")
        .accessibilityIdentifier("dj.focus.pad.\(index + 1)")
    }

    private func activeBeats(_ deck: DJDeckState) -> Double? {
        guard deck.loopActive, let start = deck.loopIn, let end = deck.loopOut else { return nil }
        return (end - start) * deck.tempo / 60
    }
    private func padForeground(deck: DJDeckState, index: Int) -> Color {
        if deck.padMode == .hotCue { return deck.hotCues[index + 1] == nil ? Palette.brass : Palette.bg }
        if deck.padMode == .beatLoop { return activeBeats(deck) == DJPerformPages.autoLoopBeats[index] ? Palette.bg : Color(red: 0.55, green: 0.92, blue: 0.80) }
        return Palette.ink
    }
    private func padFill(deck: DJDeckState, index: Int) -> Color {
        if deck.padMode == .hotCue, deck.hotCues[index + 1] != nil { return [Palette.brass, .red, .purple, .blue, .green, .yellow, .pink, .cyan][index] }
        if deck.padMode == .beatLoop { return activeBeats(deck) == DJPerformPages.autoLoopBeats[index] ? Color(red: 0.24, green: 0.84, blue: 0.65) : Color(red: 0.24, green: 0.84, blue: 0.65).opacity(0.12) }
        return Color.white.opacity(0.07)
    }
    private func padBorder(deck: DJDeckState, index: Int) -> Color {
        deck.padMode == .hotCue && deck.hotCues[index + 1] == nil ? Palette.brass.opacity(0.75) : Color.white.opacity(0.12)
    }
}
