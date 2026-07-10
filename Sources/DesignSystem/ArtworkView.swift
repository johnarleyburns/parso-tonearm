import SwiftUI

/// Global signal that lets any `ArtworkView` re-resolve its artwork after a
/// track's art changes (e.g. the user attaches custom artwork), without each
/// view needing to observe `AppState`.
@MainActor
final class ArtworkInvalidation: ObservableObject {
    static let shared = ArtworkInvalidation()
    @Published private(set) var version = 0
    private init() {}
    func invalidate() { version += 1 }
}

struct ArtworkView: View {
    var image: UIImage?
    var identifier: String?
    var trackRow: TrackRow?
    var seed: String
    var cornerRadius: CGFloat = 12
    var fallbackIcon: String? = nil

    @ObservedObject private var invalidation = ArtworkInvalidation.shared
    @State private var fetchedImage: UIImage?

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(resolvedGradient)
            .overlay {
                if let img = image ?? fetchedImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else if let icon = fallbackIcon {
                    GeometryReader { geo in
                        Image(systemName: icon)
                            .font(.system(size: min(geo.size.width, geo.size.height) * 0.36,
                                          weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
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
        let base: String
        if let identifier, !identifier.isEmpty { base = "id-\(identifier)" }
        else { base = "track-\(trackRow?.track.id ?? -1)" }
        return "\(base)-v\(invalidation.version)"
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
