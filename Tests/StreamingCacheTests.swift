import XCTest
@testable import Tonearm

final class StreamingCacheTests: XCTestCase {

    func testCacheURLPreservesPath() {
        let remote = URL(string: "https://archive.org/download/foo/track.mp3")!
        let cached = CachingResourceLoader.cacheURL(for: remote)
        XCTAssertEqual(cached.scheme, "tonearm-cache")
        XCTAssertEqual(cached.path, remote.path)
    }

    func testCacheKeyIsDeterministic() {
        let url = URL(string: "https://archive.org/download/item/track.mp3")!
        let k1 = CachingResourceLoader.key(for: url)
        let k2 = CachingResourceLoader.key(for: url)
        XCTAssertEqual(k1, k2)
    }

    func testCacheKeyIncludesExtension() {
        let url = URL(string: "https://archive.org/download/item/track.flac")!
        let key = CachingResourceLoader.key(for: url)
        XCTAssertTrue(key.hasSuffix("flac"))
    }

    func testByteRangeMapInsertAndQuery() {
        var map = ByteRangeMap()
        map.insert(0..<1024)
        XCTAssertEqual(map.contiguousBytes(from: 0), 1024)
        XCTAssertEqual(map.contiguousBytes(from: 512), 512)
        XCTAssertEqual(map.contiguousBytes(from: 1024), 0)
    }

    func testByteRangeMapMerge() {
        var map = ByteRangeMap()
        map.insert(0..<1024)
        map.insert(512..<2048)
        XCTAssertEqual(map.contiguousBytes(from: 0), 2048)
    }

    func testByteRangeMapTotalBytes() {
        var map = ByteRangeMap()
        map.insert(0..<1000)
        map.insert(2000..<3000)
        XCTAssertEqual(map.totalBytes(), 2000)
    }

    func testByteRangeMapCovers() {
        var map = ByteRangeMap()
        map.insert(0..<4096)
        XCTAssertTrue(map.covers(total: 4096))
        XCTAssertFalse(map.covers(total: 8192))
    }
}
