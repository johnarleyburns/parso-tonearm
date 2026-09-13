import Foundation

// MARK: - Read models

/// A gig crate as the list surface renders it (§41.17, mockup `ipad/14`): the
/// crate joined with its per-track roll-up — cached / analyzed / stems-ready
/// counts and the on-disk stem bytes the §43.6 budget accounts.
public struct GigCrateRow: Identifiable, Sendable, Equatable {
    public let id: Int64
    public let name: String
    public let playlistTitle: String
    public let trackCount: Int
    public let cachedCount: Int
    public let analyzedCount: Int
    public let stemsReadyCount: Int
    /// The crate's on-disk stem bytes (the SUM of `gig_crate_track.stemsBytes`).
    public let stemsBytes: Int64
    public let storageBudgetBytes: Int64
    public let lastPerformedAt: Date?
    public let createdAt: Date

    public init(id: Int64, name: String, playlistTitle: String,
                trackCount: Int, cachedCount: Int, analyzedCount: Int,
                stemsReadyCount: Int, stemsBytes: Int64,
                storageBudgetBytes: Int64, lastPerformedAt: Date?, createdAt: Date) {
        self.id = id
        self.name = name
        self.playlistTitle = playlistTitle
        self.trackCount = trackCount
        self.cachedCount = cachedCount
        self.analyzedCount = analyzedCount
        self.stemsReadyCount = stemsReadyCount
        self.stemsBytes = stemsBytes
        self.storageBudgetBytes = storageBudgetBytes
        self.lastPerformedAt = lastPerformedAt
        self.createdAt = createdAt
    }

    /// FR-PLIST-9 readiness: every track's audio is local. Empty crates are
    /// never "ready" (there is nothing to perform).
    public var isReady: Bool { trackCount > 0 && cachedCount == trackCount }

    /// The stems-separated fraction for the header progress bar.
    public var stemsFraction: Double {
        guard trackCount > 0 else { return 0 }
        return Double(stemsReadyCount) / Double(trackCount)
    }
}

/// One track row of a gig crate (§41.17): the `gig_crate_track` row joined with
/// the track's display metadata and analysis state, so the surface never needs
/// an N+1 object graph. `audioCached` is the FR-LIB-8 flag; a track that is not
/// cached is honestly deck-disabled, never presented as ready.
public struct GigCrateTrackRow: Identifiable, Sendable, Equatable {
    public var id: Int64 { trackID }
    public let position: Int
    public let trackID: Int64
    public let title: String
    public let artistNames: String
    public let durationSec: Double?
    public let bpm: Double?
    public let camelot: String?
    /// FR-LIB-8: audio fully local and reachable.
    public let audioCached: Bool
    /// `pending|running|ready|failed|evicted`.
    public let stemsState: String
    public let stemsBytes: Int64
    /// `pending|analyzed|failed` — the stage-1 readout.
    public let analysisState: String

    public init(position: Int, trackID: Int64, title: String, artistNames: String,
                durationSec: Double?, bpm: Double?, camelot: String?,
                audioCached: Bool, stemsState: String, stemsBytes: Int64,
                analysisState: String) {
        self.position = position
        self.trackID = trackID
        self.title = title
        self.artistNames = artistNames
        self.durationSec = durationSec
        self.bpm = bpm
        self.camelot = camelot
        self.audioCached = audioCached
        self.stemsState = stemsState
        self.stemsBytes = stemsBytes
        self.analysisState = analysisState
    }

    /// The crate's derived stem state enum, for switch-friendly UI.
    public var stems: GigCrateStemsState {
        GigCrateStemsState(rawValue: stemsState) ?? .pending
    }
}

/// The full read model for one crate (§41.17): the crate row + its ordered
/// track rows + the per-crate roll-up the four header cards render.
public struct GigCrateDetail: Identifiable, Sendable, Equatable {
    public var id: Int64 { crate.id ?? 0 }
    public let crate: GigCrate
    public let playlistTitle: String
    public let tracks: [GigCrateTrackRow]

    public init(crate: GigCrate, playlistTitle: String, tracks: [GigCrateTrackRow]) {
        self.crate = crate
        self.playlistTitle = playlistTitle
        self.tracks = tracks
    }

    public var trackCount: Int { tracks.count }
    public var cachedCount: Int { tracks.lazy.filter(\.audioCached).count }
    public var analyzedCount: Int {
        tracks.lazy.filter { $0.analysisState == "analyzed" }.count
    }
    public var stemsReadyCount: Int {
        tracks.lazy.filter { $0.stems == .ready }.count
    }
    /// The stems-separated fraction for the header progress bar.
    public var stemsFraction: Double {
        guard trackCount > 0 else { return 0 }
        return Double(stemsReadyCount) / Double(trackCount)
    }
    /// The crate's on-disk stem bytes (the §43.6 account).
    public var stemsBytes: Int64 { tracks.reduce(0) { $0 + $1.stemsBytes } }
    /// The projected stem bytes this crate will consume once every pending
    /// track is separated — the "Storage for this crate" card (§43.6's
    /// ~13 MB/track figure).
    public var projectedStemBytes: Int64 {
        stemsBytes + Int64(tracks.lazy.filter { $0.stems != .ready }.count)
            * StorageBudgetService.estimatedStemsBytesPerTrack
    }
}
