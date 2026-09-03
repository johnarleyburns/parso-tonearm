import XCTest
import ParsoAudioStreaming
@testable import TonearmCore

final class CacheAdoptionTests: XCTestCase {
    private func makeStore() -> SparseCacheStore {
        SparseCacheStore(rootDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("CacheAdoption-\(UUID().uuidString)", isDirectory: true))
    }

    func testAdoptionMakesWholeFileCompleteAndDurable() async throws {
        let cache = makeStore()
        await cache.adoptCompleteFile(byteCount: 1000, for: "k", durable: true)

        let glyph = CacheGlyphState.of(await cache.meta(for: "k"))
        let rangeBytes = await cache.rangeMap(for: "k").totalBytes()
        let total = await cache.totalBytes(for: "k")
        let durable = await cache.isDurable("k")
        XCTAssertEqual(glyph, .cached)
        XCTAssertEqual(rangeBytes, 1000)
        XCTAssertEqual(total, 1000)
        XCTAssertTrue(durable)

        await cache.adoptCompleteFile(byteCount: 1000, for: "k", durable: true)
        let secondRange = await cache.rangeMap(for: "k").totalBytes()
        XCTAssertEqual(secondRange, 1000)
    }

    func testContentLengthAloneRemainsEmpty() async {
        let cache = makeStore()
        await cache.setContentLength(1000, for: "k")
        let glyph = CacheGlyphState.of(await cache.meta(for: "k"))
        guard case .filling = glyph else { return XCTFail("expected .filling, got \(glyph)") }
    }
}
