import SwiftUI
import TonearmCore

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

/// The subset of `DiscoveryTrackAnalysis` `ArtworkView`'s fallback gradient
/// actually uses, cached separately from the full record so a thumbnail
/// re-render never re-decodes more than three scalars.
private struct TrackAnalysisSummary: Sendable {
    var bpm: Double?
    var key: String?
    var energy: Double?
}

/// A tiny in-memory cache in front of `discovery_track_analysis`, since
/// `ArtworkView` renders as potentially thousands of list-row thumbnails —
/// each one re-querying SQLite per scroll frame would be wasteful when the
/// same handful of tracks are visible/re-visible repeatedly. Never persisted
/// (in-memory only) and never invalidated explicitly: analysis rows are
/// write-once per track (BoundedIndexWorker commits them once, at indexing
/// time), so a cached value never goes stale during the app's lifetime.
private actor TrackAnalysisSummaryCache {
    static let shared = TrackAnalysisSummaryCache()
    private var cache: [Int64: TrackAnalysisSummary] = [:]

    func summary(forTrackId trackId: Int64) async -> TrackAnalysisSummary? {
        if let cached = cache[trackId] { return cached }
        let analysis: DiscoveryTrackAnalysis? = (try? await LibraryStore.shared.dbQueue.read { db in
            try DiscoveryTrackAnalysis.fetchOne(db, key: trackId)
        }) ?? nil
        guard let analysis else { return nil }
        let summary = TrackAnalysisSummary(bpm: analysis.bpm, key: analysis.key, energy: analysis.energy)
        cache[trackId] = summary
        return summary
    }
}

struct ArtworkView: View {
    var image: PlatformImage?
    var identifier: String?
    var trackRow: TrackRow?
    var seed: String
    var cornerRadius: CGFloat = 12
    var fallbackIcon: String? = nil
    /// When set, fetches a small, persistently-cached thumbnail (in points —
    /// scaled for screen density internally) instead of the full-resolution
    /// cover. Required for any use in a `List`/`ForEach` row that can appear
    /// by the thousands (Library, Playlists) — decoding/holding full-size
    /// covers for every visible row is real, measurable scroll jank; `nil`
    /// (the default) keeps existing larger call sites — Now Playing,
    /// `RecentCard`'s 132pt tiles — on the original full-resolution path.
    var thumbnailMaxDimension: CGFloat? = nil

    @ObservedObject private var invalidation = ArtworkInvalidation.shared
    @State private var fetchedImage: PlatformImage?
    @State private var analysis: TrackAnalysisSummary?
    @State private var keywordImage: PlatformImage?

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(resolvedGradient)
            .overlay {
                if let img = image ?? fetchedImage {
                    Image(platformImage: img)
                        .resizable()
                        .scaledToFill()
                } else if let keywordImage {
                    // "Phase 2" fallback: a bundled CC0/PD photo whose
                    // subject matches a word in the title, duotone-tinted
                    // with this same track's colorIdentity — a strict
                    // upgrade over the flat gradient below it, never a
                    // different palette (real user complaint this answers:
                    // "just blank colored squares everywhere").
                    Image(platformImage: keywordImage)
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
                    // Identifier-based lookups (source/collection tiles) are
                    // never rendered by the thousands in one scrolling list
                    // today — leave on the full-resolution path.
                    fetchedImage = await ArtworkService.shared.artwork(forIdentifier: id)
                } else if let row = trackRow {
                    if let maxDimension = thumbnailMaxDimension {
                        fetchedImage = await ArtworkService.shared.thumbnail(
                            forTrackRow: row, maxDimension: maxDimension)
                    } else {
                        fetchedImage = await ArtworkService.shared.artwork(forTrackRow: row)
                    }
                }
                // Only worth fetching if we might actually need the fallback
                // gradient (real art always wins, see resolvedGradient) —
                // but the fetch above is what tells us that, so always ask;
                // the cache makes a redundant lookup cheap.
                if let trackId = trackRow?.track.id {
                    analysis = await TrackAnalysisSummaryCache.shared.summary(forTrackId: trackId)
                }
                // Only worth matching/tinting if there's no real artwork to
                // show instead (real art always wins, see resolvedGradient).
                if image == nil, fetchedImage == nil,
                   let title = trackRow?.track.title,
                   let keyword = KeywordArtworkLibrary.match(title: title) {
                    let identity = colorIdentity
                    keywordImage = KeywordArtworkLibrary.tintedImage(
                        forKeyword: keyword, dark: PlatformColor(identity.dark), base: PlatformColor(identity.base))
                } else {
                    keywordImage = nil
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

    /// A track with no artwork still has a real identity: this app already
    /// computes and stores BPM, Camelot key, and an energy score (0...10)
    /// for every indexed track (`discovery_track_analysis`) for the
    /// scheduler/DJ workspace's own use, at no extra cost — reusing them here
    /// means two tracks that previously rendered as visually-identical
    /// title-hash blocks (a real user complaint: "just blank colored squares
    /// everywhere") now differ by their actual tempo/energy/key instead of
    /// only by name. Falls back to the plain hash gradient before analysis
    /// has loaded (or if the track isn't indexed yet) — same as the artwork
    /// fetch above, this never blocks first paint.
    private var defaultGradient: LinearGradient {
        let identity = colorIdentity
        return LinearGradient(
            colors: [identity.base, identity.dark],
            startPoint: identity.gradientAngle.0, endPoint: identity.gradientAngle.1)
    }

    /// The two-color identity (+ gradient angle) this track gets when it has
    /// no real artwork — shared by the plain gradient above AND the "Phase
    /// 2" keyword-photo duotone tint (`keywordArtworkImage`) below, so a
    /// track's color is identical either way; the keyword photo is strictly
    /// an enhancement over the flat gradient, never a different palette.
    private var colorIdentity: (base: Color, dark: Color, gradientAngle: (UnitPoint, UnitPoint)) {
        // NOT Swift's `Hasher`: it's seeded randomly per process launch by
        // design (DoS-resistance for Dictionary/Set) — the exact same title
        // string hashes to a DIFFERENT value every time the app relaunches,
        // which would have made a track's color visibly shift between
        // sessions, defeating the entire point of a stable per-track
        // identity. A plain FNV-1a over the UTF-8 bytes (same style already
        // used for `ArtworkService`'s disk-cache filenames) is deterministic
        // across launches, devices, and app versions.
        var hashInput = seed
        // Some callers pass an album-level seed (e.g. `RecentCard` uses
        // `row.album?.title ?? row.track.title`) so a whole album can read
        // as one family of color — but plenty of local files have no album
        // tag at all, or share a generic placeholder one, which collapsed
        // many genuinely different tracks onto the exact same seed and
        // therefore the exact same hue (real report: "my recently added are
        // all a green despite being a wide variety of tracks"). Folding the
        // track id in too guarantees per-track uniqueness regardless of
        // what the caller's seed collides on, while `seed` still pulls
        // same-album tracks toward a related (not identical) hue.
        if let trackId = trackRow?.track.id {
            hashInput += "-\(trackId)"
        }
        let h = Self.stableHash(hashInput)
        var hue = Double(h % 360) / 360.0

        // Camelot key (e.g. "8A", "11B") -> a hue-family offset, so tracks in
        // compatible/adjacent keys land in a visually related palette — a
        // small, genuine bonus for a DJ app, not just decoration. Blended
        // with the identity hue rather than replacing it outright, so two
        // different tracks sharing a key still don't render identically.
        if let key = analysis?.key, let camelotNumber = Int(key.dropLast()), camelotNumber >= 1 {
            let keyHue = Double(camelotNumber - 1) / 12.0
            hue = (hue * 0.4 + keyHue * 0.6).truncatingRemainder(dividingBy: 1.0)
        }
        // Major (B) reads slightly brighter than minor (A) — matches the
        // usual "major = bright, minor = moody" intuition.
        let isMajor = analysis?.key?.hasSuffix("B") ?? false

        // Energy (0...10) -> saturation/brightness: a quiet ambient track
        // reads dark and muted, a high-energy track reads bright and
        // saturated. `nil` (not yet analyzed) uses a neutral midpoint —
        // never a fabricated extreme.
        let energyFraction = min(1, max(0, (analysis?.energy ?? 5) / 10))
        let saturation = 0.35 + energyFraction * 0.35
        let majorBoost = isMajor ? 0.06 : 0.0
        let baseBrightness = 0.28 + energyFraction * 0.30 + majorBoost
        let darkBrightness = 0.09 + energyFraction * 0.11 + majorBoost * 0.5

        let base = Color(hue: hue, saturation: saturation, brightness: baseBrightness)
        let dark = Color(hue: hue, saturation: min(1, saturation + 0.1), brightness: darkBrightness)

        // BPM -> gradient angle: a cheap, deterministic "rhythm" cue (no new
        // shape/pattern rendering, just which corner the gradient runs
        // toward) rather than a color change, so tempo is legible even for
        // someone who can't distinguish the hue/saturation shift at a glance.
        return (base, dark, Self.gradientAngle(forBPM: analysis?.bpm))
    }

    /// FNV-1a over UTF-8 bytes — deterministic across launches/devices,
    /// unlike Swift's `Hasher` (see `defaultGradient`'s doc for why that
    /// matters here specifically).
    private static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return hash
    }

    private static func gradientAngle(forBPM bpm: Double?) -> (UnitPoint, UnitPoint) {
        guard let bpm else { return (.topLeading, .bottomTrailing) }
        switch bpm {
        case ..<90: return (.top, .bottom)
        case 90..<120: return (.topLeading, .bottomTrailing)
        case 120..<150: return (.leading, .trailing)
        default: return (.bottomLeading, .topTrailing)
        }
    }
}
