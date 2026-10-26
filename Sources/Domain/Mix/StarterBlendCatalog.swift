import Foundation

/// The built-in, deterministic set of curated Jamendo-backed starter blends
/// Listen shows before any model download, indexing, sign-in or library scan.
/// Metadata only: ordered track identities, the pinned release pack they are
/// served from and the precomputed edge plan for every adjacent pair. No audio
/// bytes or user data; audio streams from the immutable GitHub Release.
public struct StarterBlend: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    /// Short mood/tempo line shown on the card.
    public let summary: String
    /// SF Symbol and hue (0…1) drawn when no artwork is available.
    public let artworkSymbol: String
    public let artworkHue: Double
    /// Catalog track ids, in play order.
    public let trackIDs: [String]
    /// The immutable release these tracks stream from.
    public let pack: StarterBlendPack
    /// The supplied plan for every adjacent pair, in play order (`trackIDs.count - 1` entries).
    public let edgePlans: [BlendEdgePlan]

    /// The card's second line (presentation only; never used to admit a candidate).
    public var subtitle: String { summary }

    /// Stable, restart-safe document for this blend. Blend and occurrence UUIDs
    /// are derived from the catalog position so they never change between
    /// launches or devices.
    public var document: BlendDocument {
        StarterBlendCatalog.document(for: self)
    }
}

public enum StarterBlendCatalog {
    public static let pack = StarterBlendPack.v1
    /// The 36 mirrored Starter Pack track IDs (the only IDs with a Release asset).
    public static var starterTrackIDs: Set<String> { Set(blends.flatMap(\.trackIDs)) }
    public static let creditsURL = URL(string: "https://www.jamendo.com/about")!
    public static let attribution = "Music originally from Jamendo, released as CC0 for the Starter Blends."

    private static let epoch = Date(timeIntervalSince1970: 1_767_225_600)

    public static let blends: [StarterBlend] = [
        make(0, "starter.morning-light", "Morning Light", "Gentle and bright, slow to mid tempo",
             "sunrise.fill", 0.10, ["337997", "1424003", "337069", "1180864", "642026", "1077690"]),
        make(1, "starter.deep-focus", "Deep Focus", "Calm, steady and unobtrusive, slow tempo",
             "brain.head.profile", 0.58, ["455018", "117009", "971563", "1097061", "26403", "1100130"]),
        make(2, "starter.night-drive", "Night Drive", "Moody electronic pulse, mid tempo",
             "car.fill", 0.72, ["1163782", "1828808", "1121468", "1739551", "1493402", "1560522"]),
        make(3, "starter.acoustic-evening", "Acoustic Evening", "Warm guitars and voices, relaxed tempo",
             "guitars.fill", 0.07, ["1229422", "398193", "1418240", "1308980", "1849464", "1212932"]),
        make(4, "starter.upbeat-energy", "Upbeat Energy", "Driving and positive, fast tempo",
             "bolt.fill", 0.95, ["2053669", "2228244", "1901830", "2126638", "2133921", "1977152"]),
        make(5, "starter.rainy-day", "Rainy Day", "Soft piano and ambient textures, very slow",
             "cloud.rain.fill", 0.55, ["1891078", "1891935", "1974389", "2220789", "2169489", "1960412"])
    ]

    public static func blend(id: String) -> StarterBlend? { blends.first { $0.id == id } }

    private static func make(_ index: Int, _ id: String, _ title: String, _ summary: String,
                             _ symbol: String, _ hue: Double, _ tracks: [String]) -> StarterBlend {
        StarterBlend(id: id, title: title, summary: summary, artworkSymbol: symbol, artworkHue: hue,
                     trackIDs: tracks, pack: pack,
                     edgePlans: StarterBlendRuntimeData.edges.filter { $0.blendID == id }.sorted { $0.edge < $1.edge })
    }

    /// The `BlendDocument` for a starter blend (origin `.starter`).
    static func document(for blend: StarterBlend) -> BlendDocument {
        let index = blends.firstIndex { $0.id == blend.id } ?? 0
        let occurrences = blend.trackIDs.enumerated().map { offset, trackID in
            BlendDocument.Occurrence(
                id: stableUUID(blend: index, slot: offset + 1),
                source: .init(syncID: "\(blend.pack.releaseTag):\(trackID)", title: "Starter track \(trackID)",
                              isRemote: true))
        }
        var document = BlendDocument(id: stableUUID(blend: index, slot: 0), title: blend.title,
                             artworkReference: nil, origin: .starter, now: epoch,
                             occurrences: occurrences,
                             requestedStyles: blend.edgePlans.map { $0.style.rawValue })
        document.pack = blend.pack
        for edge in document.edges.indices {
            document.edges[edge].id = stableUUID(blend: index, slot: 0x1000 + edge)
            if edge < blend.edgePlans.count { document.edges[edge].plan = blend.edgePlans[edge] }
        }
        return document
    }

    private static func stableUUID(blend: Int, slot: Int) -> UUID {
        UUID(uuidString: String(format: "5EED0000-%04X-4000-8000-%012X", blend, slot))!
    }
}

extension StarterBlendCatalog {
    /// Saved blends followed by the built-in Starter Blends the user has not saved a copy of.
    public static func mergingStarterBlends(into saved: [BlendDocument]) -> [BlendDocument] {
        let savedIDs = Set(saved.map(\.id))
        return saved + blends.map(\.document).filter { !savedIDs.contains($0.id) }
    }

    /// True for a catalog Starter Blend, which is always listed and so cannot be removed.
    public static func isBuiltIn(_ document: BlendDocument) -> Bool {
        document.origin == .starter && blends.contains { $0.document.id == document.id }
    }
}
