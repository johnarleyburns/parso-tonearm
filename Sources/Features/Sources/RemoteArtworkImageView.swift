import SwiftUI
#if !os(macOS)
import UIKit
#endif
import TonearmCore

/// Remote artwork loading + cache for `SourceDetailView`/`RemoteNodeRow` —
/// split out of `SourceDetailView.swift`. Constructed from
/// `SourceDetailView.swift`'s `hero` and `RemoteNodeRow.swift`'s `body` (both
/// different files), so widened from `private` to `internal`.
struct RemoteArtworkImageView: View {
    let artwork: RemoteArtwork
    let seed: String
    let cornerRadius: CGFloat

    @State private var image: PlatformImage?

    var body: some View {
        ArtworkView(image: image, seed: seed, cornerRadius: cornerRadius)
            .task(id: artwork.id ?? artwork.url?.absoluteString ?? seed) {
                image = await RemoteArtworkCache.shared.load(artwork)
            }
    }
}

actor RemoteArtworkCache {
    static let shared = RemoteArtworkCache()

    private var cache: [String: PlatformImage] = [:]
    private var tasks: [String: Task<PlatformImage?, Never>] = [:]

    func load(_ artwork: RemoteArtwork) async -> PlatformImage? {
        let cacheKey = artwork.id ?? artwork.url?.absoluteString ?? ""
        if let img = cache[cacheKey] { return img }
        return await performFetch(artwork)
    }

    private func performFetch(_ artwork: RemoteArtwork) async -> PlatformImage? {
        let cacheKey = artwork.id ?? artwork.url?.absoluteString ?? UUID().uuidString
        if let existing = tasks[cacheKey] { return await existing.value }

        let task = Task<PlatformImage?, Never> {
            guard let url = artwork.url else { return nil }
            var request = URLRequest(url: url)
            for (key, value) in artwork.headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let img = PlatformImage(data: data) else { return nil }
            return img
        }
        tasks[cacheKey] = task
        let result = await task.value
        if let img = result {
            cache[cacheKey] = img
        }
        tasks[cacheKey] = nil
        return result
    }
}
