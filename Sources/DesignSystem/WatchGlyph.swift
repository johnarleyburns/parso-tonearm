import SwiftUI
import TonearmCore

struct WatchGlyphView: View {
    let state: WatchGlyphState

    var body: some View {
        Group {
            switch state {
            case .notOnWatch:
                Image(systemName: "applewatch")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)

            case .transferring(let progress):
                ZStack {
                    Image(systemName: "applewatch")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkTertiary)
                    if let progress = progress, progress > 0 {
                        Circle()
                            .trim(from: 0, to: max(0.02, min(1, progress)))
                            .stroke(Palette.accent, lineWidth: 1.5)
                            .frame(width: 17, height: 17)
                            .rotationEffect(.degrees(-90))
                    } else {
                        ProgressView()
                            .scaleEffect(0.45)
                    }
                }
                .frame(width: 17, height: 17)

            case .onWatch:
                Image(systemName: "applewatch")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.accent)

            case .failed:
                Image(systemName: "applewatch")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.danger)
            }
        }
        .frame(width: 17)
        .accessibilityLabel(Text(voiceOver))
    }

    private var voiceOver: String {
        switch state {
        case .notOnWatch: return String(localized: "Not on Apple Watch")
        case .transferring(let progress):
            if let p = progress {
                return String(localized: "Transferring to Apple Watch, \(Int(p * 100))%")
            }
            return String(localized: "Transferring to Apple Watch")
        case .onWatch: return String(localized: "On Apple Watch")
        case .failed: return String(localized: "Transfer to Apple Watch failed")
        }
    }
}
