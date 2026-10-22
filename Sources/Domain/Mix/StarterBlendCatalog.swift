import Foundation

/// The built-in, deterministic set of curated Jamendo-backed starter blends
/// Listen shows before any model download, indexing, sign-in or library scan.
/// Metadata only: ordered Jamendo track identities and the conservative
/// transition intent requested between them. No audio bytes, URLs or user data;
/// every track is resolved through the Jamendo catalogue at play time.
public struct StarterBlend: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    /// Short mood/tempo line shown on the card.
    public let summary: String
    /// SF Symbol and hue (0…1) drawn when no artwork is available.
    public let artworkSymbol: String
    public let artworkHue: Double
    /// Jamendo track ids, in play order.
    public let jamendoTrackIDs: [String]
    /// `TransitionStyle.rawValue` requested between every adjacent pair.
    public let requestedStyle: String

    /// Stable, restart-safe document for this blend. Blend and occurrence UUIDs
    /// are derived from the catalog position so they never change between
    /// launches or devices.
    public var document: BlendDocument {
        StarterBlendCatalog.document(for: self)
    }
}

public enum StarterBlendCatalog {
    public static let creditsURL = URL(string: "https://www.jamendo.com/about")!
    public static let attribution = "Music from Jamendo, licensed by each artist under Creative Commons."

    private static let epoch = Date(timeIntervalSince1970: 1_767_225_600)

    public static let blends: [StarterBlend] = [
        make(0, "starter.morning-light", "Morning Light", "Singer-Songwriter · Gentle and bright, slow to mid tempo",
             "sunrise.fill", 0.10, ["337997", "1424003", "337069", "1180864", "642026", "1077690"]),
        make(1, "starter.deep-focus", "Deep Focus", "Ambient · Calm, steady and unobtrusive, slow tempo",
             "brain.head.profile", 0.58, ["455018", "117009", "971563", "1097061", "26403", "1100130"]),
        make(2, "starter.night-drive", "Night Drive", "Synthwave · Moody electronic pulse, mid tempo",
             "car.fill", 0.72, ["1163782", "1828808", "1121468", "1739551", "1493402", "1560522"]),
        make(3, "starter.acoustic-evening", "Acoustic Evening", "Singer-Songwriter · Warm guitars and voices, relaxed tempo",
             "guitars.fill", 0.07, ["1229422", "398193", "1418240", "1308980", "1849464", "1212932"]),
        make(4, "starter.upbeat-energy", "Upbeat Energy", "Dance Pop · Driving and positive, fast tempo",
             "bolt.fill", 0.95, ["2053669", "2228244", "1901830", "2126638", "2133921", "1977152"]),
        make(5, "starter.rainy-day", "Rainy Day", "Contemporary Piano · Soft piano and ambient textures, very slow",
             "cloud.rain.fill", 0.55, ["1891078", "1891935", "1974389", "2220789", "2169489", "1960412"])
    ]

    public static func blend(id: String) -> StarterBlend? { blends.first { $0.id == id } }

    private static func make(_ index: Int, _ id: String, _ title: String, _ summary: String,
                             _ symbol: String, _ hue: Double, _ tracks: [String]) -> StarterBlend {
        StarterBlend(id: id, title: title, summary: summary, artworkSymbol: symbol, artworkHue: hue,
                     jamendoTrackIDs: tracks, requestedStyle: TransitionStyle.plainCrossfade.rawValue)
    }

    /// The `BlendDocument` for a starter blend (origin `.starter`).
    static func document(for blend: StarterBlend) -> BlendDocument {
        let index = blends.firstIndex { $0.id == blend.id } ?? 0
        let occurrences = blend.jamendoTrackIDs.enumerated().map { offset, trackID in
            BlendDocument.Occurrence(
                id: stableUUID(blend: index, slot: offset + 1),
                source: .init(syncID: "jamendo:\(trackID)", title: "Jamendo track \(trackID)",
                              isRemote: true))
        }
        var document = BlendDocument(id: stableUUID(blend: index, slot: 0), title: blend.title,
                             artworkReference: nil, origin: .starter, now: epoch,
                             occurrences: occurrences,
                             requestedStyles: Array(repeating: blend.requestedStyle,
                                                    count: max(0, occurrences.count - 1)))
        for edge in document.edges.indices {
            document.edges[edge].id = stableUUID(blend: index, slot: 0x1000 + edge)
        }
        return document
    }

    private static func stableUUID(blend: Int, slot: Int) -> UUID {
        UUID(uuidString: String(format: "5EED0000-%04X-4000-8000-%012X", blend, slot))!
    }
}
