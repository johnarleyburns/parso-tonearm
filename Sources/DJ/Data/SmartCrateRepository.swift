import Foundation
import GRDB

extension VibeQuery {
    /// Deterministic, canonical JSON form for `smart_crate.queryJSON` (§14.3).
    /// `.sortedKeys` fixes the key order, so the same query always encodes to the
    /// same bytes (NFR-DET-3) and an encode → decode → encode round-trip is
    /// byte-identical — which the byte-exact test pins.
    public func encodedJSONString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        return String(data: data, encoding: .utf8)!
    }

    public static func decodeJSON(_ string: String) throws -> VibeQuery {
        try JSONDecoder().decode(VibeQuery.self, from: Data(string.utf8))
    }
}

/// Small repository over `smart_crate` + `crate_rule` (§14, plan commit 2.5):
/// save a `VibeQuery` as a crate, load it back byte-exact, and re-evaluate it
/// live against the current index (FR-SEM-5 — a crate is the query, not a copy).
public struct SmartCrateRepository: Sendable {
    public let pool: DatabasePool

    public init(pool: DatabasePool) {
        self.pool = pool
    }

    // MARK: - Save / load

    /// Persist a `VibeQuery` as a crate: the full-fidelity `queryJSON` plus the
    /// normalized musical constraints as `crate_rule` rows, in one transaction.
    public func save(query: VibeQuery, name: String) throws -> Int64 {
        try pool.write { db in
            let now = Date()
            var crate = SmartCrate(syncID: UUID().uuidString,
                                   name: name,
                                   queryJSON: try query.encodedJSONString(),
                                   pinned: false,
                                   createdAt: now,
                                   updatedAt: now)
            try crate.insert(db)
            guard let crateID = crate.id else {
                throw SmartCrateError.persistFailed
            }
            for rule in normalizedRules(for: query) {
                var stored = rule
                stored.crateID = crateID
                try stored.insert(db)
            }
            return crateID
        }
    }

    public func crates() throws -> [SmartCrate] {
        try pool.read { db in
            try SmartCrate.order(Column("updatedAt").desc).fetchAll(db)
        }
    }

    public func crate(id: Int64) throws -> SmartCrate? {
        try pool.read { db in
            try SmartCrate.fetchOne(db, key: id)
        }
    }

    public func rules(for id: Int64) throws -> [CrateRule] {
        try pool.read { db in
            try CrateRule.filter(Column("crateID") == id).fetchAll(db)
        }
    }

    /// The stored query, decoded byte-exact from `queryJSON`.
    public func query(for id: Int64) throws -> VibeQuery? {
        try pool.read { db in
            guard let crate = try SmartCrate.fetchOne(db, key: id) else { return nil }
            return try VibeQuery.decodeJSON(crate.queryJSON)
        }
    }

    /// Delete a crate; `crate_rule` rows cascade (§14.3).
    public func delete(id: Int64) throws {
        _ = try pool.write { db in
            try SmartCrate.deleteOne(db, key: id)
        }
    }

    // MARK: - Live re-evaluation (FR-SEM-5)

    /// Run the stored query against the current index. A crate re-evaluates as
    /// the library grows, so newly imported tracks that fit appear automatically
    /// (Appendix H.3 step 5).
    public func evaluate(id: Int64,
                         using service: SemanticSearchService) async throws -> SearchResponse {
        guard let query = try query(for: id) else {
            return SearchResponse(state: .emptyQuery, results: [], coverage: 0,
                                  latencyMillis: 0)
        }
        return try await service.search(query)
    }

    // MARK: - Normalization (§14.3)

    /// The query's relational filters as `crate_rule` rows. A purely-semantic
    /// crate (text + terms only) has no normalized rules — `queryJSON` is always
    /// the source of truth.
    public func normalizedRules(for query: VibeQuery) -> [CrateRule] {
        var rules: [CrateRule] = []
        if let lo = query.bpmLo, let hi = query.bpmHi {
            let encoded = (try? JSONEncoder().encode([lo, hi]))
                .map { String(data: $0, encoding: .utf8)! }
            rules.append(CrateRule(crateID: 0, field: "bpm", op: "between",
                                   valueJSON: encoded ?? "[]"))
        }
        if let key = query.compatibleWithKey {
            let codes = Camelot.compatible(key).sorted { $0.code < $1.code }.map(\.code)
            let encoded = (try? JSONEncoder().encode(codes))
                .map { String(data: $0, encoding: .utf8)! }
            rules.append(CrateRule(crateID: 0, field: "camelot", op: "in",
                                   valueJSON: encoded ?? "[]"))
        }
        return rules
    }
}

public enum SmartCrateError: Error {
    case persistFailed
}
