import Foundation
import TonearmWatchProtocol

// MARK: - Seams

/// The result of resolving a desired watch track into a phone-local file ready to transfer.
public enum PhoneWatchAudioResolution: Sendable, Equatable {
    /// A complete local file exists (imported asset or a fully-populated cache entry).
    case cached(URL, bytes: Int64, sha256: String?)
    /// The track's container/codec is not watch-playable — a permanent skip.
    case unsupported(reason: String)
    /// No local asset and the remote source could not be reached right now.
    case unavailable
    /// The source needs re-authentication before it can be fetched.
    case needsAuth
}

/// A watch-compatible derivative that is ready to hand to the file-transfer channel. The URL is
/// phone-local and never crosses the protocol; only the opaque content hash and the bytes do.
public struct PhoneWatchArtworkTransfer: Sendable, Equatable {
    public let fileURL: URL
    public let artworkID: String
    public let role: WatchArtworkRole
    public let expectedBytes: Int64
    public let sha256: String

    public init(fileURL: URL, artworkID: String, role: WatchArtworkRole,
                expectedBytes: Int64, sha256: String) {
        self.fileURL = fileURL
        self.artworkID = artworkID
        self.role = role
        self.expectedBytes = expectedBytes
        self.sha256 = sha256
    }
}

/// The derivative-backed bindings and bytes prepared for one desired track. A cover and custom
/// asset are deliberately independent so the cover remains a fallback while custom art arrives.
public struct PhoneWatchArtworkResolution: Sendable, Equatable {
    public let coverArtworkID: String?
    public let customArtworkID: String?
    public let transfers: [PhoneWatchArtworkTransfer]

    public init(coverArtworkID: String? = nil, customArtworkID: String? = nil,
                transfers: [PhoneWatchArtworkTransfer] = []) {
        self.coverArtworkID = coverArtworkID
        self.customArtworkID = customArtworkID
        self.transfers = transfers
    }
}

/// Shared projection cache between the transfer manager and the request handler. It contains only
/// derivative IDs, never source artwork identifiers or file URLs.
public actor PhoneWatchArtworkBindingRegistry {
    private var bindings: [String: (cover: String?, custom: String?)] = [:]

    public init() {}

    public func set(trackID: String, coverArtworkID: String?, customArtworkID: String?) {
        bindings[trackID] = (coverArtworkID, customArtworkID)
    }

    public func binding(for trackID: String) -> (coverArtworkID: String?, customArtworkID: String?) {
        let binding = bindings[trackID]
        return (binding?.cover, binding?.custom)
    }
}

/// Resolves the real selected phone cover/custom art at watch-transfer time. Implementations may
/// persist a derivative-backed custom binding while preparing the resolution.
public protocol PhoneWatchArtworkResolving: Sendable {
    func resolveArtwork(trackID: WatchTrackID) async -> PhoneWatchArtworkResolution?
}

/// Sibling to the audio transfer seam. Keeping artwork separate lets the manager gate it without
/// making older test transports or mixed-version peers understand a new operation.
public protocol PhoneWatchArtworkTransferring: Sendable {
    func transferArtwork(_ transfer: PhoneWatchArtworkTransfer) async throws
}

/// Resolves watch track IDs into transferable phone-local files (§8.1 "resolve remote audio into
/// the existing phone cache before transfer"). The real implementation lives in `Sources/App/Watch`;
/// tests inject a deterministic fake.
public protocol PhoneWatchAudioResolving: Sendable {
    func resolve(trackID: WatchTrackID) async -> PhoneWatchAudioResolution
    /// A cheap, side-effect-free classification for the planner — does not perform the fetch.
    func transferability(trackID: WatchTrackID) async -> PhoneWatchTransferability
}

/// Hands a file to WatchConnectivity (or a fake writer). §8.2: sender-side progress is phone UI
/// only; the watch reports installation truth separately.
public protocol PhoneWatchFileTransferring: Sendable {
    /// Throws on rejection. A thrown `WatchProtocolFault` carries the code the scheduler classifies;
    /// any other error is treated as transient.
    func transfer(fileURL: URL, trackID: WatchTrackID, expectedBytes: Int64, sha256: String?) async throws
    /// Track IDs the framework still lists as outstanding at launch/activation (§8.2 rehydrate).
    func outstandingTransfers() async -> [WatchTrackID]
    /// Best-effort cancellation; must be idempotent if delivery wins the race.
    func cancelTransfer(trackID: WatchTrackID) async
}

/// The phone's current network policy for watch transfers. Returns false when the only available
/// path is cellular and cellular downloading is disabled → the UI shows `Waiting for Wi-Fi`.
public protocol PhoneWatchNetworkGate: Sendable {
    func canTransferNow() async -> Bool
}

/// A gate that always permits transfers — the default when no policy is injected.
public struct PhoneWatchAlwaysOnNetworkGate: PhoneWatchNetworkGate {
    public init() {}
    public func canTransferNow() async -> Bool { true }
}

// MARK: - Manager

/// The phone transfer manager (§8.2). Owns the reconcile → schedule → transfer loop, persisting
/// every state transition through `PhoneWatchDownloadStore` before touching the transfer seam so a
/// crash is always recoverable. Unwired until Phase 6 constructs it from `AppState`.
public actor PhoneWatchDownloadManager {
    private let store: PhoneWatchDownloadStore
    private let resolver: any PhoneWatchAudioResolving
    private let transfer: any PhoneWatchFileTransferring
    private let networkGate: any PhoneWatchNetworkGate
    private let emitRoots: @Sendable ([WatchDownloadRootDescriptor], Int64) async -> Void
    private let rootExpander: @Sendable (PhoneWatchDownloadRoot) async -> [String]
    private let now: @Sendable () -> Date
    private let artworkResolver: (any PhoneWatchArtworkResolving)?
    private let artworkTransfer: (any PhoneWatchArtworkTransferring)?
    private let artworkCapability: @Sendable () async -> Bool
    private let publishArtworkBindings: @Sendable (String, String?, String?) async -> Void

    private var explicitRetryTrackIDs: Set<String> = []
    private var desiredArtworkTrackIDs: Set<String> = []
    private var artworkPlans: [String: PhoneWatchArtworkResolution] = [:]
    private var artworkSentIDs: Set<String> = []

    public init(store: PhoneWatchDownloadStore,
                resolver: any PhoneWatchAudioResolving,
                transfer: any PhoneWatchFileTransferring,
                networkGate: any PhoneWatchNetworkGate = PhoneWatchAlwaysOnNetworkGate(),
                emitRoots: @escaping @Sendable ([WatchDownloadRootDescriptor], Int64) async -> Void = { _, _ in },
                rootExpander: @escaping @Sendable (PhoneWatchDownloadRoot) async -> [String] = { $0.desiredTrackIDs },
                now: @escaping @Sendable () -> Date = { Date() },
                artworkResolver: (any PhoneWatchArtworkResolving)? = nil,
                artworkTransfer: (any PhoneWatchArtworkTransferring)? = nil,
                artworkCapability: @escaping @Sendable () async -> Bool = { true },
                publishArtworkBindings: @escaping @Sendable (String, String?, String?) async -> Void = { _, _, _ in }) {
        self.store = store
        self.resolver = resolver
        self.transfer = transfer
        self.networkGate = networkGate
        self.emitRoots = emitRoots
        self.rootExpander = rootExpander
        self.now = now
        self.artworkResolver = artworkResolver
        self.artworkTransfer = artworkTransfer
        self.artworkCapability = artworkCapability
        self.publishArtworkBindings = publishArtworkBindings
    }

    // MARK: - Root mutations

    /// Replace the complete desired-root set (§5.3 `setDownloadRoots` is never a delta).
    public func setRoots(_ roots: [PhoneWatchDownloadRoot]) async throws {
        try await store.replaceRoots(roots)
        try await reconcile()
        try await emitCurrentRoots()
    }

    /// Re-run the desired-root reconciliation after a phone-side custom-art assignment. The
    /// binding and derivative are prepared lazily here, so no watch UI or Now Playing surface is
    /// required to schedule the bytes.
    public func artworkDidChange() async throws {
        try await reconcile()
        try await emitCurrentRoots()
    }

    public func addRoot(_ root: PhoneWatchDownloadRoot) async throws {
        try await store.upsertRoot(root)
        try await reconcile()
        try await emitCurrentRoots()
    }

    public func removeRoot(rootID: String) async throws {
        try await store.deleteRoot(rootID: rootID)
        try await reconcile()
        try await emitCurrentRoots()
    }

    /// A retry the user explicitly asked for — one attempt, higher priority (§8.1 bucket 2).
    public func requestRetry(trackID: String) async throws {
        explicitRetryTrackIDs.insert(trackID)
        try await reconcile()
    }

    /// Retry a specific job by request ID (Phase 8 P3 "Try Again"). Resolves the job's track and
    /// funnels through the same explicit-retry path, which revives a failed *or* cancelled job.
    public func requestRetry(requestID: String) async throws {
        guard let job = try await store.jobs().first(where: { $0.requestID == requestID }) else { return }
        try await requestRetry(trackID: job.trackID)
    }

    /// Phase 8 (P3/P4): pause a desired root from the iPhone. The root stays declared to the watch
    /// (installed tracks are kept), but reconcile stops feeding its tracks to the transfer loop and
    /// cancels any in-flight job that no other unpaused root still wants.
    public func pauseRoot(rootID: String) async throws {
        try await setRootPaused(rootID: rootID, paused: true)
    }

    /// Resume a paused root; reconcile re-queues whatever is still missing.
    public func resumeRoot(rootID: String) async throws {
        try await setRootPaused(rootID: rootID, paused: false)
    }

    private func setRootPaused(rootID: String, paused: Bool) async throws {
        guard var root = try await store.roots().first(where: { $0.rootID == rootID }),
              root.paused != paused else { return }
        root.paused = paused
        try await store.upsertRoot(root)
        try await reconcile()
    }

    /// Phase 8 (P3): cancel one job. A user-cancelled job stays cancelled until an explicit retry
    /// (the planner change in this phase enforces that); a best-effort transfer cancel is issued in
    /// case delivery has not already won the race.
    public func cancelJob(requestID: String) async throws {
        guard var job = try await store.jobs().first(where: { $0.requestID == requestID }),
              job.state != .sent, job.state != .cancelled else { return }
        job.state = .cancelled
        job.updatedAt = now()
        try await store.upsertJob(job)
        await transfer.cancelTransfer(trackID: WatchTrackID(job.trackID))
        try await reconcile()
    }

    private func emitCurrentRoots() async throws {
        let revision = try await store.bumpRevision()
        let descriptors = try await store.roots().map(\.descriptor)
        await emitRoots(descriptors, revision)
    }

    // MARK: - Manifest ingest

    /// Apply the watch's latest manifest (§1.6 second authority) and re-reconcile. Per-track bytes
    /// are not in the payload, so a known job's `expectedBytes` fills in where available.
    public func ingestManifest(_ payload: WatchManifestPayload) async throws {
        // A manifest is the watch's authority. Anything absent must be eligible for a resend,
        // including an asset that was previously accepted by WCSession but never installed.
        artworkSentIDs.formIntersection(Set(payload.installedArtworkIDs.map { $0.lowercased() }))
        let existing = try await store.jobs()
        let jobsByTrack = Dictionary(existing.map { ($0.trackID, $0) },
                                     uniquingKeysWith: { a, b in a.updatedAt >= b.updatedAt ? a : b })
        let entries = payload.readyTrackIDs.map { id -> PhoneWatchManifestEntry in
            PhoneWatchManifestEntry(trackID: id.rawValue,
                                    bytes: jobsByTrack[id.rawValue]?.expectedBytes ?? 0,
                                    manifestID: payload.manifestID,
                                    reportedAt: payload.generatedAt)
        }
        try await store.replaceManifest(entries)
        try await reconcile()
    }

    /// The app's periodic / foreground nudge. Re-runs reconciliation, which is what advances
    /// backed-off transient retries — there is no idle timer inside the manager (I-10).
    public func tick() async throws {
        try await reconcile()
    }

    // MARK: - Reconcile + pump

    /// Recompute the plan from persisted roots, jobs, and the watch manifest, apply it durably,
    /// then dispatch as many transfers as the caps allow.
    public func reconcile() async throws {
        let storedRoots = try await store.roots()
        // Playlist roots stay live: re-expand them; track/album batches are frozen snapshots.
        var roots: [PhoneWatchDownloadRoot] = []
        for root in storedRoots {
            if root.kind == .playlist {
                var live = root
                live.desiredTrackIDs = await rootExpander(root)
                roots.append(live)
            } else {
                roots.append(root)
            }
        }

        // Phase 8: paused roots stay declared to the watch (installed tracks are kept) but are
        // excluded from planning, so their in-flight jobs are cancelled and nothing new is queued.
        let activeRoots = roots.filter { !$0.paused }
        desiredArtworkTrackIDs = Set(activeRoots.flatMap(\.desiredTrackIDs))

        artworkPlans = [:]
        if await artworkCapability(), await networkGate.canTransferNow(),
           let artworkResolver {
            for trackID in desiredArtworkTrackIDs.sorted() {
                let resolved = await artworkResolver.resolveArtwork(trackID: WatchTrackID(trackID))
                if let resolved {
                    artworkPlans[trackID] = resolved
                    await publishArtworkBindings(trackID, resolved.coverArtworkID, resolved.customArtworkID)
                } else {
                    // The phone's authoritative custom-art binding may have been cleared since
                    // the previous reconcile. Remove the cached projection so a later collection
                    // response cannot resurrect a stale derivative ID on the watch.
                    await publishArtworkBindings(trackID, nil, nil)
                }
            }
        }

        let installed = try await store.installedTrackIDs()
        let existing = try await store.jobs()

        var transferability: [String: PhoneWatchTransferability] = [:]
        for track in Set(activeRoots.flatMap(\.desiredTrackIDs)) where !installed.contains(track) {
            transferability[track] = await resolver.transferability(trackID: WatchTrackID(track))
        }

        let ts = now()
        // Transient failures whose backoff has elapsed are retried now; the planner has no clock,
        // so fold them into the retry set alongside the user's explicit retries.
        let timerElapsed = existing
            .filter { $0.state == .failed && ($0.failureClass?.isRetryable ?? false)
                && ($0.nextAttemptAt ?? .distantPast) <= ts }
            .map(\.trackID)
        let retrySet = explicitRetryTrackIDs.union(timerElapsed)

        let plan = PhoneWatchDownloadPlanner.plan(
            roots: activeRoots, installedTrackIDs: installed, existingJobs: existing,
            transferability: { transferability[$0] ?? .unavailable },
            explicitRetryTrackIDs: retrySet)

        let jobsByTrack = Dictionary(existing.map { ($0.trackID, $0) },
                                     uniquingKeysWith: { a, b in a.updatedAt >= b.updatedAt ? a : b })
        let jobsByRequest = Dictionary(uniqueKeysWithValues: existing.map { ($0.requestID, $0) })
        var writes: [PhoneWatchDownloadJob] = []

        for planned in plan.toCreate where jobsByTrack[planned.trackID]?.isActive != true {
            writes.append(PhoneWatchDownloadJob(
                trackID: planned.trackID, rootIDs: planned.rootIDs, priority: planned.priority,
                state: .queued, expectedBytes: planned.expectedBytes,
                expectedSHA256: planned.expectedSHA256, createdAt: ts, updatedAt: ts))
        }
        for requestID in plan.toReset {
            guard var job = jobsByRequest[requestID] else { continue }
            job.state = .queued
            job.failureClass = nil
            job.errorCode = nil
            job.message = nil
            job.nextAttemptAt = nil
            job.updatedAt = ts
            writes.append(job)
        }
        var cancelledTracks: [String] = []
        for requestID in plan.toCancel {
            guard var job = jobsByRequest[requestID] else { continue }
            job.state = .cancelled
            job.updatedAt = ts
            writes.append(job)
            cancelledTracks.append(job.trackID)
        }
        if !writes.isEmpty { try await store.upsertJobs(writes) }
        for track in cancelledTracks {
            await transfer.cancelTransfer(trackID: WatchTrackID(track))
        }

        explicitRetryTrackIDs.subtract(plan.toReset.compactMap { jobsByRequest[$0]?.trackID })

        // Paused roots keep their settled jobs (a `.sent`-but-unconfirmed job is the dedup guard),
        // so the prune "desired" set spans *all* roots, not just the active ones.
        try await store.pruneSettledJobs(installedTrackIDs: installed,
                                         desiredTrackIDs: Set(roots.flatMap(\.desiredTrackIDs)))

        try await pump()
    }

    /// Dispatch transfers until the in-flight caps or the network gate stop us. Failed jobs with a
    /// future `nextAttemptAt` are naturally excluded, so this terminates.
    public func pump() async throws {
        var canNetwork = false
        while true {
            let jobs = try await store.jobs()
            canNetwork = await networkGate.canTransferNow()

            if !canNetwork {
                let waiting = jobs.filter {
                    $0.state == .queued && ($0.nextAttemptAt ?? .distantPast) <= now()
                }
                if !waiting.isEmpty {
                    try await store.upsertJobs(waiting.map {
                        var j = $0; j.state = .waitingForWiFi; j.updatedAt = now(); return j
                    })
                }
                return
            }

            let resume = jobs.filter { $0.state == .waitingForWiFi }
            if !resume.isEmpty {
                try await store.upsertJobs(resume.map {
                    var j = $0; j.state = .queued; j.updatedAt = now(); return j
                })
                continue
            }

            let next = PhoneWatchTransferScheduler.nextDispatch(
                jobs: jobs, now: now(), canTransferOnNetwork: canNetwork)
            guard let requestID = next.first,
                  var job = jobs.first(where: { $0.requestID == requestID }) else { break }

            job.state = .resolving
            job.updatedAt = now()
            try await store.upsertJob(job)

            switch await resolver.resolve(trackID: WatchTrackID(job.trackID)) {
            case .unsupported(let reason):
                try await fail(&job, class: .fileUnsupported, code: .unsupportedAudio, message: reason)
            case .unavailable:
                try await fail(&job, class: .sourceUnavailable, code: .sourceUnavailable,
                               message: WatchProtocolErrorCode.sourceUnavailable.safeDisplayMessage)
            case .needsAuth:
                try await fail(&job, class: .needsAuth, code: .authenticationRequired,
                               message: WatchProtocolErrorCode.authenticationRequired.safeDisplayMessage)
            case .cached(let url, let bytes, let sha):
                job.state = .transferring
                job.expectedBytes = bytes
                job.expectedSHA256 = sha ?? job.expectedSHA256
                job.updatedAt = now()
                try await store.upsertJob(job)
                do {
                    try await transfer.transfer(fileURL: url, trackID: WatchTrackID(job.trackID),
                                                expectedBytes: bytes, sha256: sha)
                    job.state = .sent
                    job.failureClass = nil
                    job.errorCode = nil
                    job.message = nil
                    job.updatedAt = now()
                    try await store.upsertJob(job)
                } catch let fault as WatchProtocolFault {
                    try await failFromError(&job, code: fault.code)
                } catch {
                    try await failFromError(&job, code: .transferFailed)
                }
            }
        }
        guard canNetwork else { return }
        await pumpArtwork()
    }

    /// Artwork is dispatched after the audio queue has had its turn. It has no independent job
    /// row because content-addressed IDs plus the watch manifest are the durable dedup truth.
    private func pumpArtwork() async {
        guard await artworkCapability(), let artworkTransfer else { return }
        for trackID in desiredArtworkTrackIDs.sorted() {
            guard let plan = artworkPlans[trackID] else { continue }
            for asset in plan.transfers {
                let normalizedID = asset.artworkID.lowercased()
                guard !artworkSentIDs.contains(normalizedID) else { continue }
                do {
                    try await artworkTransfer.transferArtwork(asset)
                    artworkSentIDs.insert(normalizedID)
                } catch {
                    // The next manifest/reconcile retries a missing asset. A failed artwork
                    // delivery must not poison the independent audio job.
                }
                try? FileManager.default.removeItem(at: asset.fileURL)
            }
        }
    }

    /// Re-attach to in-flight transfers after a relaunch (§8.2). A job the store thinks is
    /// transferring but the framework no longer lists is reset to `queued` for redelivery.
    public func resumeOutstanding() async throws {
        let outstanding = Set(await transfer.outstandingTransfers().map(\.rawValue))
        let jobs = try await store.jobs()
        let stranded = jobs.filter {
            ($0.state == .transferring || $0.state == .resolving) && !outstanding.contains($0.trackID)
        }
        if !stranded.isEmpty {
            try await store.upsertJobs(stranded.map {
                var j = $0; j.state = .queued; j.updatedAt = now(); return j
            })
        }
        try await reconcile()
    }

    // MARK: - Status

    public func statusSnapshot() async throws -> WatchDownloadStatusSnapshot {
        let jobs = try await store.jobs()
        let installed = try await store.installedTrackIDs()
        return WatchDownloadStatusSnapshot(
            revision: try await store.currentRevision(),
            queuedCount: jobs.filter { $0.state == .queued || $0.state == .resolving }.count,
            activeCount: jobs.filter { $0.state == .transferring }.count,
            waitingForWiFiCount: jobs.filter { $0.state == .waitingForWiFi }.count,
            failedCount: jobs.filter { $0.state == .failed }.count,
            readyCount: installed.count)
    }

    /// Bytes still to transfer for desired-but-not-installed tracks.
    public func estimatedRemainingBytes() async throws -> Int64 {
        let installed = try await store.installedTrackIDs()
        return try await store.jobs()
            .filter { $0.state != .sent && $0.state != .cancelled && !installed.contains($0.trackID) }
            .reduce(0) { $0 + ($1.expectedBytes ?? 0) }
    }

    // MARK: - Failure helpers

    private func fail(_ job: inout PhoneWatchDownloadJob, class cls: PhoneWatchFailureClass,
                      code: WatchProtocolErrorCode, message: String) async throws {
        job.state = .failed
        job.failureClass = cls
        job.errorCode = code.rawValue
        job.message = message
        job.attempt += 1
        job.nextAttemptAt = cls.isRetryable
            ? now().addingTimeInterval(PhoneWatchTransferScheduler.backoff(attempt: job.attempt))
            : nil
        job.updatedAt = now()
        try await store.upsertJob(job)
    }

    private func failFromError(_ job: inout PhoneWatchDownloadJob, code: WatchProtocolErrorCode) async throws {
        try await fail(&job, class: PhoneWatchTransferScheduler.classify(code),
                       code: code, message: code.safeDisplayMessage)
    }
}
