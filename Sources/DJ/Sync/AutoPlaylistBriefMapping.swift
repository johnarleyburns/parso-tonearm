import Foundation

/// Pure, CloudKit-free round-trip mapping of §38.2's `AutoPlaylistBrief` payload
/// (plan §2.9). The `auto_playlist_brief` row already carries `syncID` and every
/// field the CKRecord will carry in M6 (`prompt`, `arcKind`, `arcPoints`,
/// `targetSeconds`, `constraintsJSON`, `seed`); this mapping is the repo's
/// `RecordMapping` convention without CloudKit — a Codable envelope, byte-exact
/// tested, with no I/O. The live CKRecord translation and `DJSyncService` wiring
/// land in M6 with `DJRecordMapping` (Appendix M.7); importing CloudKit into the
/// DJ core now would add a dependency or force a `#if os(...)` (invariant §49.3.6).
public enum AutoPlaylistBriefMapping {

    /// The §38.2 payload as a Codable envelope.
    public struct Payload: Codable, Sendable, Equatable {
        public var syncID: String
        public var prompt: String
        public var arcKind: String
        /// Canonical `EnergyArc` parameter payload (`level`/`peakAt`/`cycles`/`points`).
        public var arcPointsJSON: String?
        public var targetSeconds: Int?
        public var targetTrackCount: Int?
        public var constraintsJSON: String
        public var seedTrackID: Int64?
        public var seedCrateID: Int64?
        public var randomSeed: Int64

        public init(syncID: String,
                    prompt: String,
                    arcKind: String,
                    arcPointsJSON: String? = nil,
                    targetSeconds: Int? = nil,
                    targetTrackCount: Int? = nil,
                    constraintsJSON: String,
                    seedTrackID: Int64? = nil,
                    seedCrateID: Int64? = nil,
                    randomSeed: Int64) {
            self.syncID = syncID
            self.prompt = prompt
            self.arcKind = arcKind
            self.arcPointsJSON = arcPointsJSON
            self.targetSeconds = targetSeconds
            self.targetTrackCount = targetTrackCount
            self.constraintsJSON = constraintsJSON
            self.seedTrackID = seedTrackID
            self.seedCrateID = seedCrateID
            self.randomSeed = randomSeed
        }
    }

    /// The CloudKit record name this envelope maps to in M6 — the repo's
    /// `"<Type>-<syncID>"` convention (§38.2).
    public static func recordName(syncID: String) -> String {
        "AutoPlaylistBrief-\(syncID)"
    }

    public static func payload(from brief: AutoPlaylistBrief) -> Payload {
        Payload(syncID: brief.syncID,
                prompt: brief.prompt,
                arcKind: brief.arcKind,
                arcPointsJSON: brief.arcPointsJSON,
                targetSeconds: brief.targetSeconds,
                targetTrackCount: brief.targetTrackCount,
                constraintsJSON: brief.constraintsJSON,
                seedTrackID: brief.seedTrackID,
                seedCrateID: brief.seedCrateID,
                randomSeed: brief.randomSeed)
    }

    public static func brief(from payload: Payload, id: Int64? = nil,
                             createdAt: Date = Date(), updatedAt: Date = Date())
        -> AutoPlaylistBrief {
        AutoPlaylistBrief(id: id,
                          syncID: payload.syncID,
                          prompt: payload.prompt,
                          arcKind: payload.arcKind,
                          arcPointsJSON: payload.arcPointsJSON,
                          targetSeconds: payload.targetSeconds,
                          targetTrackCount: payload.targetTrackCount,
                          constraintsJSON: payload.constraintsJSON,
                          seedTrackID: payload.seedTrackID,
                          seedCrateID: payload.seedCrateID,
                          randomSeed: payload.randomSeed,
                          createdAt: createdAt,
                          updatedAt: updatedAt)
    }

    /// Canonical byte-exact encoding (`.sortedKeys`, NFR-DET-3): the round-trip
    /// test pins encode → decode → encode ≡ same bytes.
    public static func encode(_ payload: Payload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    public static func decode(_ data: Data) throws -> Payload {
        try JSONDecoder().decode(Payload.self, from: data)
    }
}
