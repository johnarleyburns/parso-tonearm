#if !os(watchOS)
import Foundation
import GRDB
import ParsoAudioNeural
import XCTest

@testable import TonearmCore
@testable import TonearmDiscovery

/// Plan §9 input-side contract: debounce, generation guard, cancellation of a
/// superseded query.
final class DiscoverySearchCoordinatorTests: XCTestCase {
    private func makeService() async throws -> (SearchService, URL) {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("coord-\(UUID().uuidString).bin")
        let queue = try SearchFixture.makeQueue()
        try await queue.write { db in
            let s = try SearchFixture.seedSource(db)
            let t = try SearchFixture.seedTrack(db, sourceId: s, title: "only")
            let a = try SearchFixture.seedAsset(db, trackId: t)
            try SearchFixture.seedEmbedding(db, trackId: t, assetId: a, vector: [1, 0, 0, 0, 0, 0, 0, 0])
        }
        let models = ModelManager(resourceProvider: { .unavailable })
        await models.injectModelForTesting(
            FixedTextModel(dimensions: 8, vector: [1, 0, 0, 0, 0, 0, 0, 0]))
        return (
            SearchService(
                writer: queue, index: VectorIndex(writer: queue, cacheURL: cacheURL),
                models: models),
            cacheURL)
    }

    func testOnlyTheNewestSubmissionDelivers() async throws {
        let (service, cacheURL) = try await makeService()
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let coordinator = DiscoverySearchCoordinator(
            service: service, debounce: .milliseconds(20))

        let delivered = DeliveredBox()
        for i in 0..<5 {
            await coordinator.submit(DiscoverySearchQuery(text: "q\(i)")) { response in
                delivered.record(response)
            }
        }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(delivered.count, 1, "only the final submission should deliver")
        XCTAssertEqual(delivered.last?.state, .ready)
    }

    func testCancelPendingSuppressesDelivery() async throws {
        let (service, cacheURL) = try await makeService()
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let coordinator = DiscoverySearchCoordinator(
            service: service, debounce: .milliseconds(50))

        let delivered = DeliveredBox()
        await coordinator.submit(DiscoverySearchQuery(text: "q")) { r in delivered.record(r) }
        await coordinator.cancelPending()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(delivered.count, 0)
    }
}

private final class DeliveredBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [DiscoverySearchResponse] = []
    func record(_ r: DiscoverySearchResponse) { lock.lock(); items.append(r); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
    var last: DiscoverySearchResponse? { lock.lock(); defer { lock.unlock() }; return items.last }
}
#endif
