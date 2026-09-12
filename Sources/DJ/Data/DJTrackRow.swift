import Foundation
import GRDB

/// Flat listing row for the DJ-side library/search/playlist screens (§18.2).
///
/// This used to be filled by a DJ-local `DJTrackRepository` querying this
/// database's own (now-deleted) `track`/`album`/`track_artist` catalog
/// tables. C02 retired that duplicate catalog — `LibraryModel`,
/// `AutoPlaylistModel`, and the vibe-search stack now build `DJTrackRow`
/// values directly from core `LibraryStore`/`TrackRow` reads (see
/// `LibraryModel.refresh()`, `AutoPlaylistModel.rows(from:)`), so `id` here
/// is always a **core** `LibraryStore` track id. `DJTrackRow` itself stays —
/// it is just a display DTO, not catalog storage — because the DJ features'
/// views (`LibraryView`, playlist/vibe-search rows) are still built against
/// its shape.
public struct DJTrackRow: Codable, FetchableRecord, Identifiable, Equatable, Sendable {
    public var id: Int64
    public var title: String
    public var artistNames: String
    public var albumTitle: String?
    public var durationSec: Double?
    public var bpm: Double?
    public var camelot: String?
    public var energy: Double?
    public var analysisState: String
    public var stemState: String

    public init(id: Int64,
                title: String,
                artistNames: String,
                albumTitle: String? = nil,
                durationSec: Double? = nil,
                bpm: Double? = nil,
                camelot: String? = nil,
                energy: Double? = nil,
                analysisState: String = "pending",
                stemState: String = "none") {
        self.id = id
        self.title = title
        self.artistNames = artistNames
        self.albumTitle = albumTitle
        self.durationSec = durationSec
        self.bpm = bpm
        self.camelot = camelot
        self.energy = energy
        self.analysisState = analysisState
        self.stemState = stemState
    }
}
