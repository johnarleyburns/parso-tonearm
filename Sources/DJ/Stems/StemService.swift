import Foundation
import GRDB
import TonearmCore

// MARK: - Progress

/// Progress emitted by the §36.3 stem lane (mirrors `AnalysisProgress`).
public struct StemProgress: Sendable, Equatable {
    public var completed: Int
    public var total: Int
    public var currentTrackTitle: String?
    public var governorWords: String

    public init(completed: Int, total: Int, currentTrackTitle: String? = nil,
                governorWords: String = "") {
        self.completed = completed
        self.total = total
        self.currentTrackTitle = currentTrackTitle
        self.governorWords = governorWords
    }

    /// Honest ETA from the fraction of work done.
    public func etaSeconds(elapsed: TimeInterval) -> TimeInterval? {
        guard completed > 0, total > completed else { return nil }
        return (elapsed / Double(completed)) * Double(total - completed)
    }
}

// MARK: - The §36.3 lane

/// The stage-3 stem lane (plan decision 2, §36.3, FR-ANL-9): separates a gig
/// crate's tracks, serialized (concurrency 1 — each job saturates the
/// ANE/GPU), under the `.stems` governor row (§43.7) and the FR-ANL-2
/// performance pin. The queue is **crate-scoped** — stage 3 runs only for
/// tracks in a prepared crate, so the stem cache stays gig-sized instead of
/// library-wide (§43.6). On-demand deck separation (§36.5) is a separate,
/// best-effort entry that still yields to audio.
///
/// Budgeting: before the lane runs it consults `StorageBudgetService.plan` and
/// **evicts least-recently-performed crates first** to make room (FR-ANL-9,
/// AT-STEM-\*). The plan (the preview) is computed by `planPreparation` and
/// shown by the UI before `runCrateLane` performs the eviction it names.
public actor StemService {

    public let pool: DatabasePool
    public let separator: StemSeparator
    public let cache: StemCache
    public let repository: GigCrateRepository
    /// Resolves a track's asset to a file URL — the same seam the analysis
    /// coordinator uses.
    private let assetURL: @Sendable (Int64, Database) throws -> URL?
    /// Injectable `.stems` governor gate; defaults to the real thermal decision.
    private let governorAllowsRun: @Sendable () -> Bool
    private let onProgress: @Sendable (StemProgress) -> Void
    /// Fired with a trackID the instant its stems land in the cache, so a
    /// deck playing that track can re-resolve to `.prepared` (§36.5).
    private let onStemsReady: @Sendable (Int64) -> Void
    /// The single-consumer progress stream (§40.3's newest-1 idiom): the model
    /// awaits `observeProgress()`; a missed step drops the stale readout.
    private var progressBuilt: AsyncStream<StemProgress>?
    private var progressContinuation: AsyncStream<StemProgress>.Continuation?

    /// A performance is live → the lane pauses (FR-ANL-2).
    public private(set) var isPerforming: Bool = false
    public private(set) var isRunning = false

    public init(pool: DatabasePool,
                separator: StemSeparator,
                cache: StemCache,
                repository: GigCrateRepository? = nil,
                assetURL: @escaping @Sendable (Int64, Database) throws -> URL? =
                    AnalysisCoordinator.defaultAssetURL,
                governorAllowsRun: @escaping @Sendable () -> Bool =
                    StemService.defaultGovernorGate,
                onProgress: @escaping @Sendable (StemProgress) -> Void = { _ in },
                onStemsReady: @escaping @Sendable (Int64) -> Void = { _ in }) {
        self.pool = pool
        self.separator = separator
        self.cache = cache
        self.repository = repository ?? GigCrateRepository(pool: pool)
        self.assetURL = assetURL
        self.governorAllowsRun = governorAllowsRun
        self.onProgress = onProgress
        self.onStemsReady = onStemsReady
    }

    /// The real `.stems` governor gate: the lane is paused when the thermal
    /// state says so (§43.7 — full at nominal, half at fair, paused at
    /// serious/critical).
    public static func defaultGovernorGate() -> Bool {
        !ThermalGovernor.decision(for: .stems,
                                  thermalState: ProcessInfo.processInfo.thermalState).isPaused
    }

    /// Mark a performance as live/ended; while live, the lane is paused.
    public func setPerforming(_ performing: Bool) {
        isPerforming = performing
    }

    // MARK: - Reconcile

    /// How many crate tracks still need stems — the reconcile count (§36.3).
    public func reconcileCount(crateID: Int64) throws -> Int {
        try repository.tracksNeedingStemsCount(crateID: crateID)
    }

    /// Whether the lane is currently able to run (used to keep honest state
    /// in the UI's "preparing…" panel).
    public func canRunNow() -> Bool {
        !isPerforming && governorAllowsRun()
    }

    // MARK: - Progress

    /// The single-consumer progress stream. The first call builds it; the lane
    /// publishes every step (newest-1 buffering, §40.3's idiom).
    public func observeProgress() async -> AsyncStream<StemProgress> {
        if let progressBuilt { return progressBuilt }
        let (stream, continuation) = AsyncStream<StemProgress>.makeStream(
            of: StemProgress.self, bufferingPolicy: .bufferingNewest(1))
        progressContinuation = continuation
        progressBuilt = stream
        return stream
    }

    private func publishProgress(_ progress: StemProgress) {
        onProgress(progress)
        progressContinuation?.yield(progress)
    }

    // MARK: - Budgeting (FR-ANL-9, AT-STEM-\*)

    /// The eviction **preview** for preparing `crateID`: the budget account,
    /// the projected total once every pending track is separated (§43.6's
    /// ~13 MB/track), and — when the crate does not fit — exactly which crates
    /// are evicted, LRU first. The UI renders this before any eviction happens
    /// (§41.17, decision 11). `protectedIDs` are never evicted (crates backing
    /// a loaded deck); the crate being prepared is always protected.
    public func planPreparation(crateID: Int64,
                                budget: Int64,
                                protectedIDs: Set<Int64> = []) async throws -> StorageBudgetService.StemPlan {
        let allProtected = protectedIDs.union([crateID])
        let usages = try repository.cratesByLRU(excluding: [])
            .map { StorageBudgetService.CrateUsage(crateID: $0.id,
                                                   name: $0.name,
                                                   stemsBytes: $0.stemsBytes,
                                                   lastPerformedAt: $0.lastPerformedAt) }
        let current = usages.reduce(Int64(0)) { $0 + $1.stemsBytes }
        let pending = try repository.tracksNeedingStemsCount(crateID: crateID)
        let adding = Int64(pending) * StorageBudgetService.estimatedStemsBytesPerTrack
        return StorageBudgetService.plan(addingBytes: adding,
                                         budget: budget,
                                         currentStemsBytes: current,
                                         usages: usages,
                                         protectedIDs: allProtected)
    }

    /// Perform one crate's eviction: remove its stem sets from the cache and
    /// mark its tracks `evicted` — the action the `planPreparation` preview
    /// names. The full mix still plays; the tracks re-queue on the next
    /// prepare (§43.6 "evict least-recently-performed stems first").
    public func evict(crateID: Int64) async throws {
        let trackIDs = try await pool.read { db in
            try GigCrateTrack
                .filter(Column("gigCrateID") == crateID
                        && (Column("stemsState") == GigCrateStemsState.ready.rawValue
                            || Column("stemsBytes") > 0))
                .fetchAll(db)
                .compactMap(\.trackID)
        }
        for trackID in trackIDs {
            try await cache.evict(trackID: trackID,
                                  modelVersion: AnalysisVersions.stems)
            try await pool.write { db in
                try db.execute(sql: """
                    UPDATE gig_crate_track
                    SET stemsState = ?, stemsBytes = 0
                    WHERE gigCrateID = ? AND trackID = ?
                    """, arguments: [GigCrateStemsState.evicted.rawValue, crateID, trackID])
                try db.execute(sql: """
                    UPDATE track SET stemState = ? WHERE id = ?
                    """, arguments: ["evicted", trackID])
            }
        }
    }

    // MARK: - The crate lane

    /// Run the crate-scoped lane: plan the budget (evicting LRU crates to make
    /// room), then separate every pending track in order, serialized, pausing
    /// and abandoning the instant a performance starts or the `.stems` lane is
    /// shed (§36.3, §43.7). A mid-run abandonment leaves the remaining tracks
    /// `pending` — re-running resumes, never re-separates the ready ones.
    public func runCrateLane(crateID: Int64,
                             budget: Int64,
                             protectedIDs: Set<Int64> = []) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        guard !isPerforming, governorAllowsRun() else { return }

        // Budget: evict LRU crates first to make room for this one (FR-ANL-9).
        do {
            let plan = try await planPreparation(crateID: crateID, budget: budget,
                                                 protectedIDs: protectedIDs)
            for eviction in plan.evictions where eviction.crateID != crateID {
                try await evict(crateID: eviction.crateID)
            }
            guard plan.fits else {
                publishProgress(StemProgress(completed: 0, total: 0, currentTrackTitle: nil,
                                             governorWords: "paused — the stem budget cannot hold this crate"))
                return
            }
        } catch {
            return
        }

        let tracks: [GigCrateTrack]
        do {
            tracks = try await pool.read { db in
                try GigCrateTrack
                    .filter(Column("gigCrateID") == crateID
                            && Column("stemsState") != GigCrateStemsState.ready.rawValue)
                    .order(Column("position"))
                    .fetchAll(db)
            }
        } catch {
            return
        }
        guard !tracks.isEmpty else { return }

        let total = tracks.count
        var done = 0
        for track in tracks {
            if isPerforming || !governorAllowsRun() {
                return // abandon the rest; they stay pending
            }
            done += 1
            let title = trackTitle(track.trackID)
            publishProgress(StemProgress(completed: done, total: total,
                                         currentTrackTitle: title,
                                         governorWords: currentGovernorWords()))
            await separate(track: track, crateID: crateID)
        }
        publishProgress(StemProgress(completed: total, total: total,
                                     governorWords: currentGovernorWords()))
    }

    /// On-demand separation for a deck load (§36.5): best-effort, deprioritized
    /// by the same governor and abandoned at `.serious`, and never blocking the
    /// deck — the caller plays the full mix meanwhile. The separated set is
    /// **cached** so the next load of the same track is instant (§36.4).
    /// Returns the separated set (or nil when the model is absent / the lane is
    /// shed).
    @discardableResult
    public func separateOnDemand(trackID: Int64) async -> StemSeparation? {
        guard !isPerforming, governorAllowsRun() else { return nil }
        guard let track = try? await pool.read({ db in
            try DJTrack.fetchOne(db, key: trackID)
        }) else { return nil }
        guard let separation = await separate(track: track) else { return nil }
        do {
            let record = try await cache.store(separation, trackID: trackID,
                                               contentHash: track.contentHash)
            try await pool.write { db in
                try db.execute(sql: """
                    UPDATE track SET stemState = ? WHERE id = ?
                    """, arguments: ["ready", trackID])
            }
            onStemsReady(trackID)
            _ = record
        } catch {
            // Caching is best-effort on the on-demand path — the caller still
            // gets the voices to play now; the next prepare re-caches them.
        }
        return separation
    }

    // MARK: - Per-track

    /// Separate one crate track and persist the ready state in one transaction.
    private func separate(track: GigCrateTrack, crateID: Int64) async {
        let trackID = track.trackID
        do {
            try repository.setStemsState(crateID: crateID, trackID: trackID,
                                         state: .running)
        } catch {
            return
        }
        guard let row = try? await pool.read({ db in try DJTrack.fetchOne(db, key: trackID) }) else {
            try? repository.setStemsState(crateID: crateID, trackID: trackID, state: .failed)
            return
        }
        guard let separation = await separate(track: row) else {
            // Model absent (FR-SEM-6): honest absence, not a failure — leave
            // the track pending so the lane re-attempts when the model lands.
            try? repository.setStemsState(crateID: crateID, trackID: trackID,
                                          state: .pending)
            return
        }
        do {
            let record = try await cache.store(separation, trackID: trackID,
                                               contentHash: row.contentHash)
            try await pool.write { db in
                try db.execute(sql: """
                    UPDATE gig_crate_track
                    SET stemsState = ?, stemsBytes = ?
                    WHERE gigCrateID = ? AND trackID = ?
                    """, arguments: [GigCrateStemsState.ready.rawValue,
                                     record.totalBytes, crateID, trackID])
                try db.execute(sql: """
                    UPDATE track SET stemState = ? WHERE id = ?
                    """, arguments: ["ready", trackID])
            }
            onStemsReady(trackID)
        } catch {
            try? repository.setStemsState(crateID: crateID, trackID: trackID,
                                          state: .failed)
        }
    }

    /// Decode + separate one track. Returns nil when the model is absent — the
    /// honest FR-SEM-6 absence, never an error and never a partial result.
    private func separate(track: DJTrack) async -> StemSeparation? {
        let trackID = track.id ?? 0
        let url: URL
        do {
            guard let resolved = try await pool.read({ try assetURL(trackID, $0) }) else {
                return nil
            }
            url = resolved
        } catch {
            return nil
        }
        do {
            let pcm = try AudioDecoder.decode(url)
            return try await separator.separate(pcm: pcm)
        } catch {
            return nil
        }
    }

    private func trackTitle(_ trackID: Int64) -> String? {
        try? pool.read { db in
            try DJTrack.fetchOne(db, key: trackID)?.title
        }
    }

    private func currentGovernorWords() -> String {
        ThermalGovernor.words(lane: .stems,
                              thermalState: ProcessInfo.processInfo.thermalState,
                              batteryLevelPercent: 100, isCharging: true,
                              userOverride: false, isPerforming: isPerforming)
    }
}
