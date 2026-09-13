import Foundation
import GRDB

// MARK: - Recording journal (§15.5, §37.3; plan 5.11)
//
// Split out of `DJRecords.swift` — standalone record types, no cross-file
// access-level changes needed.

/// The `mix.localState` — the §37.3 journal's honest state machine. `recording`
/// is the in-progress journal row; `complete` is a finished mix; `corrupt` is a
/// journal row whose recording could not be salvaged on reconcile. The schema
/// column is text (matching §15.5 verbatim); this is the typed view.
public enum MixLocalState: String, Codable, Sendable, Equatable, CaseIterable {
    case recording
    case complete
    case corrupt

    public init?(rawValue: String?) {
        guard let rawValue else { return nil }
        self.init(rawValue: rawValue)
    }
}

/// One `mix` row — the §37.3 recording journal AND the finished mix's header
/// (FR-REC-1). The row is written **in-progress** when recording starts
/// (`localState = .recording`); `finalize` promotes it to `.complete` with the
/// real duration/size; `reconcile()` salvages a crash's stale `recording` row
/// to `.complete` (segments joined) or `.corrupt` (nothing recoverable).
public struct DJMix: Codable, Identifiable, FetchableRecord,
                     MutablePersistableRecord, Equatable, Sendable {
    public var id: Int64?
    public var syncID: String
    public var sessionID: Int64?
    public var title: String
    public var notes: String?
    public var durationSec: Double
    public var trackCount: Int
    /// The FR-REC-7 honest format name (`RecordingEncoder.formatName`).
    public var format: String
    public var bitrateKbps: Int?
    public var sizeBytes: Int64?
    public var artworkID: String?
    public var recordedAt: Date
    /// `localOnly|syncToPhone` (§15.5). `localOnly` is the default; sync is M6.
    public var syncPolicy: String
    /// `recording|complete|corrupt` (§15.5, §37.3).
    public var localState: String

    public init(id: Int64? = nil,
                syncID: String,
                sessionID: Int64? = nil,
                title: String,
                notes: String? = nil,
                durationSec: Double,
                trackCount: Int,
                format: String,
                bitrateKbps: Int? = nil,
                sizeBytes: Int64? = nil,
                artworkID: String? = nil,
                recordedAt: Date,
                syncPolicy: String = "localOnly",
                localState: String) {
        self.id = id
        self.syncID = syncID
        self.sessionID = sessionID
        self.title = title
        self.notes = notes
        self.durationSec = durationSec
        self.trackCount = trackCount
        self.format = format
        self.bitrateKbps = bitrateKbps
        self.sizeBytes = sizeBytes
        self.artworkID = artworkID
        self.recordedAt = recordedAt
        self.syncPolicy = syncPolicy
        self.localState = localState
    }

    /// The §37.3 journal state, typed.
    public var state: MixLocalState {
        MixLocalState(rawValue: localState) ?? .corrupt
    }

    public static let databaseTableName = "mix"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// One `mix_asset` row — the recording's local file + CKAsset lifecycle
/// (§15.5, §38.6). `localRelPath` is the final joined M4A relative to
/// `DJDatabase.mixesDirectory` (e.g. `<sessionUUID>/mix.m4a`), recorded at
/// `begin` and confirmed at `finalize`. Sync columns are inert until M6.
public struct DJMixAsset: Codable, FetchableRecord,
                          MutablePersistableRecord, Equatable, Sendable {
    public var mixID: Int64
    public var localRelPath: String
    public var ckRecordName: String?
    public var ckAssetUploaded: Bool
    public var uploadedBytes: Int64
    public var totalBytes: Int64?
    public var lastUploadAt: Date?

    public init(mixID: Int64,
                localRelPath: String,
                ckRecordName: String? = nil,
                ckAssetUploaded: Bool = false,
                uploadedBytes: Int64 = 0,
                totalBytes: Int64? = nil,
                lastUploadAt: Date? = nil) {
        self.mixID = mixID
        self.localRelPath = localRelPath
        self.ckRecordName = ckRecordName
        self.ckAssetUploaded = ckAssetUploaded
        self.uploadedBytes = uploadedBytes
        self.totalBytes = totalBytes
        self.lastUploadAt = lastUploadAt
    }

    public static let databaseTableName = "mix_asset"
}

/// The snapshot `RecordingService` resolves for a timeline track at finalize
/// (§37.4, plan 5.12): the `mix_track_event` title/artist/BPM/key columns are
/// filled from it so the timeline survives track deletion (§15.5).
public struct TrackTimelineSnapshot: Sendable, Equatable {
    public let title: String
    public let artist: String?
    public let bpm: Double?
    public let camelot: String?

    public init(title: String, artist: String?, bpm: Double?, camelot: String?) {
        self.title = title
        self.artist = artist
        self.bpm = bpm
        self.camelot = camelot
    }
}

/// One `mix_track_event` row — the recorded journal of *what happened when*
/// (§37.4, FR-REC-2, dj-regression-suite §7). Written by 5.12's `MixTimeline`;
/// the record ships here so the schema is complete and the regression suite's
/// journal cross-check has a row shape. `title`/`artist` are snapshots so the
/// timeline survives track deletion; `position` is 1..n order.
public struct DJMixTrackEvent: Codable, Identifiable, FetchableRecord,
                               MutablePersistableRecord, Equatable, Sendable {
    public var id: Int64?
    public var mixID: Int64
    public var trackID: Int64?
    public var title: String
    public var artist: String?
    public var deck: String
    public var startOffsetSec: Double
    public var bpmAtPlay: Double?
    public var camelotAtPlay: String?
    public var position: Int

    public init(id: Int64? = nil,
                mixID: Int64,
                trackID: Int64? = nil,
                title: String,
                artist: String? = nil,
                deck: String,
                startOffsetSec: Double,
                bpmAtPlay: Double? = nil,
                camelotAtPlay: String? = nil,
                position: Int) {
        self.id = id
        self.mixID = mixID
        self.trackID = trackID
        self.title = title
        self.artist = artist
        self.deck = deck
        self.startOffsetSec = startOffsetSec
        self.bpmAtPlay = bpmAtPlay
        self.camelotAtPlay = camelotAtPlay
        self.position = position
    }

    public static let databaseTableName = "mix_track_event"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// One `performance_session` row — a DJ set in progress or completed (§15.5).
/// `mix.sessionID` is nullable; the session row is created when the milestone's
/// set-level surface lands (M6), not by the per-mix journal.
public struct DJPerformanceSession: Codable, Identifiable, FetchableRecord,
                                    MutablePersistableRecord, Equatable, Sendable {
    public var id: Int64?
    public var syncID: String
    public var startedAt: Date
    public var endedAt: Date?
    public var deckAStartTrackID: Int64?
    public var deckBStartTrackID: Int64?

    public init(id: Int64? = nil,
                syncID: String,
                startedAt: Date,
                endedAt: Date? = nil,
                deckAStartTrackID: Int64? = nil,
                deckBStartTrackID: Int64? = nil) {
        self.id = id
        self.syncID = syncID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.deckAStartTrackID = deckAStartTrackID
        self.deckBStartTrackID = deckBStartTrackID
    }

    public static let databaseTableName = "performance_session"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
