import XCTest
@testable import TonearmCore

final class CacheAdoptionTests: XCTestCase {
    func testAdoptionMakesWholeFileCompleteAndPinned() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CacheAdoption-\(UUID().uuidString)", isDirectory: true)
        let cache = CacheStore(rootDirectory: root)
        await cache.adoptCompleteFile(byteCount: 1000, for: "k")
        let state = await cache.state(for: "k")
        let rangeBytes = await cache.rangeMap(for: "k").totalBytes()
        let total = await cache.totalBytes(for: "k")
        let pinned = await cache.isPinned("k")
        XCTAssertEqual(state, .cached)
        XCTAssertEqual(rangeBytes, 1000)
        XCTAssertEqual(total, 1000)
        XCTAssertTrue(pinned)
        await cache.adoptCompleteFile(byteCount: 1000, for: "k")
        let secondRangeBytes = await cache.rangeMap(for: "k").totalBytes()
        XCTAssertEqual(secondRangeBytes, 1000)
    }

    func testContentLengthAloneRemainsEmpty() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CacheLength-\(UUID().uuidString)", isDirectory: true)
        let cache = CacheStore(rootDirectory: root)
        await cache.setContentLength(1000, for: "k")
        let state = await cache.state(for: "k")
        XCTAssertEqual(state, .filling(0))
    }
}
