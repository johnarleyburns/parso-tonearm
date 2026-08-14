import XCTest

@testable import TonearmDJ

/// Commit 5.9 — the `GigCrateModel` (plan 5.9, §41.17): promotion, the
/// eviction preview shown before any eviction, the preparing state, and the
/// FR-PLIST-9 readiness readouts — driven against fakes so the states are
/// deterministic (§47.2). The real repository/budget/service are covered by
/// their own suites; this pins the model's orchestration.
@MainActor
final class GigCrateModelTests: XCTestCase {

    // MARK: - Fakes

    private final class FakeRepository: GigCrateRepositing, @unchecked Sendable {
        var cratesValue: [GigCrateRow] = []
        var details: [Int64: GigCrateDetail] = [:]
        var promotedCalls: [(Int64, String)] = []
        var performed: [Int64] = []

        func crates() async throws -> [GigCrateRow] { cratesValue }
        func detail(crateID: Int64) async throws -> GigCrateDetail? { details[crateID] }
        func promote(playlistID: Int64, name: String,
                     storageBudgetBytes: Int64) async throws -> Int64 {
            promotedCalls.append((playlistID, name))
            let id = Int64(promotedCalls.count)
            return id
        }
        func markPerformed(crateID: Int64) async throws { performed.append(crateID) }
        func playlists() async throws -> [DJPlaylist] { [] }
    }

    private final class FakeLane: StemLaneRunning, @unchecked Sendable {
        var plan: StorageBudgetService.StemPlan
        var planCalls: [Int64] = []
        var laneCalls: [Int64] = []
        var progress = AsyncStream<StemProgress>.makeStream(of: StemProgress.self)

        init(plan: StorageBudgetService.StemPlan) {
            self.plan = plan
        }

        func observeProgress() async -> AsyncStream<StemProgress> { progress.0 }
        func planPreparation(crateID: Int64, budget: Int64,
                             protectedIDs: Set<Int64>) async throws -> StorageBudgetService.StemPlan {
            planCalls.append(crateID)
            return plan
        }
        func runCrateLane(crateID: Int64, budget: Int64,
                          protectedIDs: Set<Int64>) async {
            laneCalls.append(crateID)
        }
    }

    private func detail(crateID: Int64, cached: Int, total: Int,
                        stems: Int = 0) -> GigCrateDetail {
        let crate = GigCrate(id: crateID,
                             syncID: UUID().uuidString, name: "Saturday",
                             storageBudgetBytes: 12_000_000_000,
                             createdAt: Date())
        let tracks = (0..<total).map { i in
            GigCrateTrackRow(position: i + 1, trackID: Int64(i + 1),
                             title: "t\(i)", artistNames: "a",
                             durationSec: nil, bpm: nil, camelot: nil,
                             audioCached: i < cached,
                             stemsState: i < stems ? "ready" : "pending",
                             stemsBytes: i < stems ? 1_000 : 0,
                             analysisState: "analyzed")
        }
        return GigCrateDetail(crate: crate, playlistTitle: "Playlist", tracks: tracks)
    }

    private func plan(evicting names: [String]) -> StorageBudgetService.StemPlan {
        StorageBudgetService.StemPlan(currentStemsBytes: 2_000_000_000,
                                      projectedTotal: 11_000_000_000,
                                      budget: 12_000_000_000,
                                      evictions: names.enumerated().map { i, name in
            StorageBudgetService.CrateUsage(crateID: Int64(i + 1), name: name,
                                            stemsBytes: 500_000_000,
                                            lastPerformedAt: Date(timeIntervalSinceNow: -Double(i + 1) * 3600))
        })
    }

    // MARK: - Tests

    func testOpenShowsDetailAndEvictionPreview() async throws {
        let repo = FakeRepository()
        let d = detail(crateID: 7, cached: 3, total: 3, stems: 2)
        repo.details[7] = d
        let lane = FakeLane(plan: plan(evicting: ["Friday"]))
        let model = GigCrateModel(repository: repo, stemService: lane)

        await model.open(crateID: 7)

        XCTAssertEqual(model.detail?.id, 7)
        XCTAssertEqual(model.detail?.cachedCount, 3)
        XCTAssertEqual(model.detail?.stemsReadyCount, 2)
        XCTAssertEqual(lane.planCalls, [7], "opening a crate computes its preview")
        XCTAssertEqual(model.evictionPreview?.evictions.map(\.name), ["Friday"])
        XCTAssertTrue(model.isReady, "3/3 cached is FR-PLIST-9 ready")
    }

    func testPromoteCreatesAndOpensTheCrate() async throws {
        let repo = FakeRepository()
        let lane = FakeLane(plan: plan(evicting: []))
        let model = GigCrateModel(repository: repo, stemService: lane)

        let id = await model.promote(playlistID: 3, name: "Saturday")

        XCTAssertEqual(id, 1)
        XCTAssertEqual(repo.promotedCalls.map(\.0), [3])
        XCTAssertEqual(repo.promotedCalls.map(\.1), ["Saturday"])
        XCTAssertEqual(lane.planCalls, [1], "the promoted crate is opened and previewed")
    }

    func testPrepareRunsTheLaneAndRefreshes() async throws {
        let repo = FakeRepository()
        let d = detail(crateID: 5, cached: 1, total: 2)
        repo.details[5] = d
        repo.cratesValue = [GigCrateRow(id: 5, name: "Saturday", playlistTitle: "P",
                                        trackCount: 2, cachedCount: 1, analyzedCount: 2,
                                        stemsReadyCount: 0, stemsBytes: 0,
                                        storageBudgetBytes: 12_000_000_000,
                                        lastPerformedAt: nil, createdAt: Date())]
        let lane = FakeLane(plan: plan(evicting: []))
        let model = GigCrateModel(repository: repo, stemService: lane)

        await model.open(crateID: 5)
        await model.prepare()

        XCTAssertEqual(lane.laneCalls, [5])
        XCTAssertEqual(model.isPreparing, false, "preparing is honest state, not stuck")
        XCTAssertFalse(model.isReady, "1/2 cached stays not-ready (FR-LIB-8)")
    }

    func testMarkPerformedStampsTheLRUClock() async throws {
        let repo = FakeRepository()
        let lane = FakeLane(plan: plan(evicting: []))
        let model = GigCrateModel(repository: repo, stemService: lane)
        await model.open(crateID: 9)

        await model.markPerformed()

        XCTAssertEqual(repo.performed, [9])
    }

    func testMixesAreNeverEvictableThroughTheServiceRule() {
        XCTAssertFalse(StorageBudgetService.mixesEvictable)
    }
}
