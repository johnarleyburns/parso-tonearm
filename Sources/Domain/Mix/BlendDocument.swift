import Foundation

/// Durable, minimal description of a repeatable blend: ordered track
/// occurrences plus the requested transition intent for each edge. It holds
/// only stable source identities — never decoded audio, security-scoped
/// bookmarks or expiring stream URLs — so every source is re-resolved when the
/// blend is replayed.
public struct BlendDocument: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchemaVersion = 1

    public enum Origin: String, Codable, Sendable, Equatable {
        case starter, manualQueue, blendLab
    }

    public enum SaveState: String, Codable, Sendable, Equatable {
        case saved
    }

    /// Canonical, restart-safe identity of a track. `syncID` is the stable
    /// library identity; `identityKeys` are `TrackIdentityKey.cloudValue`s
    /// used when the syncID no longer matches. Title/artist are display hints
    /// only, so an unavailable occurrence can still be named honestly.
    public struct SourceIdentity: Codable, Sendable, Equatable, Hashable {
        public var syncID: String?
        public var identityKeys: [String]
        public var title: String
        public var artist: String?
        public var isRemote: Bool

        public init(syncID: String?, identityKeys: [String] = [], title: String,
                    artist: String? = nil, isRemote: Bool = false) {
            self.syncID = syncID; self.identityKeys = identityKeys
            self.title = title; self.artist = artist; self.isRemote = isRemote
        }
    }

    public struct Occurrence: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var source: SourceIdentity
        public init(id: UUID = UUID(), source: SourceIdentity) {
            self.id = id; self.source = source
        }
    }

    /// The transition the listener asked for between two adjacent occurrences.
    /// Identified by its own UUID so A→A repeats keep distinct edges.
    public struct Edge: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var fromOccurrenceID: UUID
        public var toOccurrenceID: UUID
        /// `TransitionStyle.rawValue`; nil means "automatic / not specified".
        public var requestedStyle: String?
        /// The concrete, immutable plan this edge executes (Starter Blends), persisted with the
        /// blend so a replay plays exactly what was saved. Nil for edges planned at play time.
        public var plan: BlendEdgePlan?
        public init(id: UUID = UUID(), fromOccurrenceID: UUID, toOccurrenceID: UUID,
                    requestedStyle: String? = nil, plan: BlendEdgePlan? = nil) {
            self.id = id; self.fromOccurrenceID = fromOccurrenceID
            self.toOccurrenceID = toOccurrenceID; self.requestedStyle = requestedStyle
            self.plan = plan
        }
    }

    public var schemaVersion: Int
    public var id: UUID
    public var title: String
    /// Reference (e.g. a track syncID) used to draw artwork; never image bytes.
    public var artworkReference: String?
    public var origin: Origin
    public var createdAt: Date
    public var updatedAt: Date
    public var lastPlayedAt: Date?
    public var saveState: SaveState
    /// Bumps on every edit so a stale writer cannot overwrite a newer document.
    public var generation: Int
    public var occurrences: [Occurrence]
    public var edges: [Edge]
    /// The immutable release this blend's audio and edge plans belong to (Starter Blends).
    public var pack: StarterBlendPack?

    public init(id: UUID = UUID(), title: String, artworkReference: String? = nil,
                origin: Origin, now: Date = Date(), occurrences: [Occurrence],
                requestedStyles: [String?] = []) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id; self.title = title; self.artworkReference = artworkReference
        self.origin = origin; self.createdAt = now; self.updatedAt = now
        self.lastPlayedAt = nil; self.saveState = .saved; self.generation = 1
        self.occurrences = occurrences
        self.edges = Self.makeEdges(occurrences, styles: requestedStyles, reusing: [])
    }

    static func makeEdges(_ occurrences: [Occurrence], styles: [String?], reusing old: [Edge]) -> [Edge] {
        guard occurrences.count > 1 else { return [] }
        return (0..<(occurrences.count - 1)).map { i in
            let from = occurrences[i].id, to = occurrences[i + 1].id
            if let kept = old.first(where: { $0.fromOccurrenceID == from && $0.toOccurrenceID == to }) {
                return kept
            }
            return Edge(fromOccurrenceID: from, toOccurrenceID: to,
                        requestedStyle: i < styles.count ? styles[i] : nil)
        }
    }

    /// Returns an edited copy with a new generation. Existing occurrence and
    /// edge IDs are preserved wherever the adjacency survives, so editing one
    /// duplicate appearance never touches another.
    public func replacingOccurrences(_ new: [Occurrence], now: Date = Date()) -> BlendDocument {
        var copy = self
        copy.occurrences = new
        copy.edges = Self.makeEdges(new, styles: [], reusing: edges)
        copy.generation += 1
        copy.updatedAt = now
        return copy
    }

    public func markingPlayed(at date: Date) -> BlendDocument {
        var copy = self
        copy.lastPlayedAt = date
        return copy
    }

    /// Intent as shown in Blend Detail, e.g. "Smart blend" when unspecified.
    public func requestedIntent(afterOccurrence id: UUID) -> String? {
        edges.first { $0.fromOccurrenceID == id }?.requestedStyle
    }
}
