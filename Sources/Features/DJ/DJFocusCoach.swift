import SwiftUI
import TonearmCore

struct DJCoachCard: View {
    @ObservedObject var model: DJPerformanceModel
    @AppStorage("dj.dismissedCoach") private var dismissed = ""

    var body: some View {
        if let tip {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lightbulb.fill").foregroundStyle(Palette.brass)
                Text(tip.text).font(.caption)
                Spacer()
                Button("Got it") { dismissed = tip.id }
                    .font(.caption.weight(.semibold))
            }
            .padding(12)
            .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
            .accessibilityIdentifier("dj.focus.coach")
        }
    }

    private var tip: DJCoachTip? {
        let snapshot = DJCoachSnapshot(
            loadedA: model.deckA.row != nil,
            playingA: model.deckA.isPlaying,
            loadedB: model.deckB.row != nil,
            playingB: model.deckB.isPlaying,
            syncedB: model.deckB.syncEnabled,
            crossfader: model.crossfader,
            keysCompatible: keyCompatibility,
            dismissedTipID: dismissed.isEmpty ? nil : dismissed
        )
        return DJCoachPolicy.tip(for: snapshot)
    }

    private var keyCompatibility: Bool? {
        guard let a = model.deckA.key, let b = model.deckB.key else { return nil }
        return a == b
    }
}
