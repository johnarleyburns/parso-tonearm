import Foundation
import GRDB
import Testing
import TonearmWatchProtocol
@testable import TonearmCore

// MARK: - Fakes

private actor FakeResolver: PhoneWatchAudioResolving {
    private var resolutions: [String: PhoneWatchAudioResolution] = [:]
    private var transferabilities: [String: PhoneWatchTransferability] = [:]
    private(set) var resolveCounts: [String: Int] = [:]
    private var onResolve: (@Sendable (WatchTrackID) async throws -> Void)?

    init(local: Set<String> = [], bytes: Int64 = 1_000,
         unsupported: Set<String> = [], unavailable: Set<String> = []) {
        for id in local {
            resolutions[id] = .cached(URL(fileURLWithPath: "/tmp/tonearm-test/\(id).caf"),
                                      bytes: bytes, sha256: nil)
            transferabilities[id] = .ready(bytes: bytes, sha256: nil)
        }
        for id in unsupported {
            resolutions[id] = .unsupported(reason: "codec")
            transferabilities[id] = .unsupported(reason: "codec")
        }
        for id in unavailable {
            resolutions[id] = .unavailable
            transferabilities[id] = .unavailable
        }
    }

    func set(_ id: String, resolution: PhoneWatchAudioResolution, transferability: PhoneWatchTransferability) {
        resolutions[id] = resolution
        transferabilities[id] = transferability
    }

    func setOnResolve(_ callback: @escaping @Sendable (WatchTrackID) async throws -> Void) { onResolve = callback }

    func makeAvailable(_ id: String, bytes: Int64 = 1_000) {
        resolutions[id] = .cached(URL(fileURLWithPath: "/tmp/tonearm-test/\(id).caf"), bytes: bytes, sha256: nil)
        transferabilities[id] = .ready(bytes: bytes, sha256: nil)
    }

    func resolve(trackID: WatchTrackID) async -> PhoneWatchAudioResolution {
        resolveCounts[trackID.rawValue, default: 0] += 1
        try? await onResolve?(trackID)
        return resolutions[trackID.rawValue] ?? .unavailable
    }

    func transferability(trackID: WatchTrackID) async -> PhoneWatchTransferability {
        transferabilities[trackID.rawValue] ?? .unavailable
    }

    func resolveCount(_ id: String) -> Int { resolveCounts[id] ?? 0 }
}

private actor FakeTransfer: PhoneWatchFileTransferring {
    private(set) var sent: [String] = []
    private(set) var cancelled: [String] = []
    private var failOnce: Set<String> = []
    private var failAlways: [String: WatchProtocolErrorCode] = [:]
    private var outstanding: [String] = []
    private var onSend: (@Sendable (WatchTrackID) async throws -> Void)?

    func setFailOnce(_ ids: Set<String>) { failOnce = ids }
    func setFailAlways(_ map: [String: WatchProtocolErrorCode]) { failAlways = map }
    func setOutstanding(_ ids: [String]) { outstanding = ids }
    func setOnSend(_ callback: @escaping @Sendable (WatchTrackID) async throws -> Void) { onSend = callback }

    func transfer(fileURL: URL, trackID: WatchTrackID, expectedBytes: Int64, sha256: String?) async throws {
        let id = trackID.rawValue
        if let code = failAlways[id] { throw WatchProtocolFault(code: code) }
        if failOnce.contains(id) { failOnce.remove(id); throw WatchProtocolFault(code: .transferFailed) }
        sent.append(id)
        try await onSend?(trackID)
    }

    func outstandingTransfers() async -> [WatchTrackID] { outstanding.map { WatchTrackID($0) } }
    func cancelTransfer(trackID: WatchTrackID) async {
        cancelled.append(trackID.rawValue)
        outstanding.removeAll { $0 == trackID.rawValue }
    }

    func sentCount(_ id: String) -> Int { sent.filter { $0 == id }.count }
    func sentSorted() -> [String] { sent.sorted() }
    func sentSet() -> Set<String> { Set(sent) }
}

private actor FakeGate: PhoneWatchNetworkGate {
    private var allowed: Bool
    init(_ allowed: Bool = true) { self.allowed = allowed }
    func set(_ value: Bool) { allowed = value }
    func canTransferNow() async -> Bool { allowed }
}

private actor FakeArtworkResolver: PhoneWatchArtworkResolving {
    let resolution: PhoneWatchArtworkResolution
    private(set) var calls = 0

    init(_ resolution: PhoneWatchArtworkResolution) { self.resolution = resolution }
    func resolveArtwork(trackID: WatchTrackID) async -> PhoneWatchArtworkResolution? {
        calls += 1
        return resolution
    }
}

private actor FakeArtworkTransfer: PhoneWatchArtworkTransferring {
    private(set) var sent: [PhoneWatchArtworkTransfer] = []
    func transferArtwork(_ transfer: PhoneWatchArtworkTransfer) async throws { sent.append(transfer) }
}

private final class EmittedRoots: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(roots: [WatchDownloadRootDescriptor], revision: Int64)] = []
    var calls: [(roots: [WatchDownloadRootDescriptor], revision: Int64)] {
        lock.lock(); defer { lock.unlock() }; return _calls
    }
    func record(_ roots: [WatchDownloadRootDescriptor], _ revision: Int64) {
        lock.lock(); _calls.append((roots, revision)); lock.unlock()
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date = Date(timeIntervalSince1970: 10_000)) { current = start }
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current += seconds; lock.unlock() }
}

private actor PlaylistBox {
    private(set) var value: [String]
    init(_ value: [String]) { self.value = value }
    func set(_ value: [String]) { self.value = value }
}

// MARK: - Helpers

private func freshQueue() throws -> DatabaseQueue {
    let queue = try DatabaseQueue()
    try Schema.migrator().migrate(queue)
    return queue
}

private func root(_ id: String, kind: WatchRootKind = .track, tracks: [String],
                  revision: Int64 = 1, createdAt: Date = Date(timeIntervalSince1970: 1)) -> PhoneWatchDownloadRoot {
    PhoneWatchDownloadRoot(rootID: id, kind: kind, sourceID: "src-\(id)", title: id,
                           desiredTrackIDs: tracks, phoneRevision: revision, createdAt: createdAt)
}

private func manifest(_ ids: [String], id: String = UUID().uuidString) -> WatchManifestPayload {
    WatchManifestPayload(manifestID: id, readyTrackIDs: ids.map { WatchTrackID($0) },
                         installedBytes: Int64(ids.count) * 1_000)
}

// MARK: - Tests

@Suite struct PhoneWatchDownloadTests {
    @Test func testFrozenWatchSelectionsAndTrackRemovalDoNotReexpandOrRestartPlaylistAudio() async throws {
        let db = try freshQueue()
        let store = PhoneWatchDownloadStore(dbQueue: db)
        let transfer = FakeTransfer()
        let manager = PhoneWatchDownloadManager(store: store, resolver: FakeResolver(local: ["a", "b", "new"]),
            transfer: transfer, rootExpander: { _ in Issue.record("Frozen phone selection must not reexpand"); return ["a", "b", "new"] },
            keepsPlaylistsLive: false)
        try await manager.setRoots([root("playlist", kind: .playlist, tracks: ["a", "b"]), root("single", tracks: ["a"])])
        await transfer.setOutstanding(["a", "b"])
        try await manager.removeTracks(["a"])
        try await manager.tick()
        let roots = try await store.roots()
        #expect(roots.count == 1)
        #expect(roots.first?.desiredTrackIDs == ["b"])
        let sent = await transfer.sentSet()
        #expect(!sent.contains("new"))
        let count = await transfer.sentCount("a")
        #expect(count == 1, "Removed audio must not silently redownload through a playlist")
        let cancelled = await transfer.cancelled
        #expect(cancelled.contains("a"))
    }
    @Test func testMetadataOnlyManifestIngestDoesNotStartQueuedAudio() async throws {
        let db = try freshQueue()
        let store = PhoneWatchDownloadStore(dbQueue: db)
        let transfer = FakeTransfer()
        let manager = makeManager(dbQueue: db, resolver: FakeResolver(local: ["queued"]), transfer: transfer)
        try await store.upsertRoot(root("r", tracks: ["queued"]))
        try await store.upsertJob(PhoneWatchDownloadJob(trackID: "queued", rootIDs: ["r"]))
        try await manager.ingestManifest(manifest([]), reconcileDownloads: false)
        let sends = await transfer.sent
        #expect(sends.isEmpty)
        let jobs = try await store.jobs()
        #expect(jobs.first?.state == .queued)
    }
    @Test func testLostInstalledAudioAsksForApprovalInsteadOfAutomaticallyDownloadingAgain() async throws {
        let db = try freshQueue()
        let transfer = FakeTransfer()
        let manager = makeManager(dbQueue: db, resolver: FakeResolver(local: ["lost"]), transfer: transfer)
        try await manager.setRoots([root("r", tracks: ["lost"])])
        try await manager.ingestManifest(manifest(["lost"]))
        try await manager.ingestManifest(manifest([]))
        try await manager.tick()
        let count = await transfer.sentCount("lost")
        #expect(count == 1)
        let store = PhoneWatchDownloadStore(dbQueue: db)
        let job = try await store.jobs().first
        #expect(job?.state == .failed)
        #expect(job?.nextAttemptAt == nil)
    }
    @Test func testAppleOwnedWholeFilePromptsAtTwentyFourHoursWithoutReenqueueing() async throws {
        let db = try freshQueue()
        let store = PhoneWatchDownloadStore(dbQueue: db)
        let clock = TestClock()
        let transfer = FakeTransfer()
        let manager = makeManager(dbQueue: db, resolver: FakeResolver(local: ["whole"]), transfer: transfer, clock: clock)
        try await manager.setRoots([root("r", tracks: ["whole"])])
        await transfer.setOutstanding(["whole"])
        clock.advance(86_399)
        try await manager.tick()
        let before = try await store.jobs().first
        #expect(before?.state == .sent)
        clock.advance(2)
        try await manager.tick()
        let expired = try await store.jobs().first
        #expect(expired?.state == .failed)
        #expect(expired?.message?.contains("Retry this transfer?") ?? false)
        #expect(expired?.nextAttemptAt == nil)
        let count = await transfer.sentCount("whole")
        #expect(count == 1)
        try await manager.requestRetry(requestID: try #require(expired?.requestID))
        let approved = await transfer.sentCount("whole")
        #expect(approved == 2)
        let cancelled = await transfer.cancelled
        #expect(cancelled == ["whole"], "Only explicit consent cancels Apple's old file transfer")
    }
    @Test func testIsStalledOnlyAfterThresholdWithoutProgress() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        #expect(!PhoneWatchTransferScheduler.isStalled(lastProgressAt: t0, now: t0))
        #expect(PhoneWatchTransferScheduler.isStalled(
            lastProgressAt: t0, now: t0.addingTimeInterval(PhoneWatchTransferScheduler.stallThreshold + 1)))
    }

    @Test func testFrozenFractionSurfacesStalledAndRetryCancelsStaleTransfer() async throws {
        let db = try freshQueue()
        let clock = TestClock()
        let transfer = FakeTransfer()
        let manager = makeManager(dbQueue: db, resolver: FakeResolver(local: ["fred"]), transfer: transfer, clock: clock)
        try await manager.setRoots([root("r", tracks: ["fred"])])
        await transfer.setOutstanding(["fred"])
        var snap = try await manager.statusSnapshot(transferFractions: ["fred": 0.4])
        #expect(snap.activities.first?.stage != .stalled)
        clock.advance(PhoneWatchTransferScheduler.stallThreshold - 10)
        snap = try await manager.statusSnapshot(transferFractions: ["fred": 0.4])
        #expect(snap.activities.first?.stage != .stalled)
        clock.advance(20)
        snap = try await manager.statusSnapshot(transferFractions: ["fred": 0.4])
        #expect(snap.activities.first?.stage == .stalled)
        try await manager.requestRetry(trackID: "fred")
        let cancelled = await transfer.cancelled
        #expect(cancelled == ["fred"])
    }

    @Test func testPauseAndRemoveCancelSystemOwnedFilesAndResumeQueuesOneReplacement() async throws {
        let db = try freshQueue()
        let transfer = FakeTransfer()
        let manager = makeManager(dbQueue: db, resolver: FakeResolver(local: ["fred"]), transfer: transfer)
        try await manager.setRoots([root("r", tracks: ["fred"])])
        await transfer.setOutstanding(["fred"])
        try await manager.pauseRoot(rootID: "r")
        let cancelled = await transfer.cancelled
        #expect(cancelled == ["fred"])
        try await manager.resumeRoot(rootID: "r")
        let sent = await transfer.sentCount("fred")
        #expect(sent == 2)
        await transfer.setOutstanding(["fred"])
        try await manager.removeRoot(rootID: "r")
        let removed = await transfer.cancelled
        #expect(removed == ["fred", "fred"])
        let outstanding = await transfer.outstandingTransfers()
        #expect(outstanding.isEmpty, "Removed roots must not occupy all scheduler slots forever")
    }

    @Test func testLongTransferStartsPersistedAcknowledgementClockAtDeliveryNotEnqueue() async throws {
        let db = try freshQueue()
        let store = PhoneWatchDownloadStore(dbQueue: db)
        let clock = TestClock()
        let transfer = FakeTransfer()
        let resolver = FakeResolver(local: ["fred"])
        let manager = makeManager(dbQueue: db, resolver: resolver, transfer: transfer, clock: clock)
        try await manager.setRoots([root("r", tracks: ["fred"])])
        await transfer.setOutstanding(["fred"])
        clock.advance(1800)
        try await manager.tick()
        await transfer.setOutstanding([])
        try await manager.transferDelivered(trackID: "fred")
        try await manager.tick()
        let delivered = try await store.jobs().first
        #expect(delivered?.state == .sent)
        #expect(delivered?.deliveryCompletedAt == clock.now)
        let restored = makeManager(dbQueue: db, resolver: resolver, transfer: transfer, clock: clock)
        clock.advance(60)
        try await restored.resumeOutstanding()
        let count = await transfer.sentCount("fred")
        #expect(count == 1, "A relaunch during installation grace must not send another large file")
        try await restored.ingestManifest(manifest(["fred"]))
        clock.advance(600)
        try await restored.tick()
        let finalCount = await transfer.sentCount("fred")
        #expect(finalCount == 1)
    }

    @Test func testV32PreservesExistingJobsAndAddsUnknownDeliveryTime() async throws {
        let queue = try DatabaseQueue()
        try Schema.migrator(upTo: "v31").migrate(queue)
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO watchDownloadJob (requestID, trackID, rootIDs, priority, state, attempt, createdAt, updatedAt)
                VALUES ('old', 'fred', '["r"]', 2, 'sent', 3, '2026-01-01 00:00:00.000', '2026-01-01 00:00:00.000')
                """)
        }
        try Schema.migrator().migrate(queue)
        let store = PhoneWatchDownloadStore(dbQueue: queue)
        let jobs = try await store.jobs()
        #expect(jobs.first?.trackID == "fred")
        #expect(jobs.first?.attempt == 3)
        #expect(jobs.first?.deliveryCompletedAt == nil)
    }

    @Test func testExplicitRestartCancelsOutstandingTransferBeforeOneReplacement() async throws {
        let db = try freshQueue()
        let transfer = FakeTransfer()
        let manager = makeManager(dbQueue: db, resolver: FakeResolver(local: ["fred"]), transfer: transfer)
        let store = PhoneWatchDownloadStore(dbQueue: db)
        try await manager.setRoots([root("r", tracks: ["fred"])])
        await transfer.setOutstanding(["fred"])
        let jobs = try await store.jobs()
        let job = try #require(jobs.first)
        try await manager.requestRetry(requestID: job.requestID)
        let cancelled = await transfer.cancelled
        let count = await transfer.sentCount("fred")
        #expect(cancelled == ["fred"])
        #expect(count == 2, "The original transfer and exactly one replacement")
    }

    @Test func testSystemOwnedTransfersConsumeSchedulerSlotsUntilTheyFinish() {
        let jobs = (0..<4).map { i in PhoneWatchDownloadJob(trackID: "t\(i)", rootIDs: ["r"], state: .queued) }
        #expect(PhoneWatchTransferScheduler.nextDispatch(jobs: jobs, now: Date(),
            canTransferOnNetwork: true, outstandingTrackIDs: ["sentA", "sentB"]).isEmpty)
        #expect(PhoneWatchTransferScheduler.nextDispatch(jobs: jobs, now: Date(),
            canTransferOnNetwork: true, outstandingTrackIDs: ["sentA"]).count == 1)
    }
    @Test func testUnconfirmedSentDownloadCanBeCancelledButInstalledAudioCannot() async throws {
        let db = try freshQueue()
        let store = PhoneWatchDownloadStore(dbQueue: db)
        let transfer = FakeTransfer()
        let manager = makeManager(dbQueue: db, resolver: FakeResolver(local: ["a", "b"]), transfer: transfer)
        try await manager.setRoots([root("r", tracks: ["a", "b"])])
        let jobs = try await store.jobs()
        let pending = try #require(jobs.first { $0.trackID == "a" })
        let ready = try #require(jobs.first { $0.trackID == "b" })
        #expect(pending.state == .sent)
        try await manager.ingestManifest(manifest(["b"]))
        // A late persisted job must not cancel a transfer for already installed audio.
        try await store.upsertJob(ready)
        try await manager.cancelJob(requestID: ready.requestID)
        let settled = try await store.jobs()
        #expect(settled.first { $0.trackID == "b" }?.state == .sent)
        try await manager.cancelJob(requestID: pending.requestID)
        let cancelled = await transfer.cancelled
        #expect(cancelled == ["a"])
        let after = try await store.jobs()
        #expect(after.first { $0.trackID == "a" }?.state == .cancelled)
        let installed = try await store.installedTrackIDs()
        #expect(installed == ["b"])
    }

    @Test func testQueuedFilesAndUnconfirmedInstallationsRemainVisibleUntilWatchReportsReady() async throws {
        let db = try freshQueue()
        let transfer = FakeTransfer()
        let manager = makeManager(dbQueue: db, resolver: FakeResolver(local: ["a"]), transfer: transfer)
        try await manager.setRoots([root("r", tracks: ["a"])])
        await transfer.setOutstanding(["a"])
        let queued = try await manager.statusSnapshot(transferFractions: ["a": 0])
        #expect(queued.activities.first?.stage == .waitingForDelivery)
        #expect(!queued.isIdle)
        #expect(queued.readyCount == 0)
        let moving = try await manager.statusSnapshot(transferFractions: ["a": 0.5])
        #expect(moving.activities.first?.stage == .transferring)
        #expect(moving.activeCount == 1)
        await transfer.setOutstanding([])
        let unconfirmed = try await manager.statusSnapshot()
        #expect(unconfirmed.activities.first?.stage == .awaitingInstallation)
        #expect(!unconfirmed.isIdle)
        try await manager.ingestManifest(manifest(["a"]))
        let installed = try await manager.statusSnapshot()
        #expect(installed.activities.isEmpty)
        #expect(installed.readyCount == 1)
        #expect(installed.isIdle)
    }

    @Test func testCancellationDuringPreparationDoesNotEnqueueAudio() async throws {
        let db = try freshQueue()
        let store = PhoneWatchDownloadStore(dbQueue: db)
        let transfer = FakeTransfer()
        let resolver = FakeResolver(local: ["a"])
        let manager = makeManager(dbQueue: db, resolver: resolver, transfer: transfer)
        await resolver.setOnResolve { [weak manager] _ in
            if let requestID = try await store.jobs().first?.requestID {
                try await manager?.cancelJob(requestID: requestID)
            }
        }
        try await manager.setRoots([root("r", tracks: ["a"])])
        let job = try await store.jobs().first
        let sent = await transfer.sent
        #expect(job?.state == .cancelled)
        #expect(sent.isEmpty, "Stopping a download during file conversion must prevent delivery")
    }

    @Test func testDeliveryFailureDuringEnqueueSchedulesAutomaticRetry() async throws {
        let db = try freshQueue()
        let store = PhoneWatchDownloadStore(dbQueue: db)
        let transfer = FakeTransfer()
        let manager = makeManager(dbQueue: db, resolver: FakeResolver(local: ["a"]), transfer: transfer)
        await transfer.setOnSend { [weak manager] trackID in
            try await manager?.transferFailed(trackID: trackID, code: .transferFailed)
        }
        try await manager.setRoots([root("r", tracks: ["a"])])
        let job = try await store.jobs().first
        #expect(job?.state == .queued)
        #expect(job?.failureClass == .transient)
        #expect(job?.nextAttemptAt != nil)
    }

    @Test func testAsynchronousDeliveryFailureRetriesWithBackoff() async throws {
        let db = try freshQueue()
        let store = PhoneWatchDownloadStore(dbQueue: db)
        let clock = TestClock()
        let transfer = FakeTransfer()
        let manager = makeManager(dbQueue: db, resolver: FakeResolver(local: ["a"]),
                                  transfer: transfer, clock: clock)
        try await manager.setRoots([root("r", tracks: ["a"])])
        try await manager.transferFailed(trackID: "a", code: .transferFailed)
        let retrying = try await store.jobs().first
        #expect(retrying?.state == .queued)
        #expect(retrying?.failureClass == .transient)
        #expect(retrying?.nextAttemptAt == clock.now.addingTimeInterval(5))
        try await manager.tick()
        let beforeRetry = await transfer.sentCount("a")
        #expect(beforeRetry == 1)
        clock.advance(6)
        try await manager.tick()
        let afterRetry = await transfer.sentCount("a")
        #expect(afterRetry == 2)
        try await manager.ingestManifest(manifest(["a"]))
        try await manager.transferFailed(trackID: "a", code: .transferFailed)
        clock.advance(600)
        try await manager.tick()
        let afterInstall = await transfer.sentCount("a")
        #expect(afterInstall == 2, "late delivery errors must not retry installed audio")
    }

    @Test func testMissingInstallAcknowledgementRecoversWithoutDuplicatingOutstandingTransfer() async throws {
        let db = try freshQueue()
        let store = PhoneWatchDownloadStore(dbQueue: db)
        let clock = TestClock()
        let transfer = FakeTransfer()
        let manager = makeManager(dbQueue: db, resolver: FakeResolver(local: ["a"]),
                                  transfer: transfer, clock: clock)
        try await manager.setRoots([root("r", tracks: ["a"])])
        await transfer.setOutstanding(["a"])
        clock.advance(600)
        try await manager.ingestManifest(manifest([]))
        try await manager.requestRetry(trackID: "a")
        let outstandingCount = await transfer.sentCount("a")
        #expect(outstandingCount == 1)
        await transfer.setOutstanding([])
        try await manager.tick()
        let awaiting = try await store.jobs().first
        #expect(awaiting?.state == .sent, "A long queue wait must not consume installation grace")
        clock.advance(PhoneWatchDownloadManager.installationAcknowledgementTimeout + 1)
        try await manager.tick()
        let failed = try await store.jobs().first
        #expect(failed?.state == .failed)
        clock.advance(6)
        try await manager.tick()
        let recoveredCount = await transfer.sentCount("a")
        #expect(recoveredCount == 1)
        #expect(failed?.nextAttemptAt == nil)
        try await manager.requestRetry(requestID: try #require(failed?.requestID))
        try await manager.ingestManifest(manifest(["a"]))
        clock.advance(600)
        try await manager.tick()
        let installedCount = await transfer.sentCount("a")
        #expect(installedCount == 2)
    }

    @Test func testExplicitRetryRevivesUnconfirmedSentJob() {
        let job = PhoneWatchDownloadJob(trackID: "a", rootIDs: ["r"], state: .sent)
        let plan = PhoneWatchDownloadPlanner.plan(
            roots: [root("r", tracks: ["a"])], installedTrackIDs: [], existingJobs: [job],
            transferability: { _ in .ready(bytes: 100, sha256: nil) },
            explicitRetryTrackIDs: ["a"])
        #expect(plan.toReset == [job.requestID])
        #expect(plan.toCreate.isEmpty)
    }


    // MARK: schema

    @Test func testV15CreatesDownloadTables() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator(upTo: "v14").migrate(queue)
        try Schema.migrator().migrate(queue)
        try queue.read { db in
            for table in ["watchDownloadRoot", "watchDownloadJob",
                          "watchDownloadManifestEntry", "watchDownloadRevision"] {
                let exists = try db.tableExists(table)
                #expect(exists, "\(table) missing")
            }
            let seed = try Int64.fetchOne(db, sql: "SELECT value FROM watchDownloadRevision WHERE id = 1")
            #expect(seed == 0)
        }
    }

    @Test func testV17DropsLegacyWatchTransferTables() throws {
        // Phase 10 (§10): the pre-cutover v12 `watchTransfer` / `watchManifest` tables are
        // dropped once the v15 download-root stack is in place. Nothing reads them any more.
        let queue = try freshQueue()
        try queue.read { db in
            let hasWatchTransfer = try db.tableExists("watchTransfer")
            let hasWatchManifest = try db.tableExists("watchManifest")
            #expect(!hasWatchTransfer)
            #expect(!hasWatchManifest)
        }
    }

    // MARK: store round-trips

    @Test func testStoreRootAndJobRoundTrip() async throws {
        let store = PhoneWatchDownloadStore(dbQueue: try freshQueue())
        try await store.replaceRoots([root("r1", tracks: ["a", "b"])])
        let roots = try await store.roots()
        #expect(roots.map(\.rootID) == ["r1"])
        #expect(roots.first?.desiredTrackIDs == ["a", "b"])

        var job = PhoneWatchDownloadJob(trackID: "a", rootIDs: ["r1"], expectedBytes: 42)
        try await store.upsertJob(job)
        job.state = .sent
        try await store.upsertJob(job)
        let jobs = try await store.jobs()
        #expect(jobs.count == 1)
        #expect(jobs.first?.state == .sent)
        #expect(jobs.first?.expectedBytes == 42)
    }

    @Test func testBumpRevisionMonotonic() async throws {
        let store = PhoneWatchDownloadStore(dbQueue: try freshQueue())
        let start = try await store.currentRevision()
        #expect(start == 0)
        let first = try await store.bumpRevision()
        #expect(first == 1)
        let second = try await store.bumpRevision()
        #expect(second == 2)
        let current = try await store.currentRevision()
        #expect(current == 2)
    }

    // MARK: planner

    @Test func testPlannerDedupesSharedReferences() {
        let plan = PhoneWatchDownloadPlanner.plan(
            roots: [root("r1", tracks: ["a", "b"]), root("r2", kind: .playlist, tracks: ["b", "c"])],
            installedTrackIDs: [], existingJobs: [],
            transferability: { _ in .ready(bytes: 100, sha256: nil) })
        #expect(Set(plan.toCreate.map(\.trackID)) == ["a", "b", "c"])
        #expect(plan.referenceCounts["b"] == 2)
        #expect(plan.toCreate.first { $0.trackID == "b" }?.priority == .trackOrAlbumBatch)
    }

    @Test func testPlannerSkipsInstalledAndUnsupported() {
        let plan = PhoneWatchDownloadPlanner.plan(
            roots: [root("r1", tracks: ["installed", "bad", "ok"])],
            installedTrackIDs: ["installed"], existingJobs: [],
            transferability: {
                switch $0 {
                case "bad": return .unsupported(reason: "codec")
                default: return .ready(bytes: 1, sha256: nil)
                }
            })
        #expect(plan.toCreate.map(\.trackID) == ["ok"])
        #expect(plan.unsupported == ["bad"])
    }

    @Test func testPlannerQueuesRemoteTrackWhenResolverCanMaterializeIt() {
        // A remote track does not need to be cached on the phone before it is requested from the
        // watch. The app resolver materializes it during dispatch; the planner must therefore
        // preserve the job instead of classifying a streaming-only row as unavailable.
        let plan = PhoneWatchDownloadPlanner.plan(
            roots: [root("remote", tracks: ["streaming-only"])],
            installedTrackIDs: [], existingJobs: [],
            transferability: { id in
                #expect(id == "streaming-only")
                return .ready(bytes: 12_345, sha256: nil)
            })

        #expect(plan.unavailable == [])
        #expect(plan.toCreate.map(\.trackID) == ["streaming-only"])
        #expect(plan.toCreate.first?.expectedBytes == 12_345)
    }

    @Test func testPlannerCancelsUndesiredActiveJobs() {
        let existing = [PhoneWatchDownloadJob(trackID: "gone", rootIDs: ["r1"], state: .transferring)]
        let plan = PhoneWatchDownloadPlanner.plan(
            roots: [root("r1", tracks: ["kept"])],
            installedTrackIDs: [], existingJobs: existing,
            transferability: { _ in .ready(bytes: 1, sha256: nil) })
        #expect(plan.toCancel == [existing[0].requestID])
        #expect(plan.toCreate.map(\.trackID) == ["kept"])
    }

    // MARK: scheduler

    @Test func testSchedulerRespectsAudioCap() {
        let jobs = (0..<5).map { PhoneWatchDownloadJob(trackID: "t\($0)", rootIDs: ["r"], state: .queued,
                                                       createdAt: Date(timeIntervalSince1970: Double($0))) }
        let picked = PhoneWatchTransferScheduler.nextDispatch(jobs: jobs, now: Date(), canTransferOnNetwork: true)
        #expect(picked.count == PhoneWatchTransferScheduler.maxAudioInFlight)
    }

    @Test func testSchedulerHoldsBackoffJobs() {
        let future = Date().addingTimeInterval(120)
        let jobs = [PhoneWatchDownloadJob(trackID: "t", rootIDs: ["r"], state: .queued, nextAttemptAt: future)]
        let picked = PhoneWatchTransferScheduler.nextDispatch(jobs: jobs, now: Date(), canTransferOnNetwork: true)
        #expect(picked.isEmpty)
    }

    @Test func testSchedulerBackoffIsBoundedAndExponential() {
        #expect(PhoneWatchTransferScheduler.backoff(attempt: 1) == 5)
        #expect(PhoneWatchTransferScheduler.backoff(attempt: 2) == 10)
        #expect(PhoneWatchTransferScheduler.backoff(attempt: 3) == 20)
        #expect(PhoneWatchTransferScheduler.backoff(attempt: 99) == 300)
    }

    @Test func testSchedulerClassifyNeverPermanentByOmission() {
        #expect(PhoneWatchTransferScheduler.classify(nil) == .transient)
        #expect(PhoneWatchTransferScheduler.classify(.transferFailed) == .transient)
        #expect(PhoneWatchTransferScheduler.classify(.authenticationRequired) == .needsAuth)
        #expect(PhoneWatchTransferScheduler.classify(.sourceUnavailable) == .sourceUnavailable)
        #expect(PhoneWatchTransferScheduler.classify(.unsupportedAudio) == .fileUnsupported)
    }

    // MARK: manager builder

    private func makeManager(dbQueue: DatabaseQueue, resolver: FakeResolver, transfer: FakeTransfer,
                             gate: FakeGate = FakeGate(true), emitted: EmittedRoots = EmittedRoots(),
                             clock: TestClock = TestClock(),
                             expander: (@Sendable (PhoneWatchDownloadRoot) async -> [String])? = nil)
        -> PhoneWatchDownloadManager {
        PhoneWatchDownloadManager(
            store: PhoneWatchDownloadStore(dbQueue: dbQueue),
            resolver: resolver, transfer: transfer, networkGate: gate,
            emitRoots: { roots, rev in emitted.record(roots, rev) },
            rootExpander: expander ?? { $0.desiredTrackIDs },
            now: { clock.now })
    }

    // MARK: manager — happy paths

    @Test func testSetRootsTransfersEachTrackOnce() async throws {
        let db = try freshQueue()
        let resolver = FakeResolver(local: ["a", "b", "c"])
        let transfer = FakeTransfer()
        let manager = makeManager(dbQueue: db, resolver: resolver, transfer: transfer)

        try await manager.setRoots([root("r1", tracks: ["a", "b"]),
                                    root("r2", kind: .playlist, tracks: ["b", "c"])])

        let sent = await transfer.sentSet()
        #expect(sent == ["a", "b", "c"])
        let sharedCount = await transfer.sentCount("b")
        #expect(sharedCount == 1)
        let resolveCount = await resolver.resolveCount("b")
        #expect(resolveCount == 1)
    }

    @Test func testDesiredDownloadResolvesAndTransfersDerivativeArtworkWithBindings() async throws {
        let db = try freshQueue()
        let resolver = FakeResolver(local: ["a"])
        let transfer = FakeTransfer()
        let artworkFile = FileManager.default.temporaryDirectory.appendingPathComponent("watch-art-test.jpg")
        try Data("derivative".utf8).write(to: artworkFile, options: .atomic)
        let artwork = PhoneWatchArtworkTransfer(fileURL: artworkFile, artworkID: String(repeating: "a", count: 64),
                                                 role: .cover, expectedBytes: 10,
                                                 sha256: String(repeating: "a", count: 64))
        let artworkResolver = FakeArtworkResolver(.init(coverArtworkID: artwork.artworkID,
                                                        transfers: [artwork]))
        let artworkTransfer = FakeArtworkTransfer()
        let bindings = PhoneWatchArtworkBindingRegistry()
        let manager = PhoneWatchDownloadManager(
            store: PhoneWatchDownloadStore(dbQueue: db), resolver: resolver, transfer: transfer,
            artworkResolver: artworkResolver, artworkTransfer: artworkTransfer,
            publishArtworkBindings: { trackID, cover, custom in
                await bindings.set(trackID: trackID, coverArtworkID: cover, customArtworkID: custom)
            })

        try await manager.setRoots([root("art", tracks: ["a"])])
        let sentArtworkIDs = await artworkTransfer.sent.map(\.artworkID)
        let binding = await bindings.binding(for: "a")
        #expect(sentArtworkIDs == [artwork.artworkID])
        #expect(binding.coverArtworkID == artwork.artworkID)
    }

    @Test func testMissingArtworkInManifestIsResentOnReconcile() async throws {
        let db = try freshQueue()
        let audioResolver = FakeResolver(local: ["a"])
        let audioTransfer = FakeTransfer()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("watch-art-resend.jpg")
        try Data("derivative".utf8).write(to: file, options: .atomic)
        let id = String(repeating: "b", count: 64)
        let artworkResolver = FakeArtworkResolver(.init(coverArtworkID: id,
                                                        transfers: [.init(fileURL: file, artworkID: id,
                                                                          role: .cover, expectedBytes: 10, sha256: id)]))
        let artworkTransfer = FakeArtworkTransfer()
        let manager = PhoneWatchDownloadManager(
            store: PhoneWatchDownloadStore(dbQueue: db), resolver: audioResolver, transfer: audioTransfer,
            artworkResolver: artworkResolver, artworkTransfer: artworkTransfer)
        try await manager.setRoots([root("resend", tracks: ["a"])])
        let firstSendCount = await artworkTransfer.sent.count
        #expect(firstSendCount == 1)
        try await manager.ingestManifest(.init(manifestID: "missing", readyTrackIDs: [], installedBytes: 0,
                                               installedArtworkIDs: []))
        let resendCount = await artworkTransfer.sent.count
        #expect(resendCount == 2)
    }

    @Test func testArtworkPlanningAndTransferRespectCapabilityAndNetworkGates() async throws {
        let db = try freshQueue()
        let audioResolver = FakeResolver(local: ["a"])
        let audioTransfer = FakeTransfer()
        let artworkID = String(repeating: "f", count: 64)
        let artworkURL = FileManager.default.temporaryDirectory.appendingPathComponent("gated-artwork.jpg")
        try Data("artwork".utf8).write(to: artworkURL, options: .atomic)
        let artworkResolver = FakeArtworkResolver(.init(
            coverArtworkID: artworkID,
            transfers: [.init(fileURL: artworkURL, artworkID: artworkID, role: .cover,
                               expectedBytes: 7, sha256: artworkID)]))
        let artworkTransfer = FakeArtworkTransfer()
        let gate = FakeGate(false)
        let manager = PhoneWatchDownloadManager(
            store: PhoneWatchDownloadStore(dbQueue: db), resolver: audioResolver, transfer: audioTransfer,
            networkGate: gate, artworkResolver: artworkResolver, artworkTransfer: artworkTransfer,
            artworkCapability: { false })

        try await manager.setRoots([root("gated", tracks: ["a"])])
        let resolverCallsWithoutCapability = await artworkResolver.calls
        let sentWithoutCapability = await artworkTransfer.sent.count
        #expect(resolverCallsWithoutCapability == 0)
        #expect(sentWithoutCapability == 0)

        let networked = FakeGate(true)
        let networkManager = PhoneWatchDownloadManager(
            store: PhoneWatchDownloadStore(dbQueue: try freshQueue()), resolver: FakeResolver(local: ["a"]),
            transfer: FakeTransfer(), networkGate: networked, artworkResolver: artworkResolver,
            artworkTransfer: artworkTransfer, artworkCapability: { true })
        try await networkManager.setRoots([root("networked", tracks: ["a"])])
        let resolverCallsWithNetwork = await artworkResolver.calls
        let sentWithNetwork = await artworkTransfer.sent.count
        #expect(resolverCallsWithNetwork == 1)
        #expect(sentWithNetwork == 1)
    }

    @Test func testSetRootsEmitsDescriptorsWithBumpedRevision() async throws {
        let db = try freshQueue()
        let emitted = EmittedRoots()
        let manager = makeManager(dbQueue: db, resolver: FakeResolver(local: ["a"]),
                                  transfer: FakeTransfer(), emitted: emitted)
        try await manager.setRoots([root("r1", tracks: ["a"])])
        #expect(emitted.calls.count == 1)
        #expect(emitted.calls[0].revision == 1)
        #expect(emitted.calls[0].roots.map { $0.rootID.rawValue } == ["r1"])
        #expect(emitted.calls[0].roots[0].trackIDs.map(\.rawValue) == ["a"])
    }

    @Test func testUnavailableTrackIsNotTransferredAndStaysDesired() async throws {
        let db = try freshQueue()
        let resolver = FakeResolver(local: ["a"], unavailable: ["b"])
        let transfer = FakeTransfer()
        let manager = makeManager(dbQueue: db, resolver: resolver, transfer: transfer)

        try await manager.setRoots([root("r1", tracks: ["a", "b"])])
        let afterFirst = await transfer.sent
        #expect(afterFirst == ["a"])

        await resolver.makeAvailable("b")
        try await manager.tick()
        let afterConverge = await transfer.sentSet()
        #expect(afterConverge == ["a", "b"])
        let aCount = await transfer.sentCount("a")
        #expect(aCount == 1)
    }

    @Test func testUnsupportedTrackNeverCreatesAJob() async throws {
        let db = try freshQueue()
        let store = PhoneWatchDownloadStore(dbQueue: db)
        let transfer = FakeTransfer()
        let manager = makeManager(dbQueue: db, resolver: FakeResolver(local: ["a"], unsupported: ["b"]),
                                  transfer: transfer)
        try await manager.setRoots([root("r1", tracks: ["a", "b"])])
        let jobs = try await store.jobs()
        #expect(jobs.map(\.trackID) == ["a"])
        let sent = await transfer.sent
        #expect(sent == ["a"])
    }

    // MARK: manager — Wi-Fi gate

    @Test func testWaitingForWiFiThenResumes() async throws {
        let db = try freshQueue()
        let gate = FakeGate(false)
        let transfer = FakeTransfer()
        let manager = makeManager(dbQueue: db, resolver: FakeResolver(local: ["a", "b"]),
                                  transfer: transfer, gate: gate)

        try await manager.setRoots([root("r1", tracks: ["a", "b"])])
        let stalled = await transfer.sent
        #expect(stalled.isEmpty)
        let waiting = try await manager.statusSnapshot()
        #expect(waiting.waitingForWiFiCount == 2)

        await gate.set(true)
        try await manager.tick()
        let resumed = await transfer.sentSet()
        #expect(resumed == ["a", "b"])
        let after = try await manager.statusSnapshot()
        #expect(after.waitingForWiFiCount == 0)
    }

    // MARK: manager — cancellation & divergence

    @Test func testRemovingARootCancelsItsInFlightJob() async throws {
        let db = try freshQueue()
        let store = PhoneWatchDownloadStore(dbQueue: db)
        try await store.replaceRoots([root("r1", tracks: ["a"])])
        try await store.upsertJob(PhoneWatchDownloadJob(trackID: "a", rootIDs: ["r1"], state: .transferring))
        let transfer = FakeTransfer()
        let manager = makeManager(dbQueue: db, resolver: FakeResolver(local: ["a"]), transfer: transfer)

        try await manager.removeRoot(rootID: "r1")
        let cancelled = await transfer.cancelled
        #expect(cancelled == ["a"])
        // The job is cancelled and, its track no longer wanted, pruned in the same pass.
        let active = try await store.activeJobs()
        #expect(active.isEmpty)
    }

    @Test func testManifestArrivalConvergesAndStopsWork() async throws {
        let db = try freshQueue()
        let resolver = FakeResolver(local: ["a", "b", "c"])
        let transfer = FakeTransfer()
        let manager = makeManager(dbQueue: db, resolver: resolver, transfer: transfer)
        try await manager.setRoots([root("r1", tracks: ["a", "b", "c"])])

        try await manager.ingestManifest(manifest(["a", "b", "c"]))
        let snap = try await manager.statusSnapshot()
        #expect(snap.isIdle)
        #expect(snap.readyCount == 3)
        let remaining = try await manager.estimatedRemainingBytes()
        #expect(remaining == 0)

        try await manager.tick()
        let sent = await transfer.sentSorted()
        #expect(sent == ["a", "b", "c"])
    }

    @Test func testWatchStoreResetDoesNotAutomaticallyRequeueDroppedTracks() async throws {
        let db = try freshQueue()
        let resolver = FakeResolver(local: ["a", "b"])
        let transfer = FakeTransfer()
        let manager = makeManager(dbQueue: db, resolver: resolver, transfer: transfer)
        try await manager.setRoots([root("r1", tracks: ["a", "b"])])
        try await manager.ingestManifest(manifest(["a", "b"]))
        let afterFirst = await transfer.sent
        #expect(afterFirst.count == 2)

        try await manager.ingestManifest(manifest([]))
        let afterReset = await transfer.sentSorted()
        #expect(afterReset == ["a", "b"])
    }

    @Test func testManifestReadyForUndesiredTrackIsHonoured() async throws {
        let db = try freshQueue()
        let transfer = FakeTransfer()
        let manager = makeManager(dbQueue: db, resolver: FakeResolver(local: ["a"]), transfer: transfer)
        try await manager.setRoots([root("r1", tracks: ["a"])])
        try await manager.ingestManifest(manifest(["a", "legacy"]))
        let snap = try await manager.statusSnapshot()
        #expect(snap.readyCount == 2)
        #expect(snap.isIdle)
        let sent = await transfer.sent
        #expect(sent == ["a"])
    }

    // MARK: manager — retry classes

    @Test func testAllTracksMissingOnWatchAfterCatalogRebuildAreResentOnReconcile() async throws {
        let db = try freshQueue()
        let store = PhoneWatchDownloadStore(dbQueue: db)
        let clock = TestClock()
        let transfer = FakeTransfer()
        await transfer.setFailAlways(["a": .transferFailed, "b": .transferFailed])
        let manager = makeManager(dbQueue: db, resolver: FakeResolver(local: ["a", "b"]),
                                  transfer: transfer, clock: clock)
        try await manager.setRoots([root("r1", tracks: ["a", "b"])])
        for _ in 0..<3 { clock.advance(10); try await manager.tick() }
        let exhausted = try await store.jobs()
        #expect(exhausted.count == 2)
        #expect(exhausted.allSatisfy { $0.state == .failed })

        await transfer.setFailAlways([:])
        try await manager.ingestManifest(manifest([]))
        let sent = await transfer.sent
        #expect(Set(sent) == ["a", "b"])
    }

    @Test func testTransientFailureRetriesThreeTimesThenRequiresUserApproval() async throws {
        let db = try freshQueue()
        let store = PhoneWatchDownloadStore(dbQueue: db)
        let clock = TestClock()
        let transfer = FakeTransfer()
        await transfer.setFailAlways(["a": .transferFailed])
        let manager = makeManager(dbQueue: db, resolver: FakeResolver(local: ["a"]),
                                  transfer: transfer, clock: clock)

        try await manager.setRoots([root("r1", tracks: ["a"])])
        let stalled = await transfer.sent
        #expect(stalled.isEmpty)
        let failed = try await store.jobs().first
        #expect(failed?.state == .queued)
        #expect(failed?.failureClass == .transient)
        #expect(failed?.attempt == 1)
        #expect(failed?.nextAttemptAt == clock.now.addingTimeInterval(5))

        try await manager.tick()
        let stillStalled = await transfer.sent
        #expect(stillStalled.isEmpty)

        clock.advance(10)
        try await manager.tick()
        let retried = await transfer.sent
        #expect(retried.isEmpty, "The second attempt also backs off before surfacing failure")
        clock.advance(10)
        try await manager.tick()
        let terminal = try await store.jobs().first
        #expect(terminal?.state == .failed)
        #expect(terminal?.attempt == PhoneWatchTransferScheduler.maxAutomaticAttempts)
        #expect(terminal?.nextAttemptAt == nil)
        await transfer.setFailAlways([:])
        try await manager.requestRetry(requestID: try #require(terminal?.requestID))
        let approved = await transfer.sent
        #expect(approved == ["a"])
    }

    @Test func testAuthFailureDoesNotSpinButExplicitRetryWorks() async throws {
        let db = try freshQueue()
        let store = PhoneWatchDownloadStore(dbQueue: db)
        let clock = TestClock()
        let resolver = FakeResolver(local: ["a"])
        await resolver.set("a", resolution: .needsAuth, transferability: .ready(bytes: 1, sha256: nil))
        let transfer = FakeTransfer()
        let manager = makeManager(dbQueue: db, resolver: resolver, transfer: transfer, clock: clock)

        try await manager.setRoots([root("r1", tracks: ["a"])])
        let job = try await store.jobs().first
        #expect(job?.failureClass == .needsAuth)
        #expect(job?.nextAttemptAt == nil)

        clock.advance(10_000)
        try await manager.tick()
        let stillStalled = await transfer.sent
        #expect(stillStalled.isEmpty)

        await resolver.makeAvailable("a")
        try await manager.requestRetry(trackID: "a")
        let sent = await transfer.sent
        #expect(sent == ["a"])
        let resolved = try await store.jobs().first
        #expect(resolved?.state == .sent)
    }

    @Test func testPermanentFailureNeverRetries() async throws {
        let db = try freshQueue()
        let store = PhoneWatchDownloadStore(dbQueue: db)
        let transfer = FakeTransfer()
        await transfer.setFailAlways(["a": .unsupportedAudio])
        let clock = TestClock()
        let manager = makeManager(dbQueue: db, resolver: FakeResolver(local: ["a"]),
                                  transfer: transfer, clock: clock)

        try await manager.setRoots([root("r1", tracks: ["a"])])
        clock.advance(100_000)
        try await manager.tick()
        let sent = await transfer.sent
        #expect(sent.isEmpty)
        let job = try await store.jobs().first
        #expect(job?.failureClass == .fileUnsupported)
    }

    // MARK: manager — relaunch

    @Test func testRelaunchDoesNotResendCompletedTransfers() async throws {
        let db = try freshQueue()
        let resolver = FakeResolver(local: ["a", "b"])
        let transfer = FakeTransfer()
        let managerA = makeManager(dbQueue: db, resolver: resolver, transfer: transfer)
        try await managerA.setRoots([root("r1", tracks: ["a", "b"])])
        let afterA = await transfer.sent
        #expect(afterA.count == 2)

        let managerB = makeManager(dbQueue: db, resolver: resolver, transfer: transfer)
        try await managerB.resumeOutstanding()
        let afterB = await transfer.sent
        #expect(afterB.count == 2, "no track should be re-sent after relaunch")
    }

    @Test func testRelaunchDoesNotAutomaticallyRequeueStrandedTransfer() async throws {
        let db = try freshQueue()
        let store = PhoneWatchDownloadStore(dbQueue: db)
        try await store.replaceRoots([root("r1", tracks: ["a"])])
        try await store.upsertJob(PhoneWatchDownloadJob(trackID: "a", rootIDs: ["r1"], state: .transferring))
        let transfer = FakeTransfer()
        let manager = makeManager(dbQueue: db, resolver: FakeResolver(local: ["a"]), transfer: transfer)

        try await manager.resumeOutstanding()
        let sent = await transfer.sent
        #expect(sent.isEmpty)
        let job = try await store.jobs().first
        #expect(job?.state == .failed)
    }

    @Test func testRelaunchLeavesGenuinelyOutstandingTransferAlone() async throws {
        let db = try freshQueue()
        let store = PhoneWatchDownloadStore(dbQueue: db)
        try await store.replaceRoots([root("r1", tracks: ["a"])])
        try await store.upsertJob(PhoneWatchDownloadJob(trackID: "a", rootIDs: ["r1"], state: .transferring))
        let transfer = FakeTransfer()
        await transfer.setOutstanding(["a"])
        let manager = makeManager(dbQueue: db, resolver: FakeResolver(local: ["a"]), transfer: transfer)

        try await manager.resumeOutstanding()
        let sent = await transfer.sent
        #expect(sent.isEmpty)
        let job = try await store.jobs().first
        #expect(job?.state == .transferring)
    }

    // MARK: manager — playlist liveness & DoD integration

    @Test func testPlaylistRootStaysLiveAcrossEdits() async throws {
        let db = try freshQueue()
        let resolver = FakeResolver(local: ["a", "b", "c"])
        let transfer = FakeTransfer()
        let contents = PlaylistBox(["a", "b"])
        let manager = makeManager(dbQueue: db, resolver: resolver, transfer: transfer,
                                  expander: { _ in await contents.value })
        try await manager.setRoots([root("p1", kind: .playlist, tracks: ["a", "b"])])
        let afterFirst = await transfer.sentSet()
        #expect(afterFirst == ["a", "b"])

        await contents.set(["a", "b", "c"])
        try await manager.tick()
        let afterEdit = await transfer.sentSet()
        #expect(afterEdit == ["a", "b", "c"])
        let aCount = await transfer.sentCount("a")
        #expect(aCount == 1)
    }

    /// §Phase 5 definition of done: plan a mixed playlist, transfer each audio file once through a
    /// fake writer, survive relaunch, and converge after manifest receipt.
    @Test func testDefinitionOfDone() async throws {
        let db = try freshQueue()
        let resolver = FakeResolver(local: ["t1", "t2", "t3", "t4", "shared"], unsupported: ["bad"])
        let transfer = FakeTransfer()
        await transfer.setFailOnce(["t3"])
        let clock = TestClock()

        let managerA = makeManager(dbQueue: db, resolver: resolver, transfer: transfer, clock: clock)
        try await managerA.setRoots([
            root("album", kind: .albumBatch, tracks: ["t1", "t2", "shared"]),
            root("playlist", kind: .playlist, tracks: ["t3", "t4", "shared", "bad"]),
            root("single", kind: .track, tracks: ["t4"]),
        ])

        clock.advance(30)
        try await managerA.tick()

        let managerB = makeManager(dbQueue: db, resolver: resolver, transfer: transfer, clock: clock)
        try await managerB.resumeOutstanding()

        try await managerB.ingestManifest(manifest(["t1", "t2", "t3", "t4", "shared"]))

        for id in ["t1", "t2", "t3", "t4", "shared"] {
            let count = await transfer.sentCount(id)
            #expect(count == 1, "\(id) transferred \(count)×")
        }
        let sent = await transfer.sent
        #expect(!sent.contains("bad"))

        let snap = try await managerB.statusSnapshot()
        #expect(snap.isIdle)
        #expect(snap.readyCount == 5)
        let remaining = try await managerB.estimatedRemainingBytes()
        #expect(remaining == 0)

        try await managerB.tick()
        let afterTick = await transfer.sent
        #expect(afterTick.sorted() == sent.sorted())
    }

    // MARK: Phase 8 — pause / resume / cancel

    @Test func testV16AddsPausedColumnDefaultingFalse() async throws {
        let queue = try DatabaseQueue()
        try Schema.migrator(upTo: "v15").migrate(queue)
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO watchDownloadRoot (rootID, kind, sourceID, title, desiredTrackIDs, phoneRevision, createdAt)
                VALUES ('r', 'playlist', 's', 't', '[]', 1, '2026-01-01 00:00:00.000')
                """)
        }
        try Schema.migrator().migrate(queue)
        let store = PhoneWatchDownloadStore(dbQueue: queue)
        let roots = try await store.roots()
        #expect(roots.first?.paused == false)

        var paused = roots[0]
        paused.paused = true
        try await store.upsertRoot(paused)
        let reread = try await store.roots()
        #expect(reread.first?.paused == true)
    }

    @Test func testPauseRootCancelsInFlightAndStopsQueueing() async throws {
        let db = try freshQueue()
        let resolver = FakeResolver(local: ["a", "b"])
        let transfer = FakeTransfer()
        let manager = makeManager(dbQueue: db, resolver: resolver, transfer: transfer)
        let store = PhoneWatchDownloadStore(dbQueue: db)

        // An in-flight job the pause must cancel.
        try await store.replaceRoots([root("pl", kind: .playlist, tracks: ["a", "b"])])
        try await store.upsertJob(PhoneWatchDownloadJob(trackID: "a", rootIDs: ["pl"], state: .transferring))

        try await manager.pauseRoot(rootID: "pl")

        let cancelled = await transfer.cancelled
        #expect(cancelled == ["a"])
        let active = try await store.activeJobs()
        #expect(active.isEmpty, "paused root left active jobs: \(active.map(\.state))")

        // A tick while paused queues nothing new.
        try await manager.tick()
        let afterTick = try await store.activeJobs()
        #expect(afterTick.isEmpty)
    }

    @Test func testResumeRootReQueuesMissingTracks() async throws {
        let db = try freshQueue()
        let resolver = FakeResolver(local: ["a", "b"])
        let transfer = FakeTransfer()
        let manager = makeManager(dbQueue: db, resolver: resolver, transfer: transfer)

        try await manager.setRoots([root("pl", kind: .playlist, tracks: ["a", "b"])])
        try await manager.ingestManifest(manifest(["a"]))    // only "a" installed
        try await manager.pauseRoot(rootID: "pl")
        try await manager.resumeRoot(rootID: "pl")

        let sentB = await transfer.sentCount("b")
        #expect(sentB == 1)
    }

    // MARK: watch redesign D1 — root status + watch-side control

    @Test func testRootStatusPrecedence() {
        let roots = [root("done", tracks: ["a"]), root("paused", tracks: ["b"]),
                     root("dl", tracks: ["c", "d"]), root("wifi", tracks: ["e"]),
                     root("q", tracks: ["f"]), root("bad", tracks: ["g"])]
        var paused = roots[1]; paused.paused = true
        let jobs = [
            PhoneWatchDownloadJob(trackID: "b", rootIDs: ["paused"], state: .transferring),
            PhoneWatchDownloadJob(trackID: "c", rootIDs: ["dl"], state: .transferring),
            PhoneWatchDownloadJob(trackID: "d", rootIDs: ["dl"], state: .failed),
            PhoneWatchDownloadJob(trackID: "e", rootIDs: ["wifi"], state: .waitingForWiFi),
            PhoneWatchDownloadJob(trackID: "f", rootIDs: ["q"], state: .queued),
            PhoneWatchDownloadJob(trackID: "g", rootIDs: ["bad"], state: .failed)
        ]
        let statuses = PhoneWatchDownloadManager.rootStatuses(
            roots: [roots[0], paused, roots[2], roots[3], roots[4], roots[5]],
            jobs: jobs, installed: ["a"])
        #expect(statuses.map(\.state) == [.complete, .paused, .downloading, .waitingForWiFi, .queued, .failed])
        #expect(statuses[2].failedCount == 1, "a failed track inside a downloading root is still counted")
        #expect(statuses[0].fraction == 1)
    }

    @Test func testWatchPauseAndResumeControlAddressEveryRootWhenUnscoped() async throws {
        let db = try freshQueue()
        let resolver = FakeResolver(local: ["a", "b"])
        let transfer = FakeTransfer()
        let manager = makeManager(dbQueue: db, resolver: resolver, transfer: transfer)
        let store = PhoneWatchDownloadStore(dbQueue: db)
        try await store.replaceRoots([root("p1", kind: .playlist, tracks: ["a"]),
                                      root("p2", kind: .playlist, tracks: ["b"])])

        try await manager.applyControl(WatchDownloadControl(action: .pause))
        let pausedFlags = try await store.roots().map(\.paused)
        #expect(pausedFlags == [true, true])

        try await manager.applyControl(WatchDownloadControl(action: .resume, rootID: "p2"))
        let byID = Dictionary(uniqueKeysWithValues: try await store.roots().map { ($0.rootID, $0.paused) })
        #expect(byID == ["p1": true, "p2": false])
    }

    @Test func testWatchStopControlRemovesTheRoot() async throws {
        let db = try freshQueue()
        let manager = makeManager(dbQueue: db, resolver: FakeResolver(local: ["a"]), transfer: FakeTransfer())
        let store = PhoneWatchDownloadStore(dbQueue: db)
        try await store.replaceRoots([root("p1", kind: .playlist, tracks: ["a"])])

        try await manager.applyControl(WatchDownloadControl(action: .stop, rootID: "p1"))
        let remaining = try await store.roots()
        #expect(remaining.isEmpty)
    }

    @Test func testStatusSnapshotCarriesRootsAndDecodesWithoutThem() async throws {
        let db = try freshQueue()
        let manager = makeManager(dbQueue: db, resolver: FakeResolver(local: ["a"]), transfer: FakeTransfer())
        let store = PhoneWatchDownloadStore(dbQueue: db)
        try await store.replaceRoots([root("p1", kind: .playlist, tracks: ["a"])])
        let snapshot = try await manager.statusSnapshot()
        #expect(snapshot.roots.map(\.rootID) == ["p1"])

        let legacy = Data(#"{"revision":4,"queuedCount":1}"#.utf8)
        let decoded = try JSONDecoder().decode(WatchDownloadStatusSnapshot.self, from: legacy)
        #expect(decoded.roots.isEmpty)
    }

    @Test func testCancelJobStaysCancelledAcrossReconcile() async throws {
        let db = try freshQueue()
        let resolver = FakeResolver(local: ["a"])
        let transfer = FakeTransfer()
        await transfer.setFailAlways(["a": .sourceUnavailable])
        let manager = makeManager(dbQueue: db, resolver: resolver, transfer: transfer)
        let store = PhoneWatchDownloadStore(dbQueue: db)

        try await manager.setRoots([root("pl", kind: .playlist, tracks: ["a"])])
        let failed = try await store.jobs().first { $0.trackID == "a" }
        let requestID = try #require(failed?.requestID)

        try await manager.cancelJob(requestID: requestID)
        try await manager.tick()

        let after = try await store.jobs().first { $0.trackID == "a" }
        #expect(after?.state == .cancelled)

        // An explicit retry revives it.
        try await manager.requestRetry(requestID: requestID)
        let revived = try await store.jobs().first { $0.trackID == "a" }
        #expect(revived?.state != .cancelled)
    }

    // MARK: - Phase 10f — fault-injection / soak harnesses (§12)

    /// 500-track desired set: the pipeline converges (idle, all ready, nothing outstanding), every
    /// file crosses the transfer seam exactly once, and the job table does not grow unbounded — it
    /// prunes to empty once the manifest confirms the installs.
    @Test func test500TrackDesiredSetConvergesAndTheJobTableIsBounded() async throws {
        let db = try freshQueue()
        let ids = (0..<500).map { "t\($0)" }
        let resolver = FakeResolver(local: Set(ids))
        let transfer = FakeTransfer()
        let manager = makeManager(dbQueue: db, resolver: resolver, transfer: transfer)
        let store = PhoneWatchDownloadStore(dbQueue: db)

        try await manager.setRoots([root("big", kind: .playlist, tracks: ids)])

        let sent = await transfer.sent
        #expect(sent.count == 500)
        #expect(Set(sent).count == 500, "each track transferred exactly once")

        try await manager.ingestManifest(manifest(ids))
        let snap = try await manager.statusSnapshot()
        #expect(snap.isIdle)
        #expect(snap.readyCount == 500)
        let remaining = try await manager.estimatedRemainingBytes()
        #expect(remaining == 0)

        // Bounded: settled jobs for installed+desired tracks are pruned, so the table does not carry
        // one row per track forever.
        let jobs = try await store.jobs()
        #expect(jobs.isEmpty, "the job table should prune to empty after convergence, had \(jobs.count)")

        // Idempotent: another tick moves nothing.
        try await manager.tick()
        let sentAfterTick = await transfer.sent
        #expect(sentAfterTick.count == 500)
    }

    /// 100 cancellations: every cancelled job stays cancelled across a reconcile, none is revived by
    /// a bare tick, and no duplicate job is created for a still-desired track.
    @Test func test100CancellationsAllStayCancelled() async throws {
        let db = try freshQueue()
        let ids = (0..<100).map { "c\($0)" }
        let transfer = FakeTransfer()
        // Fail every resolve so nothing races to `.sent` before we cancel it.
        await transfer.setFailAlways(Dictionary(uniqueKeysWithValues: ids.map { ($0, .sourceUnavailable) }))
        let manager = makeManager(dbQueue: db, resolver: FakeResolver(local: Set(ids)), transfer: transfer)
        let store = PhoneWatchDownloadStore(dbQueue: db)

        try await manager.setRoots([root("pl", kind: .playlist, tracks: ids)])
        let requestIDs = try await store.jobs().map(\.requestID)
        #expect(requestIDs.count == 100)

        for requestID in requestIDs {
            try await manager.cancelJob(requestID: requestID)
        }
        try await manager.tick()
        try await manager.tick()

        let jobs = try await store.jobs()
        #expect(jobs.count == 100, "no duplicate jobs for still-desired tracks")
        #expect(jobs.allSatisfy { $0.state == .cancelled }, "every cancelled job stayed cancelled")
        let active = try await store.activeJobs()
        #expect(active.isEmpty)
    }

    /// Relaunch at every job state: a crash can leave a job in any `PhoneWatchJobState`. After the
    /// §8.2 relaunch flow (`resumeOutstanding`), each converges to a consistent terminal — the
    /// in-flight-ish states resume and complete, and `sent` / `failed` / `cancelled` are respected —
    /// with never more than one job per track.
    @Test func testRelaunchAtEveryJobStateConvergesConsistently() async throws {
        let resumesToSent: Set<PhoneWatchJobState> = [.queued, .waitingForWiFi]

        for state in PhoneWatchJobState.allCases {
            let db = try freshQueue()
            let store = PhoneWatchDownloadStore(dbQueue: db)
            try await store.replaceRoots([root("r1", tracks: ["a"])])
            try await store.upsertJob(PhoneWatchDownloadJob(trackID: "a", rootIDs: ["r1"], state: state))

            let transfer = FakeTransfer()
            let manager = makeManager(dbQueue: db, resolver: FakeResolver(local: ["a"]), transfer: transfer)

            try await manager.resumeOutstanding()

            let jobs = try await store.jobs().filter { $0.trackID == "a" }
            #expect(jobs.count == 1, "state \(state): exactly one job per track")
            let sent = await transfer.sent

            if resumesToSent.contains(state) {
                #expect(sent == ["a"], "state \(state) should resume and complete the transfer")
                #expect(jobs.first?.state == .sent)
            } else {
                #expect(sent.isEmpty, "state \(state) is terminal — nothing should transfer")
                #expect(jobs.first?.state == ([.resolving, .transferring].contains(state) ? .failed : state), "Interrupted work must ask for approval rather than automatically resend")
            }
        }
    }
}
