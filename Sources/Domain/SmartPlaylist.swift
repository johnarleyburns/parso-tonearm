import Foundation
import GRDB

// The rest of this domain: `SmartPlaylistRuleGroup`/`SmartPlaylistConjunction`/
// `SmartPlaylistPredicate` live in `SmartPlaylistRuleGroup.swift`;
// `SmartPlaylistRule`/`SmartPlaylistOperator` in `SmartPlaylistRule.swift`;
// `SmartPlaylistValue`/`SmartPlaylistField`/`SmartPlaylistFieldKind` in
// `SmartPlaylistField.swift`; and `SmartPlaylistQuery`/`SmartPlaylistFieldSQL`/
// `SmartPlaylistFieldValue`/`SmartPlaylistSQLBuilder` in
// `SmartPlaylistQuery.swift`. None of the split types share private state
// across files — each is independent, so no access-level widening was needed.
public struct SmartPlaylist: @unchecked Sendable, Equatable, Codable {
    public var root: SmartPlaylistRuleGroup
    public var sort: Sort
    public var limit: Int?

    public init(root: SmartPlaylistRuleGroup = SmartPlaylistRuleGroup(),
         sort: Sort = Sort(field: .title, direction: .ascending),
         limit: Int? = nil) {
        self.root = root
        self.sort = sort
        self.limit = limit
    }

    public func evaluate(rows: [TrackRow]) -> [TrackRow] {
        var matches = rows.filter { root.matches($0, isRoot: true) }
        matches.sort { sort.orders($0, before: $1) }
        if let limit {
            return Array(matches.prefix(max(0, limit)))
        }
        return matches
    }

    public func compiledQuery() -> SmartPlaylistQuery {
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

    public struct Sort: Equatable, Codable {
        public var field: SmartPlaylistField
        public var direction: Direction

        public init(field: SmartPlaylistField, direction: Direction) {
            self.field = field
            self.direction = direction
        }

        public enum Direction: String, Codable, CaseIterable {
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
