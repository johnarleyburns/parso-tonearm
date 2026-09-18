#if !os(watchOS)
import Foundation
import AVFoundation
import ParsoAudioStreaming
import Combine
import Network

/// The seam a mood-driven queue (docs/plans/mood-based-listening-plan.md
/// §3.6/§5 step 6) uses to reach back into whatever is actually running the
/// query, without `QueueSource` (TonearmCore) depending on
/// `DiscoverySearchViewModel` (TonearmDiscovery) — TonearmDiscovery already
/// depends ON TonearmCore, so the reverse import isn't available; a
/// protocol living here, conformed to from the other side, is the fix.
/// `DiscoverySearchViewModel` conforms to this in `Sources/Discovery/
/// DiscoverySearchViewModel.swift`.
@MainActor
public protocol MoodQuerySource: AnyObject {
    /// Adds a track (or term) as a positive signal to the live query —
    /// "Include in current mood" (§3.6) calls this. Must be the additive
    /// `addMoreLike(_:)` mechanism, never an exclusive-alternate-mode call
    /// like `moreLikeThis(trackID:)` (§3.6's audit note).
    func addPositiveTerm(_ term: String)
    /// Re-runs the current query for queue extension (§3.3/§7) — a fresh
    /// batch of tracks from the SAME mood query, not a generic similarity
    /// fallback.
    func refreshedTracks() async -> [TrackRow]
}

public enum QueueSource {
    case source(Source)
    case playlist(Playlist)
    case library
    case ambient
    /// A queue seeded from the Listen tab's mood entry point (docs/plans/
    /// mood-based-listening-plan.md). Carries a reference back to whatever
    /// is running the query so "Include in current mood" and queue
    /// extension can both reach it from anywhere in the app.
    case mood(any MoodQuerySource)
    case none

    public var label: String {
        switch self {
        case .source(let s): return "From Library: \(s.title)"
        case .playlist(let p): return "From Playlist: \(p.title)"
        case .library: return "From Music"
        case .ambient: return "Ambient"
        case .mood: return "A Mood"
        case .none: return ""
        }
    }
}

extension QueueSource: Equatable {
    public static func == (lhs: QueueSource, rhs: QueueSource) -> Bool {
        switch (lhs, rhs) {
        case (.source(let a), .source(let b)): return a == b
        case (.playlist(let a), .playlist(let b)): return a == b
        case (.library, .library): return true
        case (.ambient, .ambient): return true
        case (.mood(let a), .mood(let b)): return a === b
        case (.none, .none): return true
        default: return false
        }
    }
}

#endif
