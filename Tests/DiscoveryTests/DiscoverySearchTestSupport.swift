#if !os(watchOS)
import Foundation
import GRDB
import ParsoAudioNeural
import XCTest

@testable import TonearmCore
@testable import TonearmDiscovery

/// Shared fixtures for the C06 retrieval tests. Embeddings are real
/// pipeline-quantized vectors (`VectorQuantization.quantize` — the exact path
/// `BoundedIndexWorker` uses); analysis rows carry real numeric attributes.
enum SearchFixture {
    static func makeQueue() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue()
        try Schema.migrator().migrate(queue)
        return queue
    }

    @discardableResult
    static func seedSource(_ db: Database, title: String = "Music") throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO source (kind, title, addedAt, followUpdates, memberCapHit, localIsFolder)
                VALUES ('local', ?, ?, 0, 0, 1)
                """,
            arguments: [title, Date()])
        return db.lastInsertedRowID
    }

    @discardableResult
    static func seedTrack(
        _ db: Database, sourceId: Int64, title: String, sortKey: String? = nil,
        durationSec: Double? = 200
    ) throws -> Int64 {
        var track = Track(
            id: nil, albumId: nil, sourceId: sourceId, title: title, trackNo: nil, discNo: nil,
            durationSec: durationSec, codec: "wav", sampleRate: 44_100, bitDepthOrBitrate: nil,
            sortKey: sortKey ?? title.lowercased())
        try track.insert(db)
        return track.id!
    }

    @discardableResult
    static func seedAsset(_ db: Database, trackId: Int64) throws -> Int64 {
        var asset = Asset(
            id: nil, trackId: trackId, kind: .localRef, bookmark: nil, relPath: "x/\(trackId).wav",
            remoteURL: nil, altRemoteURL: nil, sizeBytes: 1, unsupportedReason: nil)
        try asset.insert(db)
        return asset.id!
    }

    /// Seed a real quantized embedding row for `trackId` from an arbitrary
    /// vector (L2-normalized then int8-quantized, exactly as the worker does).
    static func seedEmbedding(
        _ db: Database, trackId: Int64, assetId: Int64, vector: [Float],
        modelVersion: Int = DiscoveryPipelineVersion.model,
        preprocessingVersion: Int = DiscoveryPipelineVersion.preprocessing,
        samplingVersion: Int = DiscoveryPipelineVersion.sampling,
        completedAt: Date = Date()
    ) throws {
        let unit = SemanticPooling.l2Normalized(vector)
        let (int8, scale) = VectorQuantization.quantize(unit)
        var row = DiscoveryEmbedding(
            trackId: trackId, assetId: assetId, assetRevision: 1, modelVersion: modelVersion,
            preprocessingVersion: preprocessingVersion, samplingVersion: samplingVersion,
            dimensions: unit.count, quantizedVector: VectorQuantization.data(int8),
            scale: Double(scale), completedAt: completedAt)
        try row.upsert(db)
    }

    static func seedAnalysis(
        _ db: Database, trackId: Int64, assetId: Int64, bpm: Double? = nil, key: String? = nil,
        energy: Double? = nil
    ) throws {
        var row = DiscoveryTrackAnalysis(
            trackId: trackId, assetId: assetId, assetRevision: 1,
            analysisVersion: DiscoveryPipelineVersion.musicalAnalysis, bpm: bpm, key: key,
            energy: energy, phraseSummary: nil, analysisScopeSeconds: 60, completedAt: Date())
        try row.upsert(db)
    }

    static func seedJob(
        _ db: Database, trackId: Int64, state: DiscoveryJobState,
        embedding: DiscoveryStageState = .pending
    ) throws {
        var job = DiscoveryIndexJob(
            trackId: trackId, pipelineVersion: DiscoveryPipelineVersion.pipeline, state: state,
            createdAt: Date(), updatedAt: Date(), embeddingStageState: embedding,
            musicalAnalysisStageState: .pending)
        try job.insert(db)
    }
}

/// A `SemanticModel` that returns one fixed L2-normalized vector for any text
/// — lets a test drive `SearchService`'s semantic path with an exact query
/// vector. `embedAudio` is unused by search.
struct FixedTextModel: SemanticModel {
    let spec: EmbeddingModelSpec
    let vector: [Float]

    init(dimensions: Int, vector: [Float]) {
        precondition(vector.count == dimensions)
        var spec = EmbeddingModelSpec.musicCLAPMetadata
        spec.dimensions = dimensions
        self.spec = spec
        self.vector = SemanticPooling.l2Normalized(vector)
    }

    func embedText(_ text: String) async throws -> [Float] { vector }
    func embedAudio(logMel: [Float]) async throws -> [Float] { vector }
}

/// Deletes one track exactly once, on the first call — a `SearchService`
/// scan-block hook that simulates a catalog mutation landing during a single
/// in-flight scan (C06 "source / track deletion mid-query").
actor DeleteOnce {
    private let queue: DatabaseQueue
    private let trackID: Int64
    private(set) var didRun = false

    init(queue: DatabaseQueue, trackID: Int64) {
        self.queue = queue
        self.trackID = trackID
    }

    func run() async {
        guard !didRun else { return }
        didRun = true
        try? await queue.write { [trackID] db in
            try db.execute(sql: "DELETE FROM track WHERE id = ?", arguments: [trackID])
        }
    }
}
#endif
