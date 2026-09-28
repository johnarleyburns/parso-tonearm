import Foundation

#if !os(watchOS)
import CloudKit
import os

/// Wraps `CKSyncEngine` against the **private** database in container
/// `iCloud.guru.parso.tonearm` (C3). This is the networked integration layer;
/// all DB↔record mapping and merge/gating decisions live in the pure, unit-tested
/// `RecordMapping`, `SyncMerge`, and `SyncGating` helpers.
///
/// Only starts when the toggle is on **and** an iCloud account is
/// available (`SyncGating.shouldRun`). On toggle-off it stops without
/// deleting local data. iCloud sync is free for all users.
/// Real counts from the most recent pull pass — CLAUDE.md "no silent/magic
/// background work" extended to discovery-index sync: a user should be able
/// to see how many tracks arrived from another device and how many were
/// rejected (and why), not just a generic "syncing" spinner.
public struct DiscoverySyncActivity: Equatable, Sendable {
    public private(set) var accepted = 0
    public private(set) var rejectedKeepLocal = 0
    public private(set) var rejectedRequeued = 0
    public private(set) var pendingTrackImport = 0
    public private(set) var pendingOldestDate: Date?
    public private(set) var prunedPendingCount = 0

    public init() {}

    mutating func record(_ result: LibraryStore.IncomingDiscoveryEmbeddingResult) {
        switch result {
        case .accepted: accepted += 1
        case .rejectedKeepLocal: rejectedKeepLocal += 1
        case .rejectedRequeued: rejectedRequeued += 1
        case .trackNotYetImported: pendingTrackImport += 1
        }
    }

    mutating func setPendingCount(_ count: Int, oldest: Date? = nil, pruned: Int = 0) {
        pendingTrackImport = count
        pendingOldestDate = oldest
        prunedPendingCount = pruned
    }
}

@available(iOS 17.0, *)
@MainActor
public final class CloudSyncEngine: NSObject, ObservableObject {
    public static let shared = CloudSyncEngine()

    public nonisolated static let containerID = "iCloud.guru.parso.tonearm"
    private static let zoneName = "TonearmLibrary"
    private static let stateKey = "sync.icloud.engineState"

    private let log = Logger(subsystem: "guru.parso.tonearm", category: "CloudSync")
    private let container: CKContainer
    private let zoneID: CKRecordZone.ID
    private var engine: CKSyncEngine?
    private let store: LibraryStore

    public private(set) var lastHint: String?

    /// docs/plans/macos-app-cloud-sync-plan.md §4 status surface (CLAUDE.md
    /// "no silent/magic background work") — real counts from the most
    /// recent pull pass, never fabricated. Reset at the start of each
    /// `applyFetched` call so a stale count from an old pass never lingers.
    @Published public private(set) var lastSyncActivity = DiscoverySyncActivity()

    /// This device's own currently-active pipeline versions, supplied by
    /// the iOS adapter layer (`DiscoveryPipelineVersion` lives in the
    /// `TonearmDiscovery` product, which this file's target does not
    /// depend on — see `LibraryStore+DiscoverySync.swift`'s matching doc).
    /// `nil` until the discovery runtime has actually started, in which
    /// case incoming discovery-embedding records are left pending rather
    /// than guessed against.
    public var activePipelineVersionsProvider: (@Sendable () -> ActivePipelineVersions?)?

    /// The DJ surface installs this lightweight invalidation hook so a prep
    /// record arriving from another device updates a deck that is already on
    /// screen without requiring the user to leave and re-enter DJ.
    public var onDJTrackPrepApplied: (@MainActor @Sendable (Int64) -> Void)?

    public struct ActivePipelineVersions: Sendable {
        public let pipeline: Int
        public let model: Int
        public let preprocessing: Int
        public let sampling: Int
        public let musicalAnalysis: Int
        public init(pipeline: Int, model: Int, preprocessing: Int, sampling: Int, musicalAnalysis: Int) {
            self.pipeline = pipeline
            self.model = model
            self.preprocessing = preprocessing
            self.sampling = sampling
            self.musicalAnalysis = musicalAnalysis
        }
    }

    public init(store: LibraryStore = .shared) {
        self.container = CKContainer(identifier: Self.containerID)
        self.zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
        self.store = store
        super.init()
    }

    // MARK: - Lifecycle & gating (C5)

    /// Starts or stops the engine to match current gating. Safe to call on
    /// launch, on foreground, and whenever the toggle changes.
    public func reconcile() async {
        let account = await accountStatus()
        let toggle = SyncGating.isEnabled
        lastHint = SyncGating.inactiveHint(toggleOn: toggle, account: account)

        guard SyncGating.shouldRun(toggleOn: toggle, account: account) else {
            stop()
            return
        }
        if engine == nil { startEngine() }
        await syncNow()
    }

    private func startEngine() {
        var config = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: loadState(),
            delegate: self)
        config.automaticallySync = true
        engine = CKSyncEngine(config)
        log.info("CKSyncEngine started")
    }

    /// Stops the engine, leaving local data intact (C5 — never bulk-delete).
    public func stop() {
        engine = nil
    }

    /// Triggers a fetch + send pass (launch / foreground / manual).
    public func syncNow() async {
        guard let engine else { return }
        do {
            try await engine.fetchChanges()
            try await engine.sendChanges()
        } catch {
            log.error("sync pass failed: \(error.localizedDescription)")
        }
    }

    /// Enqueues local writes for the engine to push (called after DB mutations).
    public func enqueue(recordIDs: [CKRecord.ID]) {
        engine?.state.add(pendingRecordZoneChanges: recordIDs.map { .saveRecord($0) })
    }

    /// Push half of plan §4.4 — called when local indexing completes a
    /// track (`BoundedIndexWorker`'s completion path, wired through
    /// `DiscoveryAssembly`'s injected `onEmbeddingCompleted` closure, the
    /// same cross-module-boundary pattern `executionContext`/
    /// `modelResourceProvider` already use). Ensures a real, persisted
    /// `syncID` exists first (`LibraryStore+DiscoverySync.swift`) — the
    /// engine can only enqueue a `CKRecord.ID`, which is itself derived
    /// from that `syncID`.
    public func enqueueDiscoveryResults(trackId: Int64) async {
        var ids: [CKRecord.ID] = []
        if let embeddingSyncID = try? await store.ensureDiscoveryEmbeddingSyncID(trackId: trackId) {
            ids.append(RecordMapping.recordID(type: .discoveryEmbedding, syncID: embeddingSyncID, zoneID: zoneID))
        }
        if let analysisSyncID = try? await store.ensureDiscoveryTrackAnalysisSyncID(trackId: trackId) {
            ids.append(RecordMapping.recordID(type: .discoveryTrackAnalysis, syncID: analysisSyncID, zoneID: zoneID))
        }
        guard !ids.isEmpty else { return }
        enqueue(recordIDs: ids)
    }

    public func enqueueDJTrackPrep(trackId: Int64) async {
        guard let syncID = try? await store.ensureDJTrackPrepSyncID(trackId: trackId) else { return }
        enqueue(recordIDs: [RecordMapping.recordID(type: .djTrackPrep, syncID: syncID, zoneID: zoneID)])
    }

    private func accountStatus() async -> SyncGating.AccountStatus {
        do {
            switch try await container.accountStatus() {
            case .available: return .available
            case .noAccount: return .noAccount
            case .restricted: return .restricted
            case .temporarilyUnavailable: return .temporarilyUnavailable
            default: return .couldNotDetermine
            }
        } catch {
            return .couldNotDetermine
        }
    }

    // MARK: - Engine state persistence

    private func loadState() -> CKSyncEngine.State.Serialization? {
        guard let data = UserDefaults.standard.data(forKey: Self.stateKey) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func saveState(_ state: CKSyncEngine.State.Serialization) {
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.stateKey)
        }
    }
}

// MARK: - CKSyncEngineDelegate

@available(iOS 17.0, *)
extension CloudSyncEngine: CKSyncEngineDelegate {
    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            saveState(update.stateSerialization)
        case .fetchedRecordZoneChanges(let changes):
            await applyFetched(changes)
        case .sentRecordZoneChanges:
            break
        default:
            break
        }
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        // CKSyncEngine.RecordZoneChangeBatch's per-record closure is
        // synchronous, but resolving a record needs an `await` into the
        // actor-isolated LibraryStore — resolve everything up front into a
        // plain dictionary the closure can look up synchronously.
        var resolving: [CKRecord.ID: CKRecord] = [:]
        for change in pending {
            guard case .saveRecord(let recordID) = change else { continue }
            if let record = await buildRecord(for: recordID) { resolving[recordID] = record }
        }
        let resolved = resolving
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            resolved[recordID] ?? CKRecord(recordType: "Placeholder", recordID: recordID)
        }
    }

    /// Builds the real `CKRecord` for a pending local change from the
    /// current DB row via `RecordMapping`, for the two record types this
    /// session wired end-to-end (docs/plans/macos-app-cloud-sync-plan.md
    /// §4.4 — the push half of syncing indexing outcomes).
    ///
    /// The other 9 pre-existing record types (Source/Album/Track/Asset/
    /// Playlist/PlaylistItem/Favorite/PlayEvent/CustomArtwork/AppSettings/
    /// PlaybackState) still fall through to the placeholder below — nothing
    /// currently calls `enqueue(recordIDs:)` for them either, so this is
    /// not a regression, but finishing their real wiring (plan §2.1) is
    /// separate, not-yet-done work.
    private func buildRecord(for recordID: CKRecord.ID) async -> CKRecord? {
        // RecordMapping.recordID(type:syncID:zoneID:) names records
        // "<Type>-<syncID>" — parse that back out (the syncID itself may
        // contain "-", so split only on the first one).
        guard let dashRange = recordID.recordName.range(of: "-") else { return nil }
        let typeRaw = String(recordID.recordName[..<dashRange.lowerBound])
        let syncID = String(recordID.recordName[dashRange.upperBound...])
        guard let type = RecordMapping.RecordType(rawValue: typeRaw) else { return nil }

        switch type {
        case .discoveryEmbedding:
            guard let (embedding, trackSyncID) = try? await store.discoveryEmbedding(forSyncID: syncID)
            else { return nil }
            let keys = (try? await store.trackIdentityKeys(trackId: embedding.trackId)) ?? []
            return RecordMapping.record(from: embedding, trackSyncID: trackSyncID, trackKeys: keys, zoneID: zoneID)
        case .discoveryTrackAnalysis:
            guard let (analysis, trackSyncID) = try? await store.discoveryTrackAnalysis(forSyncID: syncID)
            else { return nil }
            let keys = (try? await store.trackIdentityKeys(trackId: analysis.trackId)) ?? []
            return RecordMapping.record(from: analysis, trackSyncID: trackSyncID, trackKeys: keys, zoneID: zoneID)
        case .djTrackPrep:
            guard let prep = try? await store.djTrackPrepBySyncID(syncID),
                  prep.trackId >= 0 else { return nil }
            let trackID = prep.trackId
            let trackSyncID: String?
            do { trackSyncID = try await store.trackSyncID(trackId: trackID) }
            catch { trackSyncID = nil }
            let keys = (try? await store.trackIdentityKeys(trackId: trackID)) ?? []
            return RecordMapping.record(from: prep, trackSyncID: trackSyncID, trackKeys: keys, zoneID: zoneID)
        default:
            return nil
        }
    }

    /// Pull path: decode via `RecordMapping`, apply
    /// `DiscoveryEmbeddingSyncDecision`'s accept/reject/requeue outcome for
    /// the two discovery record types (plan §4.3); other types are logged
    /// only, matching this file's pre-existing (unfinished, plan §2.1)
    /// state for them.
    private func applyFetched(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) async {
        var activity = DiscoverySyncActivity()
        let versions = activePipelineVersionsProvider?()

        for modification in changes.modifications {
            let record = modification.record
            guard let type = RecordMapping.RecordType(rawValue: record.recordType) else { continue }

            switch type {
            case .discoveryEmbedding:
                guard let versions else { continue }
                guard let (embedding, trackSyncID) = RecordMapping.discoveryEmbedding(from: record)
                else { continue }
                let keys = RecordMapping.discoveryTrackKeys(from: record)
                let result = (try? await store.applyIncomingDiscoveryEmbedding(
                    embedding, trackSyncID: trackSyncID, trackKeys: keys,
                    activePipelineVersion: versions.pipeline, activeModelVersion: versions.model,
                    activePreprocessingVersion: versions.preprocessing,
                    activeSamplingVersion: versions.sampling)) ?? .trackNotYetImported
                activity.record(result)
                if result == .trackNotYetImported { await keepPending(record, keys: keys) }

            case .discoveryTrackAnalysis:
                guard let versions else { continue }
                guard let (analysis, trackSyncID) = RecordMapping.discoveryTrackAnalysis(from: record)
                else { continue }
                let keys = RecordMapping.discoveryTrackKeys(from: record)
                let result = (try? await store.applyIncomingDiscoveryTrackAnalysis(
                    analysis, trackSyncID: trackSyncID, trackKeys: keys,
                    activePipelineVersion: versions.pipeline,
                    activeAnalysisVersion: versions.musicalAnalysis)) ?? .trackNotYetImported
                activity.record(result)
                if result == .trackNotYetImported { await keepPending(record, keys: keys) }

            case .djTrackPrep:
                guard let envelope = RecordMapping.djTrackPrep(from: record) else { continue }
                let matchingIDs = (try? await store.localTrackIds(matching: envelope.trackKeys,
                                                                   trackSyncID: envelope.trackSyncID)) ?? []
                let applied = (try? await store.applyIncomingDJTrackPrep(envelope)) ?? 0
                if applied == 0 {
                    await keepPending(record, keys: envelope.trackKeys)
                } else {
                    for id in matchingIDs { onDJTrackPrepApplied?(id) }
                }
            default:
                break
            }
        }
        await retryPending()
        let pruned = (try? await store.prunePendingSyncRecords()) ?? 0
        activity.setPendingCount((try? await store.pendingSyncRecordCount()) ?? 0,
                                 oldest: try? await store.pendingSyncOldestDate(), pruned: pruned)
        lastSyncActivity = activity
        log.info("""
            fetched \(changes.modifications.count) modifications, \
            \(changes.deletions.count) deletions — discovery sync: \
            accepted \(activity.accepted), rejectedKeepLocal \(activity.rejectedKeepLocal), \
            rejectedRequeued \(activity.rejectedRequeued), pendingTrackImport \(activity.pendingTrackImport)
            """)
    }

    private func keepPending(_ record: CKRecord, keys: [TrackIdentityKey]) async {
        guard let payload = try? NSKeyedArchiver.archivedData(withRootObject: record,
                                                               requiringSecureCoding: false) else { return }
        try? await store.upsertPendingSyncRecord(recordName: record.recordID.recordName,
                                                 recordType: record.recordType,
                                                 payload: payload, trackKeys: keys)
    }

    /// Retries records delivered before their matching library rows existed.
    /// The saved CKRecord goes through the same mapping and merge functions as
    /// a fresh CloudKit delivery, then is deleted only after a match succeeds.
    public func retryPending() async {
        guard let rows = try? await store.pendingSyncRecords(), !rows.isEmpty else { return }
        let versions = activePipelineVersionsProvider?()
        for row in rows {
            guard let record = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self,
                                                                        from: row.payload) else { continue }
            let type = RecordMapping.RecordType(rawValue: row.recordType)
            var applied = false
            switch type {
            case .discoveryEmbedding:
                guard let versions,
                      let value = RecordMapping.discoveryEmbedding(from: record) else { continue }
                let result = try? await store.applyIncomingDiscoveryEmbedding(
                    value.embedding, trackSyncID: value.trackSyncID,
                    trackKeys: RecordMapping.discoveryTrackKeys(from: record),
                    activePipelineVersion: versions.pipeline,
                    activeModelVersion: versions.model,
                    activePreprocessingVersion: versions.preprocessing,
                    activeSamplingVersion: versions.sampling)
                if let result { applied = result != .trackNotYetImported }
            case .discoveryTrackAnalysis:
                guard let versions,
                      let value = RecordMapping.discoveryTrackAnalysis(from: record) else { continue }
                let result = try? await store.applyIncomingDiscoveryTrackAnalysis(
                    value.analysis, trackSyncID: value.trackSyncID,
                    trackKeys: RecordMapping.discoveryTrackKeys(from: record),
                    activePipelineVersion: versions.pipeline,
                    activeAnalysisVersion: versions.musicalAnalysis)
                if let result { applied = result != .trackNotYetImported }
            case .djTrackPrep:
                guard let value = RecordMapping.djTrackPrep(from: record) else { continue }
                let matchingIDs = (try? await store.localTrackIds(matching: value.trackKeys,
                                                                   trackSyncID: value.trackSyncID)) ?? []
                applied = ((try? await store.applyIncomingDJTrackPrep(value)) ?? 0) > 0
                if applied { for id in matchingIDs { onDJTrackPrepApplied?(id) } }
            default:
                applied = true
            }
            if applied { try? await store.deletePendingSyncRecord(recordName: row.recordName) }
        }
        await refreshPendingActivity()
    }

    public func refreshPendingActivity() async {
        let count = (try? await store.pendingSyncRecordCount()) ?? 0
        var activity = lastSyncActivity
        activity.setPendingCount(count, oldest: try? await store.pendingSyncOldestDate())
        lastSyncActivity = activity
    }
}
#endif
