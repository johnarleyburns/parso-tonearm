import Foundation
import CloudKit

/// Pure, testable mappers between GRDB rows and `CKRecord`s. Kept free of any
/// networking so `RecordMappingTests` can round-trip every type without a live
/// CloudKit connection (repo convention: DB/mapping/merge logic stays pure).
///
/// Record names are the row's `syncID` (a UUID string, schema `v7`); parent
/// references are carried as the parent's `syncID` so identity survives across
/// devices where local `Int64` PKs differ.
public enum RecordMapping {

    /// The CloudKit record types synced by `CloudSyncEngine`, one per data category.
    public enum RecordType: String, CaseIterable {
        case source     = "Source"
        case album      = "Album"
        case track      = "Track"
        case asset      = "Asset"
        case playlist   = "Playlist"
        case playlistItem = "PlaylistItem"
        case favorite   = "Favorite"
        case playEvent  = "PlayEvent"
        case customArtwork = "CustomArtwork"
        case appSettings = "AppSettings"
    }

    /// The single fixed record name for the per-account settings singleton.
    public static let appSettingsRecordName = "app-settings"

    // MARK: - Record ID helpers

    public static func recordID(type: RecordType, syncID: String,
                         zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: "\(type.rawValue)-\(syncID)", zoneID: zoneID)
    }

    // MARK: - Source

    public static func record(from source: Source, zoneID: CKRecordZone.ID) -> CKRecord {
        let syncID = source.syncID ?? UUID().uuidString
        let record = CKRecord(recordType: RecordType.source.rawValue,
                              recordID: recordID(type: .source, syncID: syncID, zoneID: zoneID))
        record["syncID"] = syncID as CKRecordValue
        record["kind"] = source.kind.rawValue as CKRecordValue
        record["iaIdentifier"] = source.iaIdentifier as CKRecordValue?
        record["originalURL"] = source.originalURL as CKRecordValue?
        record["title"] = source.title as CKRecordValue
        record["addedAt"] = source.addedAt as CKRecordValue
        record["lastResolvedAt"] = source.lastResolvedAt as CKRecordValue?
        record["followUpdates"] = (source.followUpdates ? 1 : 0) as CKRecordValue
        record["licenseText"] = source.licenseText as CKRecordValue?
        record["memberCapHit"] = (source.memberCapHit ? 1 : 0) as CKRecordValue
        record["localIsFolder"] = (source.localIsFolder ? 1 : 0) as CKRecordValue
        return record
    }

    public static func source(from record: CKRecord) -> Source? {
        guard let syncID = record["syncID"] as? String,
              let kindRaw = record["kind"] as? String,
              let kind = SourceKind(rawValue: kindRaw),
              let title = record["title"] as? String,
              let addedAt = record["addedAt"] as? Date else { return nil }
        return Source(
            id: nil, kind: kind,
            iaIdentifier: record["iaIdentifier"] as? String,
            originalURL: record["originalURL"] as? String,
            title: title, addedAt: addedAt,
            lastResolvedAt: record["lastResolvedAt"] as? Date,
            followUpdates: (record["followUpdates"] as? Int ?? 0) != 0,
            licenseText: record["licenseText"] as? String,
            memberCapHit: (record["memberCapHit"] as? Int ?? 0) != 0,
            localIsFolder: (record["localIsFolder"] as? Int ?? 0) != 0,
            artworkTrackId: nil,
            syncID: syncID)
    }

    // MARK: - Album

    public static func record(from album: Album, sourceSyncID: String?,
                       zoneID: CKRecordZone.ID) -> CKRecord {
        let syncID = album.syncID ?? UUID().uuidString
        let record = CKRecord(recordType: RecordType.album.rawValue,
                              recordID: recordID(type: .album, syncID: syncID, zoneID: zoneID))
        record["syncID"] = syncID as CKRecordValue
        record["sourceSyncID"] = sourceSyncID as CKRecordValue?
        record["title"] = album.title as CKRecordValue
        record["artist"] = album.artist as CKRecordValue?
        record["year"] = album.year.map { $0 as CKRecordValue }
        record["artworkId"] = album.artworkId as CKRecordValue?
        return record
    }

    /// Returns the decoded album plus its parent `sourceSyncID` (for re-linking).
    public static func album(from record: CKRecord) -> (album: Album, sourceSyncID: String?)? {
        guard let syncID = record["syncID"] as? String,
              let title = record["title"] as? String else { return nil }
        let album = Album(id: nil, sourceId: 0, title: title,
                          artist: record["artist"] as? String,
                          year: record["year"] as? Int,
                          artworkId: record["artworkId"] as? String,
                          syncID: syncID)
        return (album, record["sourceSyncID"] as? String)
    }

    // MARK: - Track

    public static func record(from track: Track, sourceSyncID: String?, albumSyncID: String?,
                       zoneID: CKRecordZone.ID) -> CKRecord {
        let syncID = track.syncID ?? UUID().uuidString
        let record = CKRecord(recordType: RecordType.track.rawValue,
                              recordID: recordID(type: .track, syncID: syncID, zoneID: zoneID))
        record["syncID"] = syncID as CKRecordValue
        record["sourceSyncID"] = sourceSyncID as CKRecordValue?
        record["albumSyncID"] = albumSyncID as CKRecordValue?
        record["title"] = track.title as CKRecordValue
        record["trackNo"] = track.trackNo.map { $0 as CKRecordValue }
        record["discNo"] = track.discNo.map { $0 as CKRecordValue }
        record["durationSec"] = track.durationSec.map { $0 as CKRecordValue }
        record["codec"] = track.codec as CKRecordValue?
        record["sampleRate"] = track.sampleRate.map { $0 as CKRecordValue }
        record["bitDepthOrBitrate"] = track.bitDepthOrBitrate as CKRecordValue?
        record["sortKey"] = track.sortKey as CKRecordValue
        record["rgTrackGain"] = track.rgTrackGain.map { $0 as CKRecordValue }
        record["rgAlbumGain"] = track.rgAlbumGain.map { $0 as CKRecordValue }
        record["rgTrackPeak"] = track.rgTrackPeak.map { $0 as CKRecordValue }
        record["rgAlbumPeak"] = track.rgAlbumPeak.map { $0 as CKRecordValue }
        return record
    }

    public static func track(from record: CKRecord)
        -> (track: Track, sourceSyncID: String?, albumSyncID: String?)? {
        guard let syncID = record["syncID"] as? String,
              let title = record["title"] as? String,
              let sortKey = record["sortKey"] as? String else { return nil }
        let track = Track(id: nil, albumId: nil, sourceId: 0, title: title,
                          trackNo: record["trackNo"] as? Int,
                          discNo: record["discNo"] as? Int,
                          durationSec: record["durationSec"] as? Double,
                          codec: record["codec"] as? String,
                          sampleRate: record["sampleRate"] as? Int,
                          bitDepthOrBitrate: record["bitDepthOrBitrate"] as? String,
                          sortKey: sortKey,
                          rgTrackGain: record["rgTrackGain"] as? Double,
                          rgAlbumGain: record["rgAlbumGain"] as? Double,
                          rgTrackPeak: record["rgTrackPeak"] as? Double,
                          rgAlbumPeak: record["rgAlbumPeak"] as? Double,
                          syncID: syncID)
        return (track, record["sourceSyncID"] as? String, record["albumSyncID"] as? String)
    }

    // MARK: - Asset

    /// Local device-specific `bookmark` blobs are intentionally **omitted** (C4):
    /// they don't resolve on other devices. Pulled assets are marked
    /// `needsReimport` where no local file exists.
    public static func record(from asset: Asset, trackSyncID: String?,
                       zoneID: CKRecordZone.ID) -> CKRecord {
        let syncID = asset.syncID ?? UUID().uuidString
        let record = CKRecord(recordType: RecordType.asset.rawValue,
                              recordID: recordID(type: .asset, syncID: syncID, zoneID: zoneID))
        record["syncID"] = syncID as CKRecordValue
        record["trackSyncID"] = trackSyncID as CKRecordValue?
        record["kind"] = asset.kind.rawValue as CKRecordValue
        // NOTE: `bookmark` is deliberately not synced (device-specific).
        record["relPath"] = asset.relPath as CKRecordValue?
        record["remoteURL"] = asset.remoteURL as CKRecordValue?
        record["altRemoteURL"] = asset.altRemoteURL as CKRecordValue?
        record["opusRemoteURL"] = asset.opusRemoteURL as CKRecordValue?
        record["sizeBytes"] = asset.sizeBytes.map { $0 as CKRecordValue }
        record["unsupportedReason"] = asset.unsupportedReason as CKRecordValue?
        return record
    }

    public static func asset(from record: CKRecord) -> (asset: Asset, trackSyncID: String?)? {
        guard let syncID = record["syncID"] as? String,
              let kindRaw = record["kind"] as? String,
              let kind = AssetKind(rawValue: kindRaw) else { return nil }
        let hasRemote = (record["remoteURL"] as? String) != nil
        let asset = Asset(
            id: nil, trackId: 0, kind: kind,
            bookmark: nil,
            relPath: record["relPath"] as? String,
            remoteURL: record["remoteURL"] as? String,
            altRemoteURL: record["altRemoteURL"] as? String,
            opusRemoteURL: record["opusRemoteURL"] as? String,
            sizeBytes: record["sizeBytes"] as? Int64,
            unsupportedReason: record["unsupportedReason"] as? String,
            // A local-ref asset without a resolvable file on this device is
            // marked for re-import; remote/IA assets resolve normally (C4).
            needsReimport: (kind == .localRef || kind == .managedCopy) && !hasRemote,
            syncID: syncID)
        return (asset, record["trackSyncID"] as? String)
    }

    // MARK: - Playlist

    public static func record(from playlist: Playlist, zoneID: CKRecordZone.ID) -> CKRecord {
        let syncID = playlist.syncID ?? UUID().uuidString
        let record = CKRecord(recordType: RecordType.playlist.rawValue,
                              recordID: recordID(type: .playlist, syncID: syncID, zoneID: zoneID))
        record["syncID"] = syncID as CKRecordValue
        record["title"] = playlist.title as CKRecordValue
        record["kind"] = playlist.kind.rawValue as CKRecordValue
        record["watch"] = (playlist.watch ? 1 : 0) as CKRecordValue
        // folderBookmark is device-specific — not synced.
        return record
    }

    public static func playlist(from record: CKRecord) -> Playlist? {
        guard let syncID = record["syncID"] as? String,
              let title = record["title"] as? String,
              let kindRaw = record["kind"] as? String,
              let kind = PlaylistKind(rawValue: kindRaw) else { return nil }
        return Playlist(id: nil, title: title, kind: kind, folderBookmark: nil,
                        watch: (record["watch"] as? Int ?? 0) != 0, syncID: syncID)
    }

    // MARK: - PlaylistItem

    public static func record(from item: PlaylistItem, playlistSyncID: String?,
                       trackSyncID: String?, zoneID: CKRecordZone.ID) -> CKRecord {
        let syncID = item.syncID ?? UUID().uuidString
        let record = CKRecord(recordType: RecordType.playlistItem.rawValue,
                              recordID: recordID(type: .playlistItem, syncID: syncID, zoneID: zoneID))
        record["syncID"] = syncID as CKRecordValue
        record["playlistSyncID"] = playlistSyncID as CKRecordValue?
        record["trackSyncID"] = trackSyncID as CKRecordValue?
        record["position"] = item.position as CKRecordValue
        record["sectionTitle"] = item.sectionTitle as CKRecordValue?
        return record
    }

    public static func playlistItem(from record: CKRecord)
        -> (item: PlaylistItem, playlistSyncID: String?, trackSyncID: String?)? {
        guard let syncID = record["syncID"] as? String,
              let position = record["position"] as? Int else { return nil }
        let item = PlaylistItem(id: nil, playlistId: 0, position: position,
                                trackId: 0, sectionTitle: record["sectionTitle"] as? String,
                                syncID: syncID)
        return (item, record["playlistSyncID"] as? String, record["trackSyncID"] as? String)
    }

    // MARK: - Favorite

    public static func record(from favorite: Favorite, trackSyncID: String?,
                       zoneID: CKRecordZone.ID) -> CKRecord {
        let syncID = favorite.syncID ?? UUID().uuidString
        let record = CKRecord(recordType: RecordType.favorite.rawValue,
                              recordID: recordID(type: .favorite, syncID: syncID, zoneID: zoneID))
        record["syncID"] = syncID as CKRecordValue
        record["trackSyncID"] = trackSyncID as CKRecordValue?
        record["favoritedAt"] = favorite.favoritedAt as CKRecordValue
        return record
    }

    public static func favorite(from record: CKRecord) -> (favorite: Favorite, trackSyncID: String?)? {
        guard let syncID = record["syncID"] as? String,
              let favoritedAt = record["favoritedAt"] as? Date else { return nil }
        let favorite = Favorite(id: nil, trackId: 0, favoritedAt: favoritedAt, syncID: syncID)
        return (favorite, record["trackSyncID"] as? String)
    }

    // MARK: - PlayEvent

    public static func record(from event: PlayEvent, trackSyncID: String?,
                       zoneID: CKRecordZone.ID) -> CKRecord {
        let syncID = event.syncID ?? UUID().uuidString
        let record = CKRecord(recordType: RecordType.playEvent.rawValue,
                              recordID: recordID(type: .playEvent, syncID: syncID, zoneID: zoneID))
        record["syncID"] = syncID as CKRecordValue
        record["trackSyncID"] = trackSyncID as CKRecordValue?
        record["playedAt"] = event.playedAt as CKRecordValue
        return record
    }

    public static func playEvent(from record: CKRecord) -> (event: PlayEvent, trackSyncID: String?)? {
        guard let syncID = record["syncID"] as? String,
              let playedAt = record["playedAt"] as? Date else { return nil }
        let event = PlayEvent(id: nil, trackId: 0, playedAt: playedAt, syncID: syncID)
        return (event, record["trackSyncID"] as? String)
    }

    // MARK: - CustomArtwork

    /// The image file is carried as a `CKAsset`; on pull it is written into
    /// `Application Support/Tonearm/Artwork` keyed by `artworkId` (C3).
    public static func record(from artwork: CustomArtworkRecord, trackSyncID: String?,
                       fileURL: URL?, zoneID: CKRecordZone.ID) -> CKRecord {
        let syncID = artwork.syncID
        let record = CKRecord(recordType: RecordType.customArtwork.rawValue,
                              recordID: recordID(type: .customArtwork, syncID: syncID, zoneID: zoneID))
        record["syncID"] = syncID as CKRecordValue
        record["trackSyncID"] = trackSyncID as CKRecordValue?
        record["artworkId"] = artwork.artworkId as CKRecordValue
        if let fileURL { record["image"] = CKAsset(fileURL: fileURL) }
        return record
    }

    public static func customArtwork(from record: CKRecord)
        -> (artwork: CustomArtworkRecord, trackSyncID: String?, imageURL: URL?)? {
        guard let syncID = record["syncID"] as? String,
              let artworkId = record["artworkId"] as? String else { return nil }
        let asset = record["image"] as? CKAsset
        return (CustomArtworkRecord(syncID: syncID, artworkId: artworkId),
                record["trackSyncID"] as? String, asset?.fileURL)
    }

    // MARK: - AppSettings (EQ + synced prefs)

    public static func record(from settings: SyncedSettings, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(recordType: RecordType.appSettings.rawValue,
                              recordID: CKRecord.ID(recordName: appSettingsRecordName, zoneID: zoneID))
        record["eqEnabled"] = (settings.eqEnabled ? 1 : 0) as CKRecordValue
        record["eqGains"] = settings.eqGains as CKRecordValue
        if let data = try? JSONEncoder().encode(settings.userPresets) {
            record["userPresets"] = data as CKRecordValue
        }
        record["preferFLAC"] = (settings.preferFLAC ? 1 : 0) as CKRecordValue
        record["prefetchDepth"] = settings.prefetchDepth as CKRecordValue
        record["streamOnCellular"] = (settings.streamOnCellular ? 1 : 0) as CKRecordValue
        record["artworkLookup"] = (settings.artworkLookup ? 1 : 0) as CKRecordValue
        return record
    }

    public static func syncedSettings(from record: CKRecord) -> SyncedSettings? {
        guard record.recordType == RecordType.appSettings.rawValue else { return nil }
        var presets: [EQPreset] = []
        if let data = record["userPresets"] as? Data,
           let decoded = try? JSONDecoder().decode([EQPreset].self, from: data) {
            presets = decoded
        }
        return SyncedSettings(
            eqEnabled: (record["eqEnabled"] as? Int ?? 0) != 0,
            eqGains: (record["eqGains"] as? [Double]) ?? Array(repeating: 0, count: EQEngine.bandCount),
            userPresets: presets,
            preferFLAC: (record["preferFLAC"] as? Int ?? 0) != 0,
            prefetchDepth: record["prefetchDepth"] as? Int ?? 1,
            streamOnCellular: (record["streamOnCellular"] as? Int ?? 1) != 0,
            artworkLookup: (record["artworkLookup"] as? Int ?? 1) != 0)
    }
}

/// Lightweight value for the `custom_artwork` table (which has no domain struct):
/// carries the stable `syncID` plus the on-disk `artworkId` filename.
public struct CustomArtworkRecord: Equatable {
    public var syncID: String
    public var artworkId: String
    public var trackSyncID: String? = nil
}

/// The synced slice of app settings/EQ state (CloudKit-backed, not KVS — B2/C3).
public struct SyncedSettings: Equatable {
    public var eqEnabled: Bool
    public var eqGains: [Double]
    public var userPresets: [EQPreset]
    public var preferFLAC: Bool
    public var prefetchDepth: Int
    public var streamOnCellular: Bool
    public var artworkLookup: Bool
}
