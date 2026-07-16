import Foundation

/// The cache-fill state the player publishes; the `CacheGlyph` view (app target)
/// renders it. Lives in Core because `AudioPlayer` / `CacheStore` drive it.
public enum CacheGlyphState: Equatable {
    case none
    case filling(Double)
    case cached

    public var voiceOver: String {
        switch self {
        case .none: return "not cached"
        case .filling(let p): return "caching, \(Int((p * 100).rounded())) percent"
        case .cached: return "cached"
        }
    }
}
