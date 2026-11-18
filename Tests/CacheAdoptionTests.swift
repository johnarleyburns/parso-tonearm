import Foundation
import Testing
import ParsoAudioStreaming
@testable import TonearmCore

@Suite struct CacheAdoptionTests {
    private func makeStore() -> SparseCacheStore {
        SparseCacheStore(rootDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("CacheAdoption-\(UUID().uuidString)", isDirectory: true))
    }

    @Test func testAdoptionMakesWholeFileCompleteAndDurable() async throws {
        let cache = makeStore()
        await cache.adoptCompleteFile(byteCount: 1000, for: "k", durable: true)

        let glyph = CacheGlyphState.of(await cache.meta(for: "k"))
        let rangeBytes = await cache.rangeMap(for: "k").totalBytes()
        let total = await cache.totalBytes(for: "k")
        let durable = await cache.isDurable("k")
        #expect(glyph == .cached)
        #expect(rangeBytes == 1000)
        #expect(total == 1000)
        #expect(durable)

        await cache.adoptCompleteFile(byteCount: 1000, for: "k", durable: true)
        let secondRange = await cache.rangeMap(for: "k").totalBytes()
        #expect(secondRange == 1000)
    }

    @Test func testContentLengthAloneRemainsEmpty() async {
        let cache = makeStore()
        await cache.setContentLength(1000, for: "k")
        let glyph = CacheGlyphState.of(await cache.meta(for: "k"))
        guard case .filling = glyph else { return Issue.record("expected .filling, got \(glyph)") }
    }
}
