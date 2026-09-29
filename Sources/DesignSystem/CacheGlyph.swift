import SwiftUI
import TonearmCore

struct CacheGlyph: View {
    let state: CacheGlyphState

    var body: some View {
        Group {
            switch state {
            case .none:
                Circle()
                    .strokeBorder(Palette.ink.opacity(0.22), lineWidth: 1.5)
                    .frame(width: 9, height: 9)
            case .filling(let progress):
                ZStack {
                    Circle()
                        .fill(Palette.ink.opacity(0.15))
                    Circle()
                        .trim(from: 0, to: max(0.02, min(1, progress)))
                        .fill(Palette.accent)
                    Circle()
                        .fill(Palette.surfaceRaised)
                        .padding(3.5)
                }
                .frame(width: 16, height: 16)
                .rotationEffect(.degrees(-90))
            case .cached:
                Circle()
                    .fill(Palette.accent)
                    .frame(width: 9, height: 9)
                    .shadow(color: Palette.accent.opacity(0.5), radius: 3)
            }
        }
        .accessibilityLabel(Text(state.voiceOver))
    }
}
