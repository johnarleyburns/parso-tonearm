import Foundation
import GRDB
import XCTest
import TonearmWatchProtocol
@testable import TonearmCore

// MARK: - Fakes

private actor FakeResolver: PhoneWatchAudioResolving {
    private var resolutions: [String: PhoneWatchAudioResolution] = [:]
    private var transferabilities: [String: PhoneWatchTransferability] = [:]
    private(set) var resolveCounts: [String: Int] = [:]

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

    func makeAvailable(_ id: String, bytes: Int64 = 1_000) {
        resolutions[id] = .cached(URL(fileURLWithPath: "/tmp/tonearm-test/\(id).caf"), bytes: bytes, sha256: nil)
        transferabilities[id] = .ready(bytes: bytes, sha256: nil)
    }

    func resolve(trackID: WatchTrackID) async -> PhoneWatchAudioResolution {
        resolveCounts[trackID.rawValue, default: 0] += 1
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

    func setFailOnce(_ ids: Set<String>) { failOnce = ids }
    func setFailAlways(_ map: [String: WatchProtocolErrorCode]) { failAlways = map }
    func setOutstanding(_ ids: [String]) { outstanding = ids }

    func transfer(fileURL: URL, trackID: WatchTrackID, expectedBytes: Int64, sha256: String?) async throws {
        let id = trackID.rawValue
        if let code = failAlways[id] { throw WatchProtocolFault(code: code) }
        if failOnce.contains(id) { failOnce.remove(id); throw WatchProtocolFault(code: .transferFailed) }
        sent.append(id)
    }

    func outstandingTransfers() async -> [WatchTrackID] { outstanding.map { WatchTrackID($0) } }
    func cancelTransfer(trackID: WatchTrackID) async { cancelled.append(trackID.rawValue) }

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

final class PhoneWatchDownloadTests: XCTestCase {

    // MARK: schema

    func testV15CreatesDownloadTables() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator(upTo: "v14").migrate(queue)
        try Schema.migrator().migrate(queue)
        try queue.read { db in
            for table in ["watchDownloadRoot", "watchDownloadJob",
                          "watchDownloadManifestEntry", "watchDownloadRevision"] {
                let exists = try db.tableExists(table)
                XCTAssertTrue(exists, "\(table) missing")
            }
            let seed = try Int64.fetchOne(db, sql: "SELECT value FROM watchDownloadRevision WHERE id = 1")
            XCTAssertEqual(seed, 0)
        }
    }

    func testV15DoesNotDisturbLegacyWatchTransferTable() throws {
        let queue = try freshQueue()
        try queue.read { db in
            let transfer = try db.tableExists("watchTransfer")
            let manifestTable = try db.tableExists("watchManifest")
            XCTAssertTrue(transfer)
            XCTAssertTrue(manifestTable)
        }
    }

    // MARK: store round-trips

    func testStoreRootAndJobRoundTrip() async throws {
        let store = PhoneWatchDownloadStore(dbQueue: try freshQueue())
        try await store.replaceRoots([root("r1", tracks: ["a", "b"])])
        let roots = try await store.roots()
        XCTAssertEqual(roots.map(\.rootID), ["r1"])
        XCTAssertEqual(roots.first?.desiredTrackIDs, ["a", "b"])

        var job = PhoneWatchDownloadJob(trackID: "a", rootIDs: ["r1"], expectedBytes: 42)
        try await store.upsertJob(job)
        job.state = .sent
        try await store.upsertJob(job)
        let jobs = try await store.jobs()
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.state, .sent)
        XCTAssertEqual(jobs.first?.expectedBytes, 42)
    }

    func testBumpRevisionMonotonic() async throws {
        let store = PhoneWatchDownloadStore(dbQueue: try freshQueue())
        let start = try await store.currentRevision()
        XCTAssertEqual(start, 0)
        let first = try await store.bumpRevision()
        XCTAssertEqual(first, 1)
        let second = try await store.bumpRevision()
        XCTAssertEqual(second, 2)
        let current = try await store.currentRevision()
        XCTAssertEqual(current, 2)
    }

    // MARK: planner

    func testPlannerDedupesSharedReferences() {
        let plan = PhoneWatchDownloadPlanner.plan(
            roots: [root("r1", tracks: ["a", "b"]), root("r2", kind: .playlist, tracks: ["b", "c"])],
            installedTrackIDs: [], existingJobs: [],
            transferability: { _ in .ready(bytes: 100, sha256: nil) })
        XCTAssertEqual(Set(plan.toCreate.map(\.trackID)), ["a", "b", "c"])
        XCTAssertEqual(plan.referenceCounts["b"], 2)
        XCTAssertEqual(plan.toCreate.first { $0.trackID == "b" }?.priority, .trackOrAlbumBatch)
    }

    func testPlannerSkipsInstalledAndUnsupported() {
        let plan = PhoneWatchDownloadPlanner.plan(
            roots: [root("r1", tracks: ["installed", "bad", "ok"])],
            installedTrackIDs: ["installed"], existingJobs: [],
            transferability: {
                switch $0 {
                case "bad": return .unsupported(reason: "codec")
                default: return .ready(bytes: 1, sha256: nil)
                }
            })
        XCTAssertEqual(plan.toCreate.map(\.trackID), ["ok"])
        XCTAssertEqual(plan.unsupported, ["bad"])
    }

    func testPlannerCancelsUndesiredActiveJobs() {
        let existing = [PhoneWatchDownloadJob(trackID: "gone", rootIDs: ["r1"], state: .transferring)]
        let plan = PhoneWatchDownloadPlanner.plan(
            roots: [root("r1", tracks: ["kept"])],
            installedTrackIDs: [], existingJobs: existing,
            transferability: { _ in .ready(bytes: 1, sha256: nil) })
        XCTAssertEqual(plan.toCancel, [existing[0].requestID])
        XCTAssertEqual(plan.toCreate.map(\.trackID), ["kept"])
    }

    // MARK: scheduler

    func testSchedulerRespectsAudioCap() {
        let jobs = (0..<5).map { PhoneWatchDownloadJob(trackID: "t\($0)", rootIDs: ["r"], state: .queued,
                                                       createdAt: Date(timeIntervalSince1970: Double($0))) }
        let picked = PhoneWatchTransferScheduler.nextDispatch(jobs: jobs, now: Date(), canTransferOnNetwork: true)
        XCTAssertEqual(picked.count, PhoneWatchTransferScheduler.maxAudioInFlight)
    }

    func testSchedulerHoldsBackoffJobs() {
        let future = Date().addingTimeInterval(120)
        let jobs = [PhoneWatchDownloadJob(trackID: "t", rootIDs: ["r"], state: .queued, nextAttemptAt: future)]
        let picked = PhoneWatchTransferScheduler.nextDispatch(jobs: jobs, now: Date(), canTransferOnNetwork: true)
        XCTAssertTrue(picked.isEmpty)
    }

    func testSchedulerBackoffIsBoundedAndExponential() {
        XCTAssertEqual(PhoneWatchTransferScheduler.backoff(attempt: 1), 5)
        XCTAssertEqual(PhoneWatchTransferScheduler.backoff(attempt: 2), 10)
        XCTAssertEqual(PhoneWatchTransferScheduler.backoff(attempt: 3), 20)
        XCTAssertEqual(PhoneWatchTransferScheduler.backoff(attempt: 99), 300)
    }

    func testSchedulerClassifyNeverPermanentByOmission() {
        XCTAssertEqual(PhoneWatchTransferScheduler.classify(nil), .transient)
        XCTAssertEqual(PhoneWatchTransferScheduler.classify(.transferFailed), .transient)
        XCTAssertEqual(PhoneWatchTransferScheduler.classify(.authenticationRequired), .needsAuth)
        XCTAssertEqual(PhoneWatchTransferScheduler.classify(.sourceUnavailable), .sourceUnavailable)
        XCTAssertEqual(PhoneWatchTransferScheduler.classify(.unsupportedAudio), .fileUnsupported)
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

    func testSetRootsTransfersEachTrackOnce() async throws {
        let db = try freshQueue()
        let resolver = FakeResolver(local: ["a", "b", "c"])
        let transfer = FakeTransfer()
        let manager = makeManager(dbQueue: db, resolver: resolver, transfer: transfer)

        try await manager.setRoots([root("r1", tracks: ["a", "b"]),
                                    root("r2", kind: .playlist, tracks: ["b", "c"])])

        let sent = await transfer.sentSet()
        XCTAssertEqual(sent, ["a", "b", "c"])
        let sharedCount = await transfer.sentCount("b")
        XCTAssertEqual(sharedCount, 1)
        let resolveCount = await resolver.resolveCount("b")
        XCTAssertEqual(resolveCount, 1)
    }

    func testSetRootsEmitsDescriptorsWithBumpedRevision() async throws {
        let db = try freshQueue()
        let emitted = EmittedRoots()
        let manager = makeManager(dbQueue: db, resolver: FakeResolver(local: ["a"]),
                                  transfer: FakeTransfer(), emitted: emitted)
        try await manager.setRoots([root("r1", tracks: ["a"])])
        XCTAssertEqual(emitted.calls.count, 1)
        XCTAssertEqual(emitted.calls[0].revision, 1)
        XCTAssertEqual(emitted.calls[0].roots.map { $0.rootID.rawValue }, ["r1"])
        XCTAssertEqual(emitted.calls[0].roots[0].trackIDs.map(\.rawValue), ["a"])
    }

    func testUnavailableTrackIsNotTransferredAndStaysDesired() async throws {
        let db = try freshQueue()
        let resolver = FakeResolver(local: ["a"], unavailable: ["b"])
        let transfer = FakeTransfer()
        let manager = makeManager(dbQueue: db, resolver: resolver, transfer: transfer)

        try await manager.setRoots([root("r1", tracks: ["a", "b"])])
        let afterFirst = await transfer.sent
        XCTAssertEqual(afterFirst, ["a"])

        await resolver.makeAvailable("b")
        try await manager.tick()
        let afterConverge = await transfer.sentSet()
        XCTAssertEqual(afterConverge, ["a", "b"])
        let aCount = await transfer.sentCount("a")
        XCTAssertEqual(aCount, 1)
    }

    func testUnsupportedTrackNeverCreatesAJob() async throws {
        let db = try freshQueue()
        let store = PhoneWatchDownloadStore(dbQueue: db)
        let transfer = FakeTransfer()
        let manager = makeManager(dbQueue: db, resolver: FakeResolver(local: ["a"], unsupported: ["b"]),
                                  transfer: transfer)
        try await manager.setRoots([root("r1", tracks: ["a", "b"])])
        let jobs = try await store.jobs()
        XCTAssertEqual(jobs.map(\.trackID), ["a"])
        let sent = await transfer.sent
        XCTAssertEqual(sent, ["a"])
    }

    // MARK: manager — Wi-Fi gate

    func testWaitingForWiFiThenResumes() async throws {
        let db = try freshQueue()
        let gate = FakeGate(false)
        let transfer = FakeTransfer()
        let manager = makeManager(dbQueue: db, resolver: FakeResolver(local: ["a", "b"]),
                                  transfer: transfer, gate: gate)

        try await manager.setRoots([root("r1", tracks: ["a", "b"])])
        let stalled = await transfer.sent
        XCTAssertTrue(stalled.isEmpty)
        let waiting = try await manager.statusSnapshot()
        XCTAssertEqual(waiting.waitingForWiFiCount, 2)

        await gate.set(true)
        try await manager.tick()
        let resumed = await transfer.sentSet()
        XCTAssertEqual(resumed, ["a", "b"])
        let after = try await manager.statusSnapshot()
        XCTAssertEqual(after.waitingForWiFiCount, 0)
    }

    // MARK: manager — cancellation & divergence

    func testRemovingARootCancelsItsInFlightJob() async throws {
        let db = try freshQueue()
        let store = PhoneWatchDownloadStore(dbQueue: db)
        try await store.replaceRoots([root("r1", tracks: ["a"])])
        try await store.upsertJob(PhoneWatchDownloadJob(trackID: "a", rootIDs: ["r1"], state: .transferring))
        let transfer = FakeTransfer()
        let manager = makeManager(dbQueue: db, resolver: FakeResolver(local: ["a"]), transfer: transfer)

        try await manager.removeRoot(rootID: "r1")
        let cancelled = await transfer.cancelled
        XCTAssertEqual(cancelled, ["a"])
        // The job is cancelled and, its track no longer wanted, pruned in the same pass.
        let active = try await store.activeJobs()
        XCTAssertTrue(active.isEmpty)
    }

    func testManifestArrivalConvergesAndStopsWork() async throws {
        let db = try freshQueue()
        let resolver = FakeResolver(local: ["a", "b", "c"])
        let transfer = FakeTransfer()
        let manager = makeManager(dbQueue: db, resolver: resolver, transfer: transfer)
        try await manager.setRoots([root("r1", tracks: ["a", "b", "c"])])

        try await manager.ingestManifest(manifest(["a", "b", "c"]))
        let snap = try await manager.statusSnapshot()
        XCTAssertTrue(snap.isIdle)
        XCTAssertEqual(snap.readyCount, 3)
        let remaining = try await manager.estimatedRemainingBytes()
        XCTAssertEqual(remaining, 0)

        try await manager.tick()
        let sent = await transfer.sentSorted()
        XCTAssertEqual(sent, ["a", "b", "c"])
    }

    func testWatchStoreResetReQueuesDroppedTracks() async throws {
        let db = try freshQueue()
        let resolver = FakeResolver(local: ["a", "b"])
        let transfer = FakeTransfer()
        let manager = makeManager(dbQueue: db, resolver: resolver, transfer: transfer)
        try await manager.setRoots([root("r1", tracks: ["a", "b"])])
        try await manager.ingestManifest(manifest(["a", "b"]))
        let afterFirst = await transfer.sent
        XCTAssertEqual(afterFirst.count, 2)

        try await manager.ingestManifest(manifest([]))
        let afterReset = await transfer.sentSorted()
        XCTAssertEqual(afterReset, ["a", "a", "b", "b"])
    }

    func testManifestReadyForUndesiredTrackIsHonoured() async throws {
        let db = try freshQueue()
        let transfer = FakeTransfer()
        let manager = makeManager(dbQueue: db, resolver: FakeResolver(local: ["a"]), transfer: transfer)
        try await manager.setRoots([root("r1", tracks: ["a"])])
        try await manager.ingestManifest(manifest(["a", "legacy"]))
        let snap = try await manager.statusSnapshot()
        XCTAssertEqual(snap.readyCount, 2)
        XCTAssertTrue(snap.isIdle)
        let sent = await transfer.sent
        XCTAssertEqual(sent, ["a"])
    }

    // MARK: manager — retry classes

    func testTransientFailureBacksOffThenRetriesOnTimerElapsed() async throws {
        let db = try freshQueue()
        let store = PhoneWatchDownloadStore(dbQueue: db)
        let clock = TestClock()
        let transfer = FakeTransfer()
        await transfer.setFailOnce(["a"])
        let manager = makeManager(dbQueue: db, resolver: FakeResolver(local: ["a"]),
                                  transfer: transfer, clock: clock)

        try await manager.setRoots([root("r1", tracks: ["a"])])
        let stalled = await transfer.sent
        XCTAssertTrue(stalled.isEmpty)
        let failed = try await store.jobs().first
        XCTAssertEqual(failed?.state, .failed)
        XCTAssertEqual(failed?.failureClass, .transient)
        XCTAssertEqual(failed?.attempt, 1)
        XCTAssertNotNil(failed?.nextAttemptAt)

        try await manager.tick()
        let stillStalled = await transfer.sent
        XCTAssertTrue(stillStalled.isEmpty)

        clock.advance(10)
        try await manager.tick()
        let retried = await transfer.sent
        XCTAssertEqual(retried, ["a"])
    }

    func testAuthFailureDoesNotSpinButExplicitRetryWorks() async throws {
        let db = try freshQueue()
        let store = PhoneWatchDownloadStore(dbQueue: db)
        let clock = TestClock()
        let resolver = FakeResolver(local: ["a"])
        await resolver.set("a", resolution: .needsAuth, transferability: .ready(bytes: 1, sha256: nil))
        let transfer = FakeTransfer()
        let manager = makeManager(dbQueue: db, resolver: resolver, transfer: transfer, clock: clock)

        try await manager.setRoots([root("r1", tracks: ["a"])])
        let job = try await store.jobs().first
        XCTAssertEqual(job?.failureClass, .needsAuth)
        XCTAssertNil(job?.nextAttemptAt)

        clock.advance(10_000)
        try await manager.tick()
        let stillStalled = await transfer.sent
        XCTAssertTrue(stillStalled.isEmpty)

        await resolver.makeAvailable("a")
        try await manager.requestRetry(trackID: "a")
        let sent = await transfer.sent
        XCTAssertEqual(sent, ["a"])
        let resolved = try await store.jobs().first
        XCTAssertEqual(resolved?.state, .sent)
    }

    func testPermanentFailureNeverRetries() async throws {
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
        XCTAssertTrue(sent.isEmpty)
        let job = try await store.jobs().first
        XCTAssertEqual(job?.failureClass, .fileUnsupported)
    }

    // MARK: manager — relaunch

    func testRelaunchDoesNotResendCompletedTransfers() async throws {
        let db = try freshQueue()
        let resolver = FakeResolver(local: ["a", "b"])
        let transfer = FakeTransfer()
        let managerA = makeManager(dbQueue: db, resolver: resolver, transfer: transfer)
        try await managerA.setRoots([root("r1", tracks: ["a", "b"])])
        let afterA = await transfer.sent
        XCTAssertEqual(afterA.count, 2)

        let managerB = makeManager(dbQueue: db, resolver: resolver, transfer: transfer)
        try await managerB.resumeOutstanding()
        let afterB = await transfer.sent
        XCTAssertEqual(afterB.count, 2, "no track should be re-sent after relaunch")
    }

    func testRelaunchReQueuesStrandedTransferWhenFrameworkForgotIt() async throws {
        let db = try freshQueue()
        let store = PhoneWatchDownloadStore(dbQueue: db)
        try await store.replaceRoots([root("r1", tracks: ["a"])])
        try await store.upsertJob(PhoneWatchDownloadJob(trackID: "a", rootIDs: ["r1"], state: .transferring))
        let transfer = FakeTransfer()
        let manager = makeManager(dbQueue: db, resolver: FakeResolver(local: ["a"]), transfer: transfer)

        try await manager.resumeOutstanding()
        let sent = await transfer.sent
        XCTAssertEqual(sent, ["a"])
    }

    func testRelaunchLeavesGenuinelyOutstandingTransferAlone() async throws {
        let db = try freshQueue()
        let store = PhoneWatchDownloadStore(dbQueue: db)
        try await store.replaceRoots([root("r1", tracks: ["a"])])
        try await store.upsertJob(PhoneWatchDownloadJob(trackID: "a", rootIDs: ["r1"], state: .transferring))
        let transfer = FakeTransfer()
        await transfer.setOutstanding(["a"])
        let manager = makeManager(dbQueue: db, resolver: FakeResolver(local: ["a"]), transfer: transfer)

        try await manager.resumeOutstanding()
        let sent = await transfer.sent
        XCTAssertTrue(sent.isEmpty)
        let job = try await store.jobs().first
        XCTAssertEqual(job?.state, .transferring)
    }

    // MARK: manager — playlist liveness & DoD integration

    func testPlaylistRootStaysLiveAcrossEdits() async throws {
        let db = try freshQueue()
        let resolver = FakeResolver(local: ["a", "b", "c"])
        let transfer = FakeTransfer()
        let contents = PlaylistBox(["a", "b"])
        let manager = makeManager(dbQueue: db, resolver: resolver, transfer: transfer,
                                  expander: { _ in await contents.value })
        try await manager.setRoots([root("p1", kind: .playlist, tracks: ["a", "b"])])
        let afterFirst = await transfer.sentSet()
        XCTAssertEqual(afterFirst, ["a", "b"])

        await contents.set(["a", "b", "c"])
        try await manager.tick()
        let afterEdit = await transfer.sentSet()
        XCTAssertEqual(afterEdit, ["a", "b", "c"])
        let aCount = await transfer.sentCount("a")
        XCTAssertEqual(aCount, 1)
    }

    /// §Phase 5 definition of done: plan a mixed playlist, transfer each audio file once through a
    /// fake writer, survive relaunch, and converge after manifest receipt.
    func testDefinitionOfDone() async throws {
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
            XCTAssertEqual(count, 1, "\(id) transferred \(count)×")
        }
        let sent = await transfer.sent
        XCTAssertFalse(sent.contains("bad"))

        let snap = try await managerB.statusSnapshot()
        XCTAssertTrue(snap.isIdle)
        XCTAssertEqual(snap.readyCount, 5)
        let remaining = try await managerB.estimatedRemainingBytes()
        XCTAssertEqual(remaining, 0)

        try await managerB.tick()
        let afterTick = await transfer.sent
        XCTAssertEqual(afterTick.sorted(), sent.sorted())
    }

    // MARK: Phase 8 — pause / resume / cancel

    func testV16AddsPausedColumnDefaultingFalse() async throws {
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
        XCTAssertEqual(roots.first?.paused, false)

        var paused = roots[0]
        paused.paused = true
        try await store.upsertRoot(paused)
        let reread = try await store.roots()
        XCTAssertEqual(reread.first?.paused, true)
    }

    func testPauseRootCancelsInFlightAndStopsQueueing() async throws {
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
        XCTAssertEqual(cancelled, ["a"])
        let active = try await store.activeJobs()
        XCTAssertTrue(active.isEmpty, "paused root left active jobs: \(active.map(\.state))")

        // A tick while paused queues nothing new.
        try await manager.tick()
        let afterTick = try await store.activeJobs()
        XCTAssertTrue(afterTick.isEmpty)
    }

    func testResumeRootReQueuesMissingTracks() async throws {
        let db = try freshQueue()
        let resolver = FakeResolver(local: ["a", "b"])
        let transfer = FakeTransfer()
        let manager = makeManager(dbQueue: db, resolver: resolver, transfer: transfer)

        try await manager.setRoots([root("pl", kind: .playlist, tracks: ["a", "b"])])
        try await manager.ingestManifest(manifest(["a"]))    // only "a" installed
        try await manager.pauseRoot(rootID: "pl")
        try await manager.resumeRoot(rootID: "pl")

        let sentB = await transfer.sentCount("b")
        XCTAssertEqual(sentB, 1)
    }

    func testCancelJobStaysCancelledAcrossReconcile() async throws {
        let db = try freshQueue()
        let resolver = FakeResolver(local: ["a"])
        let transfer = FakeTransfer()
        await transfer.setFailAlways(["a": .sourceUnavailable])
        let manager = makeManager(dbQueue: db, resolver: resolver, transfer: transfer)
        let store = PhoneWatchDownloadStore(dbQueue: db)

        try await manager.setRoots([root("pl", kind: .playlist, tracks: ["a"])])
        let failed = try await store.jobs().first { $0.trackID == "a" }
        let requestID = try XCTUnwrap(failed?.requestID)

        try await manager.cancelJob(requestID: requestID)
        try await manager.tick()

        let after = try await store.jobs().first { $0.trackID == "a" }
        XCTAssertEqual(after?.state, .cancelled)

        // An explicit retry revives it.
        try await manager.requestRetry(requestID: requestID)
        let revived = try await store.jobs().first { $0.trackID == "a" }
        XCTAssertNotEqual(revived?.state, .cancelled)
    }
}
