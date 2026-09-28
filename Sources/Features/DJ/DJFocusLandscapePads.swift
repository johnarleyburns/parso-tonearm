import SwiftUI
import TonearmCore

struct DJFocusLandscapePads: View {
    @ObservedObject var model: DJPerformanceModel
    let deckID: DJDeckID

    var body: some View {
        let deck = model.deck(deckID)
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
            ForEach(1...4, id: \.self) { number in
                Button(deck.hotCues[number] == nil ? "\(number)" : "Cue \(number)") {
                    model.activateCue(number, deck: deckID)
                }
                .frame(minHeight: 40)
                .background(deck.hotCues[number] == nil ? Color.white.opacity(0.06) : deck.accent,
                            in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(deck.hotCues[number] == nil ? Palette.ink2 : Palette.bg)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("dj.focus.landscape.pads.\(deckID.rawValue.lowercased())")
    }
}
