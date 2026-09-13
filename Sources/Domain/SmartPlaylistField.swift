import Foundation

public enum SmartPlaylistValue: Equatable, Codable {
    case text(String)
    case number(Double)

    public var textValue: String {
        switch self {
        case .text(let value):
            return value
        case .number(let value):
            return SmartPlaylistFieldValue.formatNumber(value)
        }
    }

    public var numberValue: Double? {
        switch self {
        case .text(let value):
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        case .number(let value):
            return value
        }
    }
}

public enum SmartPlaylistField: String, Codable, CaseIterable {
    case title
    case artist
    case album
    case genre
    case composer
    case codec
    case sourceTitle
    case sourceKind
    case assetKind
    case assetLocation
    case year
    case durationSeconds
    case trackNumber
    case discNumber
    case sampleRate
    case sizeBytes
    case replayGain
    case dateAdded

    public var kind: SmartPlaylistFieldKind {
        switch self {
        case .title, .artist, .album, .genre, .composer, .codec, .sourceTitle,
             .sourceKind, .assetKind, .assetLocation:
            return .text
        case .year, .durationSeconds, .trackNumber, .discNumber, .sampleRate,
             .sizeBytes, .replayGain, .dateAdded:
            return .number
        }
    }

    public func value(in row: TrackRow) -> SmartPlaylistFieldValue {
        switch self {
        case .title:
            return .text(row.track.title)
        case .artist:
            return .text(row.artist?.name.nilIfBlank
                ?? row.album?.albumArtist?.nilIfBlank
                ?? row.album?.artist?.nilIfBlank)
        case .album:
            return .text(row.album?.title)
        case .genre:
            return .text(row.track.genre?.nilIfBlank ?? row.album?.genre?.nilIfBlank)
        case .composer:
            return .text(row.track.composer)
        case .codec:
            return .text(row.track.codec)
        case .sourceTitle:
            return .text(row.source?.title)
        case .sourceKind:
            return .text(row.source?.kind.rawValue)
        case .assetKind:
            return .text(row.asset?.kind.rawValue)
        case .assetLocation:
            return .text([row.asset?.relPath, row.asset?.remoteURL, row.asset?.altRemoteURL]
                .compactMap { $0?.nilIfBlank }
                .first)
        case .year:
            return .number(row.album?.year.map(Double.init))
        case .durationSeconds:
            return .number(row.track.durationSec)
        case .trackNumber:
            return .number(row.track.trackNo.map(Double.init))
        case .discNumber:
            return .number(row.track.discNo.map(Double.init))
        case .sampleRate:
            return .number(row.track.sampleRate.map(Double.init))
        case .sizeBytes:
            return .number(row.asset?.sizeBytes.map(Double.init))
        case .replayGain:
            return .number(row.track.rgTrackGain)
        case .dateAdded:
            return .number(row.source?.addedAt.timeIntervalSince1970)
        }
    }

    public var sql: SmartPlaylistFieldSQL {
        switch self {
        case .title:
            return SmartPlaylistFieldSQL(expression: "track.title", kind: kind)
        case .artist:
            return SmartPlaylistFieldSQL(
                expression: "COALESCE(track_artist.name, album.albumArtist, album.artist, album_artist.name)",
                kind: kind)
        case .album:
            return SmartPlaylistFieldSQL(expression: "album.title", kind: kind)
        case .genre:
            return SmartPlaylistFieldSQL(
                expression: "COALESCE(NULLIF(track.genre, ''), NULLIF(album.genre, ''))",
                kind: kind)
        case .composer:
            return SmartPlaylistFieldSQL(expression: "track.composer", kind: kind)
        case .codec:
            return SmartPlaylistFieldSQL(expression: "track.codec", kind: kind)
        case .sourceTitle:
            return SmartPlaylistFieldSQL(expression: "source.title", kind: kind)
        case .sourceKind:
            return SmartPlaylistFieldSQL(expression: "source.kind", kind: kind)
        case .assetKind:
            return SmartPlaylistFieldSQL(expression: "asset.kind", kind: kind)
        case .assetLocation:
            return SmartPlaylistFieldSQL(
                expression: "COALESCE(NULLIF(asset.relPath, ''), NULLIF(asset.remoteURL, ''), NULLIF(asset.altRemoteURL, ''))",
                kind: kind)
        case .year:
            return SmartPlaylistFieldSQL(expression: "album.year", kind: kind)
        case .durationSeconds:
            return SmartPlaylistFieldSQL(expression: "track.durationSec", kind: kind)
        case .trackNumber:
            return SmartPlaylistFieldSQL(expression: "track.trackNo", kind: kind)
        case .discNumber:
            return SmartPlaylistFieldSQL(expression: "track.discNo", kind: kind)
        case .sampleRate:
            return SmartPlaylistFieldSQL(expression: "track.sampleRate", kind: kind)
        case .sizeBytes:
            return SmartPlaylistFieldSQL(expression: "asset.sizeBytes", kind: kind)
        case .replayGain:
            return SmartPlaylistFieldSQL(expression: "track.rgTrackGain", kind: kind)
        case .dateAdded:
            return SmartPlaylistFieldSQL(
                expression: "CAST(strftime('%s', source.addedAt) AS REAL)",
                kind: kind)
        }
    }
}

public enum SmartPlaylistFieldKind {
    case text
    case number
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
