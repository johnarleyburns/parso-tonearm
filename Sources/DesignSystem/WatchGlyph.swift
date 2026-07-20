import SwiftUI
import TonearmCore

struct WatchGlyphView: View {
    let state: WatchGlyphState

    var body: some View {
        Group {
            switch state {
            case .notOnWatch:
                Image(systemName: "applewatch")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink3)

            case .transferring(let progress):
                ZStack {
                    Image(systemName: "applewatch")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink3)
                    if let progress = progress, progress > 0 {
                        Circle()
                            .trim(from: 0, to: max(0.02, min(1, progress)))
                            .stroke(Palette.brass, lineWidth: 1.5)
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
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.brass)

            case .failed:
                Image(systemName: "applewatch")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.danger)
            }
        }
        .frame(width: 17)
        .accessibilityLabel(Text(voiceOver))
    }

    private var voiceOver: String {
        switch state {
        case .notOnWatch: return "Not on Apple Watch"
        case .transferring(let progress):
            if let p = progress {
                return "Transferring to Apple Watch, \(Int(p * 100))%"
            }
            return "Transferring to Apple Watch"
        case .onWatch: return "On Apple Watch"
        case .failed: return "Transfer to Apple Watch failed"
        }
    }
}
