import SwiftUI

struct ArtworkView: View {
    var image: UIImage?
    var identifier: String?
    var trackRow: TrackRow?
    var seed: String
    var cornerRadius: CGFloat = 12

    @State private var fetchedImage: UIImage?

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(resolvedGradient)
            .overlay {
                if let img = image ?? fetchedImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: fetchKey) {
                if let id = identifier, !id.isEmpty {
                    fetchedImage = await ArtworkService.shared.artwork(forIdentifier: id)
                } else if let row = trackRow {
                    fetchedImage = await ArtworkService.shared.artwork(forTrackRow: row)
                }
            }
    }

    private var fetchKey: String {
        if let identifier, !identifier.isEmpty { return "id-\(identifier)" }
        return "track-\(trackRow?.track.id ?? -1)"
    }

    private var resolvedGradient: LinearGradient {
        if let img = image ?? fetchedImage {
            let uiColor = ArtworkService.dominantColor(from: img)
            let color = Color(uiColor)
            return LinearGradient(
                colors: [color.opacity(0.3), color.opacity(0.6)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
        return defaultGradient
    }

    private var defaultGradient: LinearGradient {
        var hasher = Hasher()
        hasher.combine(seed)
        let h = abs(hasher.finalize())
        let hue = Double(h % 360) / 360.0
        let base = Color(hue: hue, saturation: 0.45, brightness: 0.42)
        let dark = Color(hue: hue, saturation: 0.55, brightness: 0.14)
        return LinearGradient(colors: [base, dark], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
