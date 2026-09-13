import SwiftUI
import TonearmCore

/// A row in `SourceDetailView`'s remote browser — split out of
/// `SourceDetailView.swift`. Constructed from `SourceDetailView.swift`'s
/// `remoteBrowser` (a different file), so widened from `private` to
/// `internal`.
struct RemoteNodeRow: View {
    var icon: String
    var title: String
    var subtitle: String?
    var artwork: RemoteArtwork?

    var body: some View {
        HStack(spacing: 12) {
            if let artwork {
                RemoteArtworkImageView(artwork: artwork, seed: title, cornerRadius: 9)
                    .frame(width: 36, height: 36)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.brass)
                    .frame(width: 36, height: 36)
                    .glassSurface(cornerRadius: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(Palette.ink3).lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}
