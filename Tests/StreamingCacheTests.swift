import XCTest
import UniformTypeIdentifiers
@testable import TonearmCore

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

    func testCacheKeyIsStableAcrossLaunches() {
        let url = URL(string: "https://archive.org/download/item/track.mp3")!
        let key = CachingResourceLoader.key(for: url)
        XCTAssertEqual(key, "995d3f45ace3a63922472923d0a45497240725186f0aea72ca31d99e9a2e9818-mp3")
    }

    func testOpusKeyIsDetected() {
        XCTAssertTrue(CacheStore.isOpusKey("abc123-opus"))
        XCTAssertFalse(CacheStore.isOpusKey("abc123-mp3"))
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

    // MARK: - Content-type mapping (T1.2)

    func testContentTypeMapsFLAC() {
        let url = URL(string: "https://archive.org/download/item/track.flac")!
        XCTAssertEqual(CachingResourceLoader.contentType(for: url), "org.xiph.flac")
    }

    // IA download URLs can carry a query string (e.g. ?cnt=0); the UTI mapping
    // must still resolve from the path extension.
    func testContentTypeMapsFLACWithQueryString() {
        let url = URL(string: "https://archive.org/download/item/track.flac?cnt=0&foo=bar")!
        XCTAssertEqual(CachingResourceLoader.contentType(for: url), "org.xiph.flac")
    }

    func testContentTypeMapsMP3WithQueryString() {
        let url = URL(string: "https://ia600.us.archive.org/download/item/track.mp3?cnt=123")!
        XCTAssertEqual(CachingResourceLoader.contentType(for: url), UTType.mp3.identifier)
    }
}
