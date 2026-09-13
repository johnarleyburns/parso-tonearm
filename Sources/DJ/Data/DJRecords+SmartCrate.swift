import Foundation
import GRDB

// MARK: - Smart crates (§14, FR-SEM-5)
//
// Split out of `DJRecords.swift` — standalone record types, no cross-file
// access-level changes needed.

/// A saved `VibeQuery` that re-evaluates live against whatever the library has
/// now (§14, mockup `ipad/04b` "Save as Smart Crate"). The full-fidelity query
/// lives in `queryJSON`; the normalized `crate_rule` rows let relational filters
/// read the musical constraints without decoding (§14.3).
public struct SmartCrate: Codable, Identifiable, FetchableRecord,
                          MutablePersistableRecord, Equatable, Sendable {
    public var id: Int64?
    public var syncID: String
    public var name: String
    /// Encoded `VibeQuery` — the crate IS the query, not a frozen list.
    public var queryJSON: String
    public var pinned: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: Int64? = nil,
                syncID: String,
                name: String,
                queryJSON: String,
                pinned: Bool = false,
                createdAt: Date,
                updatedAt: Date) {
        self.id = id
        self.syncID = syncID
        self.name = name
        self.queryJSON = queryJSON
        self.pinned = pinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static let databaseTableName = "smart_crate"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// A normalized musical constraint of a smart crate (§14.3): a filter that a
/// relational query can read without decoding `smart_crate.queryJSON`.
public struct CrateRule: Codable, Identifiable, FetchableRecord,
                         MutablePersistableRecord, Equatable, Sendable {
    public var id: Int64?
    public var crateID: Int64
    /// `bpm | camelot | energy | genre | rating | addedAt` (§14.3).
    public var field: String
    /// `between | eq | gte | lte | in` (§14.3).
    public var op: String
    /// JSON-encoded operand, e.g. `[118,132]` for bpm `between`.
    public var valueJSON: String

    public init(id: Int64? = nil, crateID: Int64, field: String, op: String,
                valueJSON: String) {
        self.id = id
        self.crateID = crateID
        self.field = field
        self.op = op
        self.valueJSON = valueJSON
    }

    public static let databaseTableName = "crate_rule"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
