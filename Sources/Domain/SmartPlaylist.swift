import Foundation
import GRDB

struct SmartPlaylist: Equatable, Codable {
    var root: SmartPlaylistRuleGroup
    var sort: Sort
    var limit: Int?

    init(root: SmartPlaylistRuleGroup = SmartPlaylistRuleGroup(),
         sort: Sort = Sort(field: .title, direction: .ascending),
         limit: Int? = nil) {
        self.root = root
        self.sort = sort
        self.limit = limit
    }

    func evaluate(rows: [TrackRow]) -> [TrackRow] {
        var matches = rows.filter { root.matches($0, isRoot: true) }
        matches.sort { sort.orders($0, before: $1) }
        if let limit {
            return Array(matches.prefix(max(0, limit)))
        }
        return matches
    }

    func compiledQuery() -> SmartPlaylistQuery {
        var builder = SmartPlaylistSQLBuilder()
        let whereClause = root.sql(isRoot: true, builder: &builder)
        let sortSQL = sort.sql()
        var sql = """
            SELECT track.* FROM track
            LEFT JOIN album ON album.id = track.albumId
            LEFT JOIN artist track_artist ON track_artist.id = track.artistId
            LEFT JOIN artist album_artist ON album_artist.id = album.artistId
            LEFT JOIN source ON source.id = track.sourceId
            LEFT JOIN asset ON asset.id = (
                SELECT first_asset.id FROM asset first_asset
                WHERE first_asset.trackId = track.id
                ORDER BY first_asset.id
                LIMIT 1
            )
            WHERE \(whereClause)
            ORDER BY \(sortSQL), track.id ASC
            """
        if let limit {
            sql += "\nLIMIT \(builder.bind(max(0, limit)))"
        }
        return SmartPlaylistQuery(sql: sql, arguments: builder.arguments)
    }

    struct Sort: Equatable, Codable {
        var field: SmartPlaylistField
        var direction: Direction

        enum Direction: String, Codable, CaseIterable {
            case ascending
            case descending
        }

        func orders(_ lhs: TrackRow, before rhs: TrackRow) -> Bool {
            let left = field.value(in: lhs)
            let right = field.value(in: rhs)
            if left.isEmpty != right.isEmpty { return !left.isEmpty }

            let comparison: ComparisonResult
            switch field.kind {
            case .text:
                comparison = left.textValue.localizedCaseInsensitiveCompare(right.textValue)
            case .number:
                comparison = compareNumbers(left.numberValue, right.numberValue)
            }

            if comparison != .orderedSame {
                switch direction {
                case .ascending: return comparison == .orderedAscending
                case .descending: return comparison == .orderedDescending
                }
            }
            return lhs.id < rhs.id
        }

        func sql() -> String {
            let fieldSQL = field.sql
            let order = direction == .ascending ? "ASC" : "DESC"
            let missing = field.kind == .text
                ? "CASE WHEN TRIM(COALESCE(\(fieldSQL.expression), '')) = '' THEN 1 ELSE 0 END ASC"
                : "CASE WHEN \(fieldSQL.expression) IS NULL THEN 1 ELSE 0 END ASC"
            switch field.kind {
            case .text:
                return "\(missing), LOWER(COALESCE(\(fieldSQL.expression), '')) COLLATE BINARY \(order)"
            case .number:
                return "\(missing), \(fieldSQL.expression) \(order)"
            }
        }

        private func compareNumbers(_ lhs: Double?, _ rhs: Double?) -> ComparisonResult {
            switch (lhs, rhs) {
            case let (left?, right?):
                if left < right { return .orderedAscending }
                if left > right { return .orderedDescending }
                return .orderedSame
            case (nil, nil):
                return .orderedSame
            case (nil, _?):
                return .orderedDescending
            case (_?, nil):
                return .orderedAscending
            }
        }
    }
}

struct SmartPlaylistRuleGroup: Equatable, Codable {
    var conjunction: SmartPlaylistConjunction
    var predicates: [SmartPlaylistPredicate]

    init(conjunction: SmartPlaylistConjunction = .all,
         predicates: [SmartPlaylistPredicate] = []) {
        self.conjunction = conjunction
        self.predicates = predicates
    }

    func matches(_ row: TrackRow, isRoot: Bool = false) -> Bool {
        guard !predicates.isEmpty else { return isRoot || conjunction == .all }
        switch conjunction {
        case .all:
            return predicates.allSatisfy { $0.matches(row) }
        case .any:
            return predicates.contains { $0.matches(row) }
        }
    }

    func sql(isRoot: Bool = false, builder: inout SmartPlaylistSQLBuilder) -> String {
        guard !predicates.isEmpty else { return isRoot || conjunction == .all ? "1 = 1" : "0 = 1" }
        let separator = conjunction == .all ? " AND " : " OR "
        return predicates
            .map { "(\($0.sql(builder: &builder)))" }
            .joined(separator: separator)
    }
}

enum SmartPlaylistConjunction: String, Codable, CaseIterable {
    case all
    case any
}

indirect enum SmartPlaylistPredicate: Equatable, Codable {
    case rule(SmartPlaylistRule)
    case group(SmartPlaylistRuleGroup)

    func matches(_ row: TrackRow) -> Bool {
        switch self {
        case .rule(let rule): return rule.matches(row)
        case .group(let group): return group.matches(row)
        }
    }

    func sql(builder: inout SmartPlaylistSQLBuilder) -> String {
        switch self {
        case .rule(let rule): return rule.sql(builder: &builder)
        case .group(let group): return group.sql(builder: &builder)
        }
    }
}

struct SmartPlaylistRule: Equatable, Codable {
    var field: SmartPlaylistField
    var op: SmartPlaylistOperator
    var value: SmartPlaylistValue?
    var upperValue: SmartPlaylistValue?

    init(field: SmartPlaylistField,
         op: SmartPlaylistOperator,
         value: SmartPlaylistValue? = nil,
         upperValue: SmartPlaylistValue? = nil) {
        self.field = field
        self.op = op
        self.value = value
        self.upperValue = upperValue
    }

    func matches(_ row: TrackRow) -> Bool {
        let fieldValue = field.value(in: row)
        switch op {
        case .contains:
            return fieldValue.normalizedText.contains(requiredText())
        case .notContains:
            return !fieldValue.normalizedText.contains(requiredText())
        case .equals:
            return equals(fieldValue)
        case .notEquals:
            return !equals(fieldValue)
        case .beginsWith:
            return fieldValue.normalizedText.hasPrefix(requiredText())
        case .endsWith:
            return fieldValue.normalizedText.hasSuffix(requiredText())
        case .greaterThan:
            guard let left = fieldValue.numberValue, let right = value?.numberValue else { return false }
            return left > right
        case .greaterThanOrEqual:
            guard let left = fieldValue.numberValue, let right = value?.numberValue else { return false }
            return left >= right
        case .lessThan:
            guard let left = fieldValue.numberValue, let right = value?.numberValue else { return false }
            return left < right
        case .lessThanOrEqual:
            guard let left = fieldValue.numberValue, let right = value?.numberValue else { return false }
            return left <= right
        case .between:
            guard let left = fieldValue.numberValue,
                  let first = value?.numberValue,
                  let second = upperValue?.numberValue else { return false }
            let lower = min(first, second)
            let upper = max(first, second)
            return lower <= left && left <= upper
        case .isEmpty:
            return fieldValue.isEmpty
        case .isNotEmpty:
            return !fieldValue.isEmpty
        }
    }

    func sql(builder: inout SmartPlaylistSQLBuilder) -> String {
        let fieldSQL = field.sql
        switch op {
        case .contains:
            return "\(fieldSQL.textExpression) LIKE \(builder.bind(likePattern(requiredText()))) ESCAPE '\\'"
        case .notContains:
            return "\(fieldSQL.textExpression) NOT LIKE \(builder.bind(likePattern(requiredText()))) ESCAPE '\\'"
        case .equals:
            switch field.kind {
            case .text:
                return "\(fieldSQL.textExpression) = \(builder.bind(requiredText()))"
            case .number:
                guard let value = value?.numberValue else { return "0 = 1" }
                return "\(fieldSQL.expression) = \(builder.bind(value))"
            }
        case .notEquals:
            switch field.kind {
            case .text:
                return "\(fieldSQL.textExpression) != \(builder.bind(requiredText()))"
            case .number:
                guard let value = value?.numberValue else { return "1 = 1" }
                return "(\(fieldSQL.expression) IS NULL OR \(fieldSQL.expression) != \(builder.bind(value)))"
            }
        case .beginsWith:
            return "\(fieldSQL.textExpression) LIKE \(builder.bind(prefixPattern(requiredText()))) ESCAPE '\\'"
        case .endsWith:
            return "\(fieldSQL.textExpression) LIKE \(builder.bind(suffixPattern(requiredText()))) ESCAPE '\\'"
        case .greaterThan:
            return numericSQL(fieldSQL, ">", builder: &builder)
        case .greaterThanOrEqual:
            return numericSQL(fieldSQL, ">=", builder: &builder)
        case .lessThan:
            return numericSQL(fieldSQL, "<", builder: &builder)
        case .lessThanOrEqual:
            return numericSQL(fieldSQL, "<=", builder: &builder)
        case .between:
            guard field.kind == .number else { return "0 = 1" }
            guard let first = value?.numberValue, let second = upperValue?.numberValue else { return "0 = 1" }
            let lower = min(first, second)
            let upper = max(first, second)
            return "(\(fieldSQL.numericExpression) >= \(builder.bind(lower)) AND \(fieldSQL.numericExpression) <= \(builder.bind(upper)))"
        case .isEmpty:
            switch field.kind {
            case .text:
                return "TRIM(COALESCE(\(fieldSQL.expression), '')) = ''"
            case .number:
                return "\(fieldSQL.expression) IS NULL"
            }
        case .isNotEmpty:
            switch field.kind {
            case .text:
                return "TRIM(COALESCE(\(fieldSQL.expression), '')) != ''"
            case .number:
                return "\(fieldSQL.expression) IS NOT NULL"
            }
        }
    }

    private func equals(_ fieldValue: SmartPlaylistFieldValue) -> Bool {
        switch field.kind {
        case .text:
            return fieldValue.normalizedText == requiredText()
        case .number:
            guard let left = fieldValue.numberValue, let right = value?.numberValue else { return false }
            return left == right
        }
    }

    private func numericSQL(_ fieldSQL: SmartPlaylistFieldSQL,
                            _ comparison: String,
                            builder: inout SmartPlaylistSQLBuilder) -> String {
        guard field.kind == .number else { return "0 = 1" }
        guard let value = value?.numberValue else { return "0 = 1" }
        return "\(fieldSQL.numericExpression) \(comparison) \(builder.bind(value))"
    }

    private func requiredText() -> String {
        (value?.textValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func likePattern(_ value: String) -> String {
        "%\(escapedLike(value))%"
    }

    private func prefixPattern(_ value: String) -> String {
        "\(escapedLike(value))%"
    }

    private func suffixPattern(_ value: String) -> String {
        "%\(escapedLike(value))"
    }

    private func escapedLike(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "%": escaped.append("\\%")
            case "_": escaped.append("\\_")
            case "\\": escaped.append("\\\\")
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }
}

enum SmartPlaylistOperator: String, Codable, CaseIterable {
    case contains
    case notContains
    case equals
    case notEquals
    case beginsWith
    case endsWith
    case greaterThan
    case greaterThanOrEqual
    case lessThan
    case lessThanOrEqual
    case between
    case isEmpty
    case isNotEmpty
}

enum SmartPlaylistValue: Equatable, Codable {
    case text(String)
    case number(Double)

    var textValue: String {
        switch self {
        case .text(let value):
            return value
        case .number(let value):
            return SmartPlaylistFieldValue.formatNumber(value)
        }
    }

    var numberValue: Double? {
        switch self {
        case .text(let value):
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        case .number(let value):
            return value
        }
    }
}

enum SmartPlaylistField: String, Codable, CaseIterable {
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

    var kind: SmartPlaylistFieldKind {
        switch self {
        case .title, .artist, .album, .genre, .composer, .codec, .sourceTitle,
             .sourceKind, .assetKind, .assetLocation:
            return .text
        case .year, .durationSeconds, .trackNumber, .discNumber, .sampleRate,
             .sizeBytes, .replayGain, .dateAdded:
            return .number
        }
    }

    func value(in row: TrackRow) -> SmartPlaylistFieldValue {
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

    var sql: SmartPlaylistFieldSQL {
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

enum SmartPlaylistFieldKind {
    case text
    case number
}

struct SmartPlaylistQuery {
    var sql: String
    var arguments: StatementArguments
}

struct SmartPlaylistFieldSQL {
    var expression: String
    var kind: SmartPlaylistFieldKind

    var textExpression: String {
        "LOWER(COALESCE(CAST(\(expression) AS TEXT), ''))"
    }

    var numericExpression: String {
        kind == .number ? expression : "CAST(\(expression) AS REAL)"
    }
}

struct SmartPlaylistFieldValue: Equatable {
    private var storage: Storage

    private enum Storage: Equatable {
        case text(String?)
        case number(Double?)
    }

    static func text(_ value: String?) -> SmartPlaylistFieldValue {
        SmartPlaylistFieldValue(storage: .text(value))
    }

    static func number(_ value: Double?) -> SmartPlaylistFieldValue {
        SmartPlaylistFieldValue(storage: .number(value))
    }

    var isEmpty: Bool {
        switch storage {
        case .text(let value):
            return value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        case .number(let value):
            return value == nil
        }
    }

    var textValue: String {
        switch storage {
        case .text(let value):
            return value ?? ""
        case .number(let value):
            return value.map(Self.formatNumber) ?? ""
        }
    }

    var normalizedText: String {
        textValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    var numberValue: Double? {
        switch storage {
        case .text:
            return nil
        case .number(let value):
            return value
        }
    }

    static func formatNumber(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int64(value))
        }
        return String(value)
    }
}

struct SmartPlaylistSQLBuilder {
    private(set) var arguments = StatementArguments()

    mutating func bind(_ value: (any DatabaseValueConvertible)?) -> String {
        _ = arguments.append(contentsOf: StatementArguments([value]))
        return "?"
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
