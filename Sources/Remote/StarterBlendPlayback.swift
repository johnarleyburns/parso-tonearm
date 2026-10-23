import Foundation

/// What Listen hands to the real player for one starter blend: the resolved rows, the blend's
/// occurrence IDs (same order) and the supplied plan for every adjacent edge.
public struct StarterPlayRequest: Sendable {
    public let blendID: String
    public let pack: StarterBlendPack
    public let occurrenceIDs: [UUID]
    public let rows: [TrackRow]
    /// Release track ids, parallel to `rows`.
    public let trackIDs: [String]
    /// `edgePlans[i]` joins `rows[i]` to `rows[i + 1]`. Consumed by the streaming renderer, never
    /// summarised away: this is what makes every planned edge audible.
    public let edgePlans: [BlendEdgePlan]
    /// False plays the same rows one after another, with no blend and no claim of one.
    public let isBlended: Bool

    public init(blendID: String, pack: StarterBlendPack = StarterBlendCatalog.pack, occurrenceIDs: [UUID],
                rows: [TrackRow], trackIDs: [String], edgePlans: [BlendEdgePlan], isBlended: Bool = true) {
        self.blendID = blendID
        self.pack = pack
        self.occurrenceIDs = occurrenceIDs
        self.rows = rows
        self.trackIDs = trackIDs
        self.edgePlans = edgePlans
        self.isBlended = isBlended
    }
}

/// What the player reports back about a starter blend it was handed.
public enum StarterStreamStatus: Equatable, Sendable {
    /// Opening the release assets / filling the first buffer.
    case buffering(blendID: String)
    /// Streaming with every planned edge executable.
    case blending(blendID: String)
    /// Streaming stopped; the rest plays in order without blends. `retryable` says whether
    /// trying the blend again can help (a transport problem) or not (the asset is gone).
    case sequential(blendID: String, reason: String, retryable: Bool)
    case stopped(blendID: String)

    public var blendID: String {
        switch self {
        case .buffering(let id), .blending(let id), .stopped(let id): return id
        case .sequential(let id, _, _): return id
        }
    }
}

/// Drives the per-card Play of the starter blends. Rows come from the checked-in catalog (release
/// asset URLs), so starting needs no network lookup, model, index or download; the player streams
/// the first assets after ordinary buffering. A failure is scoped to the card that hit it, and a
/// second tap or a recreated view while a start is in flight does not start playback twice.
@MainActor
public final class StarterBlendPlayback: ObservableObject {
    public enum CardState: Equatable, Sendable {
        case idle
        /// Building the request.
        case loading
        /// The player is opening the release assets and filling its first buffer.
        case buffering
        /// Playing with every edge's supplied plan executing.
        case blending
        /// Streaming stopped: the blend plays in order with no transitions. `retryable` says whether
        /// the release assets might become reachable again.
        case unavailable(reason: String, retryable: Bool)
        case failed(String)
    }

    public typealias Start = @MainActor (StarterPlayRequest) -> Void

    @Published public private(set) var states: [String: CardState] = [:]

    private let start: Start
    private var inFlight: Set<String> = []

    public init(start: @escaping Start) { self.start = start }

    public func state(for blend: StarterBlend) -> CardState { states[blend.id] ?? .idle }

    /// The release-backed rows of `blend`, in play order. Display names are the blend's own: the
    /// release carries audio and plans, not tags.
    nonisolated static func rows(for blend: StarterBlend) -> [TrackRow] {
        rows(blendID: blend.id, title: blend.title, trackIDs: blend.trackIDs, pack: blend.pack)
    }

    nonisolated static func rows(blendID: String, title: String, trackIDs: [String], pack: StarterBlendPack) -> [TrackRow] {
        let source = Source(id: nil, kind: .local, iaIdentifier: blendID, originalURL: nil,
                            title: title, addedAt: Date(), lastResolvedAt: nil,
                            followUpdates: false, licenseText: StarterBlendCatalog.attribution,
                            memberCapHit: false)
        return trackIDs.enumerated().compactMap { offset, trackID in
            guard let assetURL = pack.assetURL(trackID: trackID) else { return nil }
            let id = -(Int64(trackID) ?? Int64(offset + 1))
            let track = Track(id: id, albumId: nil, sourceId: 0, title: "\(title) \(offset + 1)",
                              trackNo: offset + 1, discNo: nil, durationSec: nil,
                              codec: "AAC", sampleRate: nil, bitDepthOrBitrate: "128 kbps",
                              sortKey: String(format: "%06d", offset + 1), genre: nil, artistId: nil)
            var asset = Asset(id: nil, trackId: id, kind: .remote, bookmark: nil, relPath: nil,
                              remoteURL: assetURL.absoluteString,
                              altRemoteURL: nil, sizeBytes: nil, unsupportedReason: nil)
            asset.transientRemoteSupportsByteRanges = true
            return TrackRow(track: track, album: nil, source: source, asset: asset, artist: nil)
        }
    }

    /// Starts the blend. Returns when playback was requested.
    public func play(_ blend: StarterBlend) async {
        // A tap while this blend is already starting (or buffering) must not start it twice.
        switch state(for: blend) {
        case .loading, .buffering: return
        default: break
        }
        guard inFlight.insert(blend.id).inserted else { return }
        defer { inFlight.remove(blend.id) }
        states[blend.id] = .loading
        let rows = Self.rows(for: blend)
        let occurrences = blend.document.occurrences.map(\.id)
        guard rows.count == blend.trackIDs.count, occurrences.count == rows.count,
              blend.edgePlans.count == rows.count - 1 else {
            states[blend.id] = .failed("This blend is incomplete.")
            return
        }
        states[blend.id] = .buffering
        start(StarterPlayRequest(blendID: blend.id, pack: blend.pack, occurrenceIDs: occurrences, rows: rows,
                                 trackIDs: blend.trackIDs, edgePlans: blend.edgePlans))
    }

    /// The player's report for a blend it was handed (buffering, blending, or why it fell back).
    public func apply(_ status: StarterStreamStatus) {
        switch status {
        case .buffering(let id): states[id] = .buffering
        case .blending(let id): states[id] = .blending
        case .sequential(let id, let reason, let retryable): states[id] = .unavailable(reason: reason, retryable: retryable)
        case .stopped(let id): if states[id] != nil { states[id] = .idle }
        }
    }
}
