import SwiftUI
import TonearmCore

struct CacheGlyph: View {
    let state: CacheGlyphState

    var body: some View {
        Group {
            switch state {
            case .none:
                Circle()
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 1.5)
                    .frame(width: 9, height: 9)
            case .filling(let progress):
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.15))
                    Circle()
                        .trim(from: 0, to: max(0.02, min(1, progress)))
                        .fill(Palette.brass)
                    Circle()
                        .fill(Color(hex: 0x191410))
                        .padding(3.5)
                }
                .frame(width: 16, height: 16)
                .rotationEffect(.degrees(-90))
            case .cached:
                Circle()
                    .fill(Palette.brass)
                    .frame(width: 9, height: 9)
                    .shadow(color: Palette.brass.opacity(0.5), radius: 3)
            }
        }
        .accessibilityLabel(Text(state.voiceOver))
    }
}
