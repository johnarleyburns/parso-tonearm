#if !os(watchOS)
import Foundation
import GRDB

/// The one explicit embedding-space contract: audio and text vectors are
/// native `dimensions`-wide and only comparable inside the same space. The
/// `fingerprint` is persisted in `discovery_embedding_space`; a mismatch
/// resets derived discovery state (never user library data).
///
/// The checksums are the released archive hashes in `Config/models.lock`.
public struct EmbeddingSpace: Codable, Equatable, Sendable {
    public let identifier: String
    public let dimensions: Int
    public let audioModelSHA256: String
    public let textModelSHA256: String
    public let projectionSHA256: String
    public let preprocessingVersion: Int
    public let samplingVersion: Int

    public init(
        identifier: String, dimensions: Int, audioModelSHA256: String, textModelSHA256: String,
        projectionSHA256: String, preprocessingVersion: Int, samplingVersion: Int
    ) {
        self.identifier = identifier
        self.dimensions = dimensions
        self.audioModelSHA256 = audioModelSHA256
        self.textModelSHA256 = textModelSHA256
        self.projectionSHA256 = projectionSHA256
        self.preprocessingVersion = preprocessingVersion
        self.samplingVersion = samplingVersion
    }

    public var fingerprint: String {
        [identifier, String(dimensions), audioModelSHA256, textModelSHA256,
         projectionSHA256, String(preprocessingVersion), String(samplingVersion)]
            .joined(separator: ":")
    }

    /// Native 128-D int4 CLAP space: the published release assets and frozen projection.
    public static let current = EmbeddingSpace(
        identifier: "clap-int4-128-v1",
        dimensions: 128,
        audioModelSHA256: "b69c830c05cc006e380c2f7ab938c2c561721be868f3a45613982c046db93b7a",
        textModelSHA256: "429a248e33d03b106e4f80a7098c66fdadc022b83eee72710347629fc341fb86",
        projectionSHA256: "df530674afd552bffc04ad38acbabf028dc279408de0a57238a53a3ea763f32a",
        preprocessingVersion: DiscoveryPipelineVersion.preprocessing,
        samplingVersion: DiscoveryPipelineVersion.sampling)

    /// Compares the stored fingerprint with `space` and, on a missing row or
    /// mismatch, atomically clears only derived discovery tables and records
    /// the new fingerprint. The vector cache file is removed after commit.
    /// A failed transaction rolls back, leaving the old state and fingerprint.
    /// - Returns: true when a reset was performed.
    @discardableResult
    public static func install(
        _ space: EmbeddingSpace = .current, on writer: any DatabaseWriter,
        cacheURL: URL = DiscoveryCaches.vectorCacheURL(), now: Date = Date()
    ) throws -> Bool {
        let fingerprint = space.fingerprint
        let installedAt = ISO8601DateFormatter().string(from: now)
        let didReset = try writer.write { db -> Bool in
            let stored = try String.fetchOne(
                db, sql: "SELECT fingerprint FROM discovery_embedding_space WHERE singleton = 1")
            if stored == fingerprint { return false }
            try db.execute(sql: "DELETE FROM discovery_window_checkpoint")
            try db.execute(sql: "DELETE FROM discovery_index_job")
            try db.execute(sql: "DELETE FROM discovery_embedding")
            try db.execute(sql: "DELETE FROM discovery_track_analysis")
            try db.execute(sql: "DELETE FROM discovery_transition_profile")
            try db.execute(sql: "DELETE FROM discovery_embedding_space")
            try db.execute(
                sql: "INSERT INTO discovery_embedding_space(singleton, fingerprint, installedAt) VALUES (1, ?, ?)",
                arguments: [fingerprint, installedAt])
            return true
        }
        if didReset { try? FileManager.default.removeItem(at: cacheURL) }
        return didReset
    }
}
#endif
