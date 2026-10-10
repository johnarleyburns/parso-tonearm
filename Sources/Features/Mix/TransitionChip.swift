import SwiftUI
import TonearmCore

struct TransitionChip: View {
    @EnvironmentObject private var player: AudioPlayer
    let planned: TransitionPlan?
    let onUsePlainFade: (() -> Void)?
    let onPrepareNow: (() -> Void)?
    let onAudition: (() -> Void)?
    let preparationState: GridPrepState?
    @State private var showWhy = false

    init(plan: TransitionPlan? = nil, onUsePlainFade: (() -> Void)? = nil,
         onPrepareNow: (() -> Void)? = nil, onAudition: (() -> Void)? = nil,
         preparationState: GridPrepState? = nil) {
        self.planned = plan
        self.onUsePlainFade = onUsePlainFade
        self.onPrepareNow = onPrepareNow
        self.onAudition = onAudition
        self.preparationState = preparationState
    }

    var body: some View {
        if let plan = planned ?? player.transitionPlan {
            Button { showWhy = true } label: {
                Label("\(plan.displayName) · \(preparationState?.shortLabel ?? "Why?")",
                      systemImage: "waveform.path")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Palette.accent.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityValue("Confidence \(Int(plan.confidence * 100)) percent")
            .sheet(isPresented: $showWhy) {
                NavigationStack {
                    WhyThisTransitionView(plan: plan,
                                         onAudition: onAudition,
                                         onUsePlainFade: onUsePlainFade,
                                         onPrepareNow: onPrepareNow,
                                         preparationState: preparationState)
                }
            }
        }
    }
}

private extension TransitionPlan {
    var displayName: String {
        switch style {
        case .gapless: String(localized: "Gapless continuation")
        case .beatmatchedBlend: String(localized: "Beat-matched blend")
        case .phraseFade: String(localized: "Phrase-aware fade")
        case .plainCrossfade: String(localized: "Plain crossfade")
        }
    }
}
