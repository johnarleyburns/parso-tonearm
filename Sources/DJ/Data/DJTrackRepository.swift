import Foundation
import GRDB

/// Filter surface for library listings. Search is literal (title/artist/album);
/// semantic queries arrive later via the §18.3 `LibraryQuery` extension when the
/// embedder lands (M2).
public struct LibraryQuery: Equatable, Sendable {
    public var searchText: String
    public var analysisState: String?

    public init(searchText: String = "", analysisState: String? = nil) {
        self.searchText = searchText
        self.analysisState = analysisState
    }
}

/// Flat listing row for fast library screens (§18.2). `artistNames` is the
/// ordered `GROUP_CONCAT` of primary artists via `track_artist.position`, so a
/// list row never needs an N+1 object graph.
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

/// Grouped query surface over the DJ database (§18.3). Reactive listing bridges
/// GRDB `ValueObservation` to an `AsyncStream`, so the Library screen updates
/// live as analysis completes without polling.
public struct DJTrackRepository: Sendable {
    public let pool: DatabasePool

    public init(pool: DatabasePool) {
        self.pool = pool
    }

    /// One-shot fetch, deterministic — the testable core the observation wraps.
    public func tracks(matching query: LibraryQuery) throws -> [DJTrackRow] {
        try pool.read { db in
            try Self.fetchAll(db, query)
        }
    }

    public func trackCount() throws -> Int {
        try pool.read { db in
            try DJTrack.fetchCount(db)
        }
    }

    /// Live listing. Emits the current rows immediately, then re-emits on any
    /// change to the tracked tables. Cancelling the stream stops the observation.
    public func observeAll(_ query: LibraryQuery) -> AsyncStream<[DJTrackRow]> {
        AsyncStream { continuation in
            let observation = ValueObservation.tracking { db in
                try Self.fetchAll(db, query)
            }
            let cancellable = observation.start(
                in: pool,
                scheduling: .async(onQueue: .main),
                onError: { _ in continuation.finish() },
                onChange: { rows in continuation.yield(rows) })
            continuation.onTermination = { _ in
                cancellable.cancel()
            }
        }
    }

    // MARK: - Listing SQL

    /// Single listing statement for both the sync fetch and the observation, so
    /// the observed value and a plain read can never disagree.
    private static func fetchAll(_ db: Database, _ query: LibraryQuery) throws -> [DJTrackRow] {
        var sql = baseListingSQL
        var arguments: [DatabaseValueConvertible?] = []
        var conditions: [String] = []

        if !query.searchText.isEmpty {
            let like = likePattern(query.searchText)
            conditions.append(
                "(t.title LIKE ? ESCAPE '\\' OR al.title LIKE ? ESCAPE '\\' OR EXISTS ("
                + "SELECT 1 FROM track_artist s_ta JOIN artist s_ar ON s_ar.id = s_ta.artistID "
                + "WHERE s_ta.trackID = t.id AND s_ar.name LIKE ? ESCAPE '\\'))")
            arguments += [like, like, like]
        }
        if let state = query.analysisState, !state.isEmpty {
            conditions.append("t.analysisState = ?")
            arguments.append(state)
        }

        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " GROUP BY t.id ORDER BY t.sortKey COLLATE NOCASE, t.id"

        let request = SQLRequest<DJTrackRow>(sql: sql, arguments: StatementArguments(arguments))
        return try request.fetchAll(db)
    }

    private static let baseListingSQL = """
        SELECT
            t.id AS id,
            t.title AS title,
            COALESCE((
                SELECT GROUP_CONCAT(sub.name, ', ')
                FROM (
                    SELECT ar.name AS name
                    FROM track_artist ta
                    JOIN artist ar ON ar.id = ta.artistID
                    WHERE ta.trackID = t.id
                    ORDER BY ta.position, ar.name
                ) AS sub
            ), '') AS artistNames,
            al.title AS albumTitle,
            t.durationSec AS durationSec,
            t.bpm AS bpm,
            t.camelot AS camelot,
            t.energy AS energy,
            t.analysisState AS analysisState,
            t.stemState AS stemState
        FROM track t
        LEFT JOIN album al ON al.id = t.albumID
        """

    /// Escapes the three `LIKE` wildcards so user text is matched literally.
    private static func likePattern(_ input: String) -> String {
        let escaped = input
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }
}
