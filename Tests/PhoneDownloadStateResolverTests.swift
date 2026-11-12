import XCTest
import ParsoAudioStreaming
@testable import TonearmCore

final class PhoneDownloadStateResolverTests: XCTestCase {
    private func meta(total: Int64? = 100, cached: Int64 = 0, complete: Bool = false,
                      durable: Bool? = nil) -> SparseCacheStore.Meta {
        SparseCacheStore.Meta(totalBytes: total, cachedBytes: cached, complete: complete,
                              lastAccessedAt: Date(), createdAt: Date(),
                              rangeMap: ByteRangeMap(), durable: durable)
    }

    func testNilMetaIsNotDownloaded() {
        XCTAssertEqual(PhoneDownloadStateResolver.resolve(meta: nil, blobExists: true), .notDownloaded)
    }

    func testCompleteWithBlobIsDownloaded() {
        let m = meta(cached: 100, complete: true)
        XCTAssertEqual(PhoneDownloadStateResolver.resolve(meta: m, blobExists: true), .downloaded)
    }

    func testDurableWithBlobIsDownloaded() {
        let m = meta(cached: 10, durable: true)
        XCTAssertEqual(PhoneDownloadStateResolver.resolve(meta: m, blobExists: true), .downloaded)
    }

    func testCompleteWithoutBlobFallsThroughToPartial() {
        let m = meta(total: 200, cached: 50, complete: true)
        XCTAssertEqual(PhoneDownloadStateResolver.resolve(meta: m, blobExists: false), .downloading(0.25))
    }

    func testCompleteWithoutBlobAndNoBytesIsNotDownloaded() {
        let m = meta(cached: 0, complete: true)
        XCTAssertEqual(PhoneDownloadStateResolver.resolve(meta: m, blobExists: false), .notDownloaded)
    }

    func testPartialWithKnownTotal() {
        XCTAssertEqual(PhoneDownloadStateResolver.resolve(meta: meta(total: 200, cached: 50), blobExists: false),
                       .downloading(0.25))
    }

    func testPartialWithUnknownTotalUsesFallback() {
        XCTAssertEqual(PhoneDownloadStateResolver.resolve(meta: meta(total: nil, cached: 50), blobExists: false),
                       .downloading(0.05))
    }

    func testZeroBytesIsNotDownloaded() {
        XCTAssertEqual(PhoneDownloadStateResolver.resolve(meta: meta(cached: 0), blobExists: false), .notDownloaded)
    }
}
