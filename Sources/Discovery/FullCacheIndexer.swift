#if !os(watchOS)
import Foundation
import GRDB
import ParsoAudioNeural
import TonearmCore

/// Why an index request is allowed to touch audio bytes. Only
/// `.remoteFullCacheAndProfile` may request a full remote asset, and only after an explicit
/// user action that disclosed the download; sparse remote work stays range-based.
public enum DiscoveryIndexIntent: String, Codable, Sendable {
    case localFile
    case remoteSparseEmbedding
    case remoteFullCacheAndProfile
}

public enum DiscoveryNetworkClass: Sendable { case wifi, cellular, offline }

/// Full-asset download into the existing managed `AudioCache` (retained/evicted by normal
/// cache policy). Conformers must honour cancellation and surface disk-full as an error.
public protocol ManagedAudioCaching: Sendable {
    func downloadAndRetain(asset: Asset) async throws -> URL
}

public struct DiscoveryAnalysisOutput: Sendable {
    public var embedding: [Float]
    public var bpm: Double?
    public var key: String?
    public var energy: Double?
    public var profile: TransitionProfile?
    public init(embedding: [Float], bpm: Double? = nil, key: String? = nil, energy: Double? = nil,
                profile: TransitionProfile? = nil) {
        self.embedding = embedding; self.bpm = bpm; self.key = key; self.energy = energy
        self.profile = profile
    }
}

public protocol DiscoveryAudioAnalyzing: Sendable {
    func analyze(url: URL, wantsTransitionProfile: Bool) async throws -> DiscoveryAnalysisOutput
}

public enum DiscoveryIndexError: Error, Equatable, Sendable {
    case wrongIntentForAsset
    case networkPolicyBlocked
    case staleAssetRevision
    case staleEmbeddingSpace
    case invalidOutput
    case assetUnavailable
}

/// Source-revision-safe persistence for embedding + analysis + TransitionProfile, plus the
/// explicit "remove derived index" action. Cache eviction never calls into this type.
public struct DiscoveryDerivedStore: Sendable {
    private let writer: any DatabaseWriter
    public init(writer: any DatabaseWriter) { self.writer = writer }

    /// The asset's current content revision (`discovery_asset_state`, default 1).
    public static func currentRevision(_ db: Database, assetId: Int64) throws -> Int64 {
        try Int64.fetchOne(
            db, sql: "SELECT contentRevision FROM discovery_asset_state WHERE assetId = ?",
            arguments: [assetId]) ?? 1
    }

    /// Commits `output` only if, inside this transaction, the asset still exists at
    /// `expectedRevision` and the installed embedding space equals `expectedFingerprint`.
    public func persistIfCurrent(
        _ output: DiscoveryAnalysisOutput, trackId: Int64, assetId: Int64, expectedRevision: Int64,
        expectedFingerprint: String, now: Date = Date()
    ) throws {
        guard output.embedding.count == EmbeddingSpace.current.dimensions,
            output.embedding.allSatisfy({ $0.isFinite })
        else { throw DiscoveryIndexError.invalidOutput }
        let payload = try output.profile?.encoded()
        let (int8, scale) = VectorQuantization.quantize(output.embedding)
        try writer.write { db in
            guard try Asset.fetchOne(db, key: assetId)?.trackId == trackId else {
                throw DiscoveryIndexError.staleAssetRevision
            }
            guard try Self.currentRevision(db, assetId: assetId) == expectedRevision else {
                throw DiscoveryIndexError.staleAssetRevision
            }
            let installed = try String.fetchOne(
                db, sql: "SELECT fingerprint FROM discovery_embedding_space WHERE singleton = 1")
            guard installed == expectedFingerprint else { throw DiscoveryIndexError.staleEmbeddingSpace }

            var embedding = DiscoveryEmbedding(
                trackId: trackId, assetId: assetId, assetRevision: expectedRevision,
                modelVersion: DiscoveryPipelineVersion.model,
                preprocessingVersion: DiscoveryPipelineVersion.preprocessing,
                samplingVersion: DiscoveryPipelineVersion.sampling,
                dimensions: output.embedding.count, quantizedVector: VectorQuantization.data(int8),
                scale: Double(scale), completedAt: now)
            try embedding.upsert(db)
            var analysis = DiscoveryTrackAnalysis(
                trackId: trackId, assetId: assetId, assetRevision: expectedRevision,
                analysisVersion: DiscoveryPipelineVersion.musicalAnalysis, bpm: output.bpm,
                key: output.key, energy: output.energy, phraseSummary: nil,
                analysisScopeSeconds: nil, completedAt: now)
            try analysis.upsert(db)
            guard let payload else { return }
            // One profile per asset revision: drop rows from older revisions/spaces.
            try db.execute(
                sql: """
                    DELETE FROM discovery_transition_profile WHERE trackId = ?
                      AND NOT (assetId = ? AND assetRevision = ? AND embeddingSpaceFingerprint = ?)
                    """,
                arguments: [trackId, assetId, expectedRevision, expectedFingerprint])
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO discovery_transition_profile
                    (trackId, assetId, assetRevision, embeddingSpaceFingerprint, profileVersion, payload, completedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [trackId, assetId, expectedRevision, expectedFingerprint,
                            TransitionProfile.currentVersion, payload,
                            ISO8601DateFormatter().string(from: now)])
        }
    }

    /// The stored profile for the track, only if it matches the asset's current revision and
    /// the given embedding-space fingerprint.
    public func currentProfile(trackId: Int64, fingerprint: String) throws -> TransitionProfile? {
        try writer.read { db in
            guard let assetId = try Int64.fetchOne(
                db, sql: "SELECT assetId FROM discovery_transition_profile WHERE trackId = ? AND embeddingSpaceFingerprint = ?",
                arguments: [trackId, fingerprint]) else { return nil }
            let revision = try Self.currentRevision(db, assetId: assetId)
            guard let data = try Data.fetchOne(
                db, sql: """
                    SELECT payload FROM discovery_transition_profile
                    WHERE trackId = ? AND assetId = ? AND assetRevision = ? AND embeddingSpaceFingerprint = ?
                    """, arguments: [trackId, assetId, revision, fingerprint]) else { return nil }
            return try? TransitionProfile.decode(data)
        }
    }

    /// Tracks whose embedding or profile no longer matches the current asset revision.
    public func staleTrackIds() throws -> [Int64] {
        try writer.read { db in
            try Int64.fetchAll(
                db, sql: """
                    SELECT e.trackId FROM discovery_embedding e
                    LEFT JOIN discovery_asset_state s ON s.assetId = e.assetId
                    WHERE e.assetRevision != COALESCE(s.contentRevision, 1)
                    UNION
                    SELECT p.trackId FROM discovery_transition_profile p
                    LEFT JOIN discovery_asset_state s ON s.assetId = p.assetId
                    WHERE p.assetRevision != COALESCE(s.contentRevision, 1)
                    """)
        }
    }

    /// Explicit "remove downloaded audio and derived index": deletes only this track's derived
    /// rows. Library rows (track/asset/playlists) are untouched; the caller removes the bytes.
    public func removeDerived(trackId: Int64) throws {
        try writer.write { db in
            for table in ["discovery_embedding", "discovery_track_analysis", "discovery_transition_profile"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE trackId = ?", arguments: [trackId])
            }
        }
    }
}

/// Runs one index request per intent. Intent separation is the privacy boundary: the managed
/// cache is only ever asked for a full download under `.remoteFullCacheAndProfile`.
public struct IntentIndexRunner: Sendable {
    private let writer: any DatabaseWriter
    private let store: DiscoveryDerivedStore
    private let analyzer: any DiscoveryAudioAnalyzing
    private let cache: any ManagedAudioCaching
    private let resolveLocal: @Sendable (Asset) throws -> URL
    private let boundedAnalysisURL: @Sendable (Asset) async throws -> URL
    private let network: @Sendable () -> DiscoveryNetworkClass
    private let wifiOnly: @Sendable () -> Bool
    private let fingerprint: String

    public init(
        writer: any DatabaseWriter, analyzer: any DiscoveryAudioAnalyzing,
        cache: any ManagedAudioCaching,
        resolveLocal: @escaping @Sendable (Asset) throws -> URL,
        boundedAnalysisURL: @escaping @Sendable (Asset) async throws -> URL,
        network: @escaping @Sendable () -> DiscoveryNetworkClass,
        wifiOnly: @escaping @Sendable () -> Bool,
        fingerprint: String = EmbeddingSpace.current.fingerprint
    ) {
        self.writer = writer
        self.store = DiscoveryDerivedStore(writer: writer)
        self.analyzer = analyzer
        self.cache = cache
        self.resolveLocal = resolveLocal
        self.boundedAnalysisURL = boundedAnalysisURL
        self.network = network
        self.wifiOnly = wifiOnly
        self.fingerprint = fingerprint
    }

    public func run(intent: DiscoveryIndexIntent, trackId: Int64, assetId: Int64) async throws {
        let (asset, revision) = try await writer.read { db -> (Asset?, Int64) in
            (try Asset.fetchOne(db, key: assetId), try DiscoveryDerivedStore.currentRevision(db, assetId: assetId))
        }
        guard let asset, asset.trackId == trackId else { throw DiscoveryIndexError.assetUnavailable }
        try Task.checkCancellation()

        let audioURL: URL
        switch intent {
        case .localFile:
            guard asset.kind != .remote else { throw DiscoveryIndexError.wrongIntentForAsset }
            audioURL = try resolveLocal(asset)
        case .remoteSparseEmbedding:
            guard asset.kind == .remote else { throw DiscoveryIndexError.wrongIntentForAsset }
            audioURL = try await boundedAnalysisURL(asset)
        case .remoteFullCacheAndProfile:
            guard asset.kind == .remote else { throw DiscoveryIndexError.wrongIntentForAsset }
            let current = network()
            if current == .offline || (wifiOnly() && current != .wifi) {
                throw DiscoveryIndexError.networkPolicyBlocked
            }
            audioURL = try await cache.downloadAndRetain(asset: asset)
            try Task.checkCancellation()
        }
        let output = try await analyzer.analyze(
            url: audioURL, wantsTransitionProfile: intent != .remoteSparseEmbedding)
        try Task.checkCancellation()
        try store.persistIfCurrent(
            output, trackId: trackId, assetId: assetId, expectedRevision: revision,
            expectedFingerprint: fingerprint)
    }
}
#endif
