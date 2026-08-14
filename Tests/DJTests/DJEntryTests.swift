import XCTest
@testable import TonearmCore
@testable import TonearmDJ

/// Plan 5.1 — the app entry point (spec §49.3a). The reachability invariant is
/// an executable contract: every user-facing DJ surface is on the route table
/// the app root binds to, and the performance surface constructs from the
/// root's inputs and gates on the entitlement store — free users get the real
/// dimmed surface + lock chip, Pro users the live decks (App. T.3, §40.4).
@MainActor
final class DJEntryTests: XCTestCase {

    private struct EmptyEntitlementSource: EntitlementSource {
        func currentTransactions() async throws -> [TransactionFact] { [] }
        func transactionUpdates() -> AsyncStream<TransactionFact> { AsyncStream { _ in } }
    }

    private func makeStore(isPro: Bool) -> EntitlementStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DJEntryTests-\(UUID().uuidString)", isDirectory: true)
        let cacheURL = dir.appendingPathComponent("entitlement-cache.json")
        EntitlementCacheStore(fileURL: cacheURL).save(
            EntitlementCache(isPro: isPro, source: isPro ? .purchased : .none, timestamp: Date()))
        return EntitlementStore(entitlementSource: EmptyEntitlementSource(),
                                cacheStore: EntitlementCacheStore(fileURL: cacheURL))
    }

    // MARK: - §49.3a reachability

    func testPerformanceSurfaceIsOnTheReachableRouteTable() {
        // Rule 1: a feature is not done until it is reachable from the app
        // root. The decks (the performance surface) and the library are the
        // DJ route table the app root binds to.
        XCTAssertEqual(DJEntryModel.reachableDestinations, [.decks, .library, .mixes])
        XCTAssertTrue(DJEntryModel.reachableDestinations.contains(.decks),
                      "the performance surface must be reachable from the app root (§49.3a)")
    }

    func testEntryModelPresentsAPushedDestination() {
        let entry = DJEntryModel()
        XCTAssertTrue(entry.path.isEmpty, "the home is the empty path")
        entry.present(.decks)
        XCTAssertEqual(entry.path, [.decks])
        entry.present(.library)
        XCTAssertEqual(entry.path, [.decks, .library])
        entry.popToHome()
        XCTAssertTrue(entry.path.isEmpty)
    }

    // MARK: - The workspace constructs and gates

    func testAssemblyBuildsAWorkspaceThatGatesOnTheStore() async throws {
        let proModel = await makeModel(isPro: true)
        let pro = try XCTUnwrap(proModel)
        XCTAssertTrue(pro.isDecksEnabled, "a Pro user reaches the live decks (App. T.3)")

        let freeModel = await makeModel(isPro: false)
        let free = try XCTUnwrap(freeModel)
        XCTAssertFalse(free.isDecksEnabled,
                       "a free user sees the real dimmed surface + lock chip (§40.4)")
        XCTAssertFalse(free.isPro)
    }

    private func makeModel(isPro: Bool) async -> WorkspaceModel? {
        await DJWorkspaceAssembly.makeModel(store: makeStore(isPro: isPro))
    }
}
