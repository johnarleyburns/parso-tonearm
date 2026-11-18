import Testing
import ParsoAudioStreaming
@testable import TonearmCore

@Suite struct PhoneDownloadStateResolverTests {
    private func meta(total: Int64? = 100, cached: Int64 = 0, complete: Bool = false,
                      durable: Bool? = nil) -> SparseCacheStore.Meta {
        SparseCacheStore.Meta(totalBytes: total, cachedBytes: cached, complete: complete,
                              lastAccessedAt: Date(), createdAt: Date(),
                              rangeMap: ByteRangeMap(), durable: durable)
    }

    @Test func testNilMetaIsNotDownloaded() {
        #expect(PhoneDownloadStateResolver.resolve(meta: nil, blobExists: true) == .notDownloaded)
    }

    @Test func testCompleteWithBlobIsDownloaded() {
        let m = meta(cached: 100, complete: true)
        #expect(PhoneDownloadStateResolver.resolve(meta: m, blobExists: true) == .downloaded)
    }

    @Test func testDurableWithBlobIsDownloaded() {
        let m = meta(cached: 10, durable: true)
        #expect(PhoneDownloadStateResolver.resolve(meta: m, blobExists: true) == .downloaded)
    }

    @Test func testCompleteWithoutBlobFallsThroughToPartial() {
        let m = meta(total: 200, cached: 50, complete: true)
        #expect(PhoneDownloadStateResolver.resolve(meta: m, blobExists: false) == .downloading(0.25))
    }

    @Test func testCompleteWithoutBlobAndNoBytesIsNotDownloaded() {
        let m = meta(cached: 0, complete: true)
        #expect(PhoneDownloadStateResolver.resolve(meta: m, blobExists: false) == .notDownloaded)
    }

    @Test func testPartialWithKnownTotal() {
        #expect(PhoneDownloadStateResolver.resolve(meta: meta(total: 200, cached: 50), blobExists: false)
                       == .downloading(0.25))
    }

    @Test func testPartialWithUnknownTotalUsesFallback() {
        #expect(PhoneDownloadStateResolver.resolve(meta: meta(total: nil, cached: 50), blobExists: false)
                       == .downloading(0.05))
    }

    @Test func testZeroBytesIsNotDownloaded() {
        #expect(PhoneDownloadStateResolver.resolve(meta: meta(cached: 0), blobExists: false) == .notDownloaded)
    }
}
