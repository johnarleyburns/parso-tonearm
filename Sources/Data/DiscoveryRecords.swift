import Foundation
import GRDB

// Unified-library CLAP indexing/search persistence (IMPLEMENT_CLAP_PLAN.md §4).
// These types live in TonearmCore alongside `Records.swift` because they are
// core-schema tables (foreign keys to `track`/`asset`), even though the
// algorithms that populate/consume them live in the `TonearmDiscovery`
// package target added alongside this file. TonearmCore itself has no
// dependency on TonearmDiscovery — these are plain persistence DTOs.

/// One-active-logical-job-per-(track, pipelineVersion) state machine (plan §4).
public enum DiscoveryJobState: String, Codable, Sendable, CaseIterable {
    case queued
    case running
    case waitingForModel
    case waitingForAsset
    case waitingForNetwork
    case waitingForPower
    case waitingForCooling
    case retryScheduled
    case failed
    case complete
    case unsupported
}

/// Per-stage state within a job: embedding and musical-analysis are tracked
/// independently so embedding coverage never depends on musical-analysis
/// success (plan §4/§6).
public enum DiscoveryStageState: String, Codable, Sendable, CaseIterable {
    case pending
    case running
    case complete
    case failed
    case unsupported
}

public enum DiscoveryImportJobState: String, Codable, Sendable, CaseIterable {
    case queued
    case running
    case waitingForNetwork
    case paused
    case complete
    case failed
    case cancelled
}

public enum DiscoveryImportItemState: String, Codable, Sendable, CaseIterable {
    case pending
    case imported
    case failed
    case skipped
}

/// Tracks whether the currently-selected analyzable asset for a track has
/// changed content since it was last analyzed. Cache path/last-access
/// changes alone are NOT content revisions (plan §4).
public struct DiscoveryAssetState: Codable, Equatable, Sendable, FetchableRecord,
    MutablePersistableRecord
{
    public static let databaseTableName = "discovery_asset_state"

    public var assetId: Int64
    public var contentRevision: Int64
    public var observedSizeBytes: Int64?
    public var observedMTime: Date?
    public var observedProviderValidator: String?
    public var canonicalRevisionSignature: String?
    public var lastValidatedAt: Date

    public init(
        assetId: Int64,
        contentRevision: Int64 = 1,
        observedSizeBytes: Int64? = nil,
        observedMTime: Date? = nil,
        observedProviderValidator: String? = nil,
        canonicalRevisionSignature: String? = nil,
        lastValidatedAt: Date
    ) {
        self.assetId = assetId
        self.contentRevision = contentRevision
        self.observedSizeBytes = observedSizeBytes
        self.observedMTime = observedMTime
        self.observedProviderValidator = observedProviderValidator
        self.canonicalRevisionSignature = canonicalRevisionSignature
        self.lastValidatedAt = lastValidatedAt
    }
}

/// Musical BPM/key/energy analysis, checkpointed separately from embeddings
/// (plan §6). Unknown values stay NULL rather than a guessed default.
public struct DiscoveryTrackAnalysis: Codable, Equatable, Sendable, FetchableRecord,
    MutablePersistableRecord
{
    public static let databaseTableName = "discovery_track_analysis"

    public var trackId: Int64
    public var assetId: Int64
    public var assetRevision: Int64
    public var analysisVersion: Int
    public var bpm: Double?
    public var key: String?
    public var energy: Double?
    public var phraseSummary: String?
    public var analysisScopeSeconds: Double?
    public var completedAt: Date?

    public init(
        trackId: Int64,
        assetId: Int64,
        assetRevision: Int64,
        analysisVersion: Int,
        bpm: Double? = nil,
        key: String? = nil,
        energy: Double? = nil,
        phraseSummary: String? = nil,
        analysisScopeSeconds: Double? = nil,
        completedAt: Date? = nil
    ) {
        self.trackId = trackId
        self.assetId = assetId
        self.assetRevision = assetRevision
        self.analysisVersion = analysisVersion
        self.bpm = bpm
        self.key = key
        self.energy = energy
        self.phraseSummary = phraseSummary
        self.analysisScopeSeconds = analysisScopeSeconds
        self.completedAt = completedAt
    }
}

/// The quantized CLAP audio embedding for a track's selected asset revision.
/// Authoritative store; the mmap/vector cache (VectorIndex, C06/§8) is
/// rebuildable from these rows and is never a second source of truth.
public struct DiscoveryEmbedding: Codable, Equatable, Sendable, FetchableRecord,
    MutablePersistableRecord
{
    public static let databaseTableName = "discovery_embedding"

    public var trackId: Int64
    public var assetId: Int64
    public var assetRevision: Int64
    public var modelVersion: Int
    public var preprocessingVersion: Int
    public var samplingVersion: Int
    public var dimensions: Int
    public var quantizedVector: Data
    public var scale: Double
    public var completedAt: Date

    public init(
        trackId: Int64,
        assetId: Int64,
        assetRevision: Int64,
        modelVersion: Int,
        preprocessingVersion: Int,
        samplingVersion: Int,
        dimensions: Int,
        quantizedVector: Data,
        scale: Double,
        completedAt: Date
    ) {
        self.trackId = trackId
        self.assetId = assetId
        self.assetRevision = assetRevision
        self.modelVersion = modelVersion
        self.preprocessingVersion = preprocessingVersion
        self.samplingVersion = samplingVersion
        self.dimensions = dimensions
        self.quantizedVector = quantizedVector
        self.scale = scale
        self.completedAt = completedAt
    }
}

/// One logical indexing job per (track, pipelineVersion). Restarted, not
/// duplicated, when the selected asset's content revision changes.
public struct DiscoveryIndexJob: Codable, Equatable, Sendable, Identifiable, FetchableRecord,
    MutablePersistableRecord
{
    public static let databaseTableName = "discovery_index_job"

    public var id: String
    public var trackId: Int64
    public var selectedAssetId: Int64?
    public var assetRevision: Int64?
    public var pipelineVersion: Int
    public var state: DiscoveryJobState
    public var priority: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var nextAttemptAt: Date?
    public var attemptCount: Int
    public var leaseToken: String?
    public var leaseExpiresAt: Date?
    public var completedWindows: Int
    public var totalWindows: Int
    public var embeddingStageState: DiscoveryStageState
    public var musicalAnalysisStageState: DiscoveryStageState
    public var errorCode: String?
    public var errorMessage: String?

    public init(
        id: String = UUID().uuidString,
        trackId: Int64,
        selectedAssetId: Int64? = nil,
        assetRevision: Int64? = nil,
        pipelineVersion: Int,
        state: DiscoveryJobState = .queued,
        priority: Int = 0,
        createdAt: Date,
        updatedAt: Date,
        nextAttemptAt: Date? = nil,
        attemptCount: Int = 0,
        leaseToken: String? = nil,
        leaseExpiresAt: Date? = nil,
        completedWindows: Int = 0,
        totalWindows: Int = 0,
        embeddingStageState: DiscoveryStageState = .pending,
        musicalAnalysisStageState: DiscoveryStageState = .pending,
        errorCode: String? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.trackId = trackId
        self.selectedAssetId = selectedAssetId
        self.assetRevision = assetRevision
        self.pipelineVersion = pipelineVersion
        self.state = state
        self.priority = priority
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.nextAttemptAt = nextAttemptAt
        self.attemptCount = attemptCount
        self.leaseToken = leaseToken
        self.leaseExpiresAt = leaseExpiresAt
        self.completedWindows = completedWindows
        self.totalWindows = totalWindows
        self.embeddingStageState = embeddingStageState
        self.musicalAnalysisStageState = musicalAnalysisStageState
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }

    /// A job is complete when BOTH stages are terminal (plan §4/§6): a
    /// terminal state is `complete`, `failed` or `unsupported`. Terminal
    /// failures stay separately counted (see `IndexJobRepository.Coverage`)
    /// and manually retryable; they do not keep the job forever runnable
    /// (which would spin `IndexScheduler.tick`). Embedding-derived search
    /// coverage still counts only a `complete` embedding stage, independently
    /// of the musical stage's outcome.
    public var isComplete: Bool {
        Self.isTerminal(embeddingStageState) && Self.isTerminal(musicalAnalysisStageState)
    }

    private static func isTerminal(_ state: DiscoveryStageState) -> Bool {
        state == .complete || state == .failed || state == .unsupported
    }
}

/// Durable intermediate per-window embedding — resumable after relaunch.
/// Not searchable partial-track output (plan §4/§6).
public struct DiscoveryWindowCheckpoint: Codable, Equatable, Sendable, FetchableRecord,
    MutablePersistableRecord
{
    public static let databaseTableName = "discovery_window_checkpoint"

    public var id: Int64?
    public var jobId: String
    public var revisionSignature: String
    public var windowIndex: Int
    public var startSeconds: Double
    public var embeddingVector: Data
    public var poolingWeight: Double
    public var completedAt: Date

    public init(
        id: Int64? = nil,
        jobId: String,
        revisionSignature: String,
        windowIndex: Int,
        startSeconds: Double,
        embeddingVector: Data,
        poolingWeight: Double,
        completedAt: Date
    ) {
        self.id = id
        self.jobId = jobId
        self.revisionSignature = revisionSignature
        self.windowIndex = windowIndex
        self.startSeconds = startSeconds
        self.embeddingVector = embeddingVector
        self.poolingWeight = poolingWeight
        self.completedAt = completedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public enum DiscoveryChangeKind: String, Codable, Sendable {
    case trackInserted
    case trackMetadataUpdated
    case trackDeleted
    case assetContentReplaced
    case sourceDeleted
}

/// Durable transactional outbox: written atomically alongside core catalog
/// mutations so the reconciler can wake without polling (plan §4).
public struct DiscoveryChange: Codable, Equatable, Sendable, FetchableRecord,
    MutablePersistableRecord
{
    public static let databaseTableName = "discovery_change"

    public var id: Int64?
    public var trackId: Int64?
    public var kind: DiscoveryChangeKind
    public var createdAt: Date

    public init(id: Int64? = nil, trackId: Int64?, kind: DiscoveryChangeKind, createdAt: Date) {
        self.id = id
        self.trackId = trackId
        self.kind = kind
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Global scheduling gate/preferences: pause is one row, not a per-track
/// mutation (plan §4/§6).
public struct DiscoverySetting: Codable, Equatable, Sendable, FetchableRecord,
    MutablePersistableRecord
{
    public static let databaseTableName = "discovery_setting"

    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }

    public enum Key {
        public static let paused = "discovery.paused"
        public static let modelDownloadConsent = "discovery.modelDownloadConsent"
        public static let chargingOnly = "discovery.chargingOnly"
    }
}

/// One durable, resumable import job per source enumeration (plan §5).
public struct DiscoveryImportJob: Codable, Equatable, Sendable, Identifiable, FetchableRecord,
    MutablePersistableRecord
{
    public static let databaseTableName = "discovery_import_job"

    public var id: String
    public var sourceId: Int64?
    public var sourceKind: String
    public var resumeLocator: Data?
    public var state: DiscoveryImportJobState
    public var providerCursor: String?
    public var discoveredCount: Int
    public var importedCount: Int
    public var failedCount: Int
    public var enumerationComplete: Bool
    public var lastError: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        sourceId: Int64?,
        sourceKind: String,
        resumeLocator: Data? = nil,
        state: DiscoveryImportJobState = .queued,
        providerCursor: String? = nil,
        discoveredCount: Int = 0,
        importedCount: Int = 0,
        failedCount: Int = 0,
        enumerationComplete: Bool = false,
        lastError: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.sourceId = sourceId
        self.sourceKind = sourceKind
        self.resumeLocator = resumeLocator
        self.state = state
        self.providerCursor = providerCursor
        self.discoveredCount = discoveredCount
        self.importedCount = importedCount
        self.failedCount = failedCount
        self.enumerationComplete = enumerationComplete
        self.lastError = lastError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// unique(jobId, identity) so replaying an enumeration cannot duplicate a
/// track (plan §4/§5).
public struct DiscoveryImportItem: Codable, Equatable, Sendable, FetchableRecord,
    MutablePersistableRecord
{
    public static let databaseTableName = "discovery_import_item"

    public var id: Int64?
    public var jobId: String
    public var itemIdentity: String
    public var state: DiscoveryImportItemState
    public var resultingTrackId: Int64?
    public var error: String?

    public init(
        id: Int64? = nil,
        jobId: String,
        itemIdentity: String,
        state: DiscoveryImportItemState = .pending,
        resultingTrackId: Int64? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.jobId = jobId
        self.itemIdentity = itemIdentity
        self.state = state
        self.resultingTrackId = resultingTrackId
        self.error = error
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Singleton telemetry row — NOT the authoritative queue (plan §4).
public struct DiscoveryRuntime: Codable, Equatable, Sendable, FetchableRecord,
    MutablePersistableRecord
{
    public static let databaseTableName = "discovery_runtime"

    public var id: Int64
    public var lastRunAt: Date?
    public var lastStartAt: Date?
    public var lastStopAt: Date?
    public var lastStopReason: String?
    public var lastBackgroundSubmissionResult: String?
    public var lastBackgroundSubmissionAt: Date?
    public var lastSuccessfulWorkAt: Date?
    /// Last coded error observed by the background/foreground drain (nil once
    /// a subsequent run succeeds). Added in migration v20.
    public var lastError: String?
    /// Compact coverage string captured at the end of the last run, e.g.
    /// "238 / 1042". Added in migration v20.
    public var coverageSnapshot: String?
    /// `earliestBeginDate` of the most recently submitted BGProcessingTask
    /// request. Added in migration v20.
    public var nextScheduledAt: Date?

    public init(
        id: Int64 = 1,
        lastRunAt: Date? = nil,
        lastStartAt: Date? = nil,
        lastStopAt: Date? = nil,
        lastStopReason: String? = nil,
        lastBackgroundSubmissionResult: String? = nil,
        lastBackgroundSubmissionAt: Date? = nil,
        lastSuccessfulWorkAt: Date? = nil,
        lastError: String? = nil,
        coverageSnapshot: String? = nil,
        nextScheduledAt: Date? = nil
    ) {
        self.id = id
        self.lastRunAt = lastRunAt
        self.lastStartAt = lastStartAt
        self.lastStopAt = lastStopAt
        self.lastStopReason = lastStopReason
        self.lastBackgroundSubmissionResult = lastBackgroundSubmissionResult
        self.lastBackgroundSubmissionAt = lastBackgroundSubmissionAt
        self.lastSuccessfulWorkAt = lastSuccessfulWorkAt
        self.lastError = lastError
        self.coverageSnapshot = coverageSnapshot
        self.nextScheduledAt = nextScheduledAt
    }
}
