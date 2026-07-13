import XCTest
@testable import Tonearm

/// T3.4 — cache preset gating + the downgrade (lazy-eviction) rule.
final class CachePresetGateTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ProEntitlement.clear()
    }

    override func tearDown() {
        ProEntitlement.clear()
        super.tearDown()
    }

    private let twoGB: Int64 = 2 * 1024 * 1024 * 1024
    private let tenGB: Int64 = 10 * 1024 * 1024 * 1024
    private let fiveHundredMB: Int64 = 500 * 1024 * 1024
    private let twoHundredMB: Int64 = 200 * 1024 * 1024

    func testFreeLocksLargePresets() {
        XCTAssertTrue(ProGating.isCachePresetLocked(twoGB, isPro: false))
        XCTAssertTrue(ProGating.isCachePresetLocked(tenGB, isPro: false))
    }

    func testFreeAllowsSmallPresets() {
        XCTAssertFalse(ProGating.isCachePresetLocked(twoHundredMB, isPro: false))
        XCTAssertFalse(ProGating.isCachePresetLocked(fiveHundredMB, isPro: false))
    }

    func testProUnlocksAllPresets() {
        XCTAssertFalse(ProGating.isCachePresetLocked(twoGB, isPro: true))
        XCTAssertFalse(ProGating.isCachePresetLocked(tenGB, isPro: true))
    }

    func testFreeDefaultStays500MB() {
        XCTAssertEqual(ProGating.allowedCacheLimit(fiveHundredMB, isPro: false), fiveHundredMB)
    }

    // Downgrade: entitlement lost → the *setting* clamps back to the free max,
    // but content is not bulk-deleted; it evicts lazily via CacheStore.evictToFit.
    func testDowngradeClampsSettingToFreeMax() {
        XCTAssertEqual(ProGating.allowedCacheLimit(tenGB, isPro: false), fiveHundredMB)
        XCTAssertEqual(ProGating.allowedCacheLimit(twoGB, isPro: false), fiveHundredMB)
        // While Pro, the larger limit is honored.
        XCTAssertEqual(ProGating.allowedCacheLimit(tenGB, isPro: true), tenGB)
    }

    // Lazy eviction: setting a smaller limit drives eviction through the existing
    // CacheStore path rather than a bulk delete on launch.
    func testSettingSmallerLimitEvictsLazilyViaCacheStore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cachegate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = CacheStore(rootDirectory: root, limitBytes: 10 * 1024 * 1024)
        let keyA = "aaaa-mp3"
        let keyB = "bbbb-mp3"
        // Write dummy files so eviction has something to delete.
        let fileA = await store.fileURL(for: keyA)
        let fileB = await store.fileURL(for: keyB)
        try Data(count: 1_000_000).write(to: fileA)
        await store.setContentLength(1_000_000, for: keyA)
        await store.recordWrite(range: 0..<1_000_000, for: keyA)
        try? await Task.sleep(nanoseconds: 5_000_000)
        try Data(count: 1_000_000).write(to: fileB)
        await store.setContentLength(1_000_000, for: keyB)
        await store.recordWrite(range: 0..<1_000_000, for: keyB)

        let before = await store.totalCachedBytes()
        XCTAssertGreaterThan(before, 1_200_000)

        // Shrinking the limit triggers evictToFit (LRU) — no bulk delete.
        await store.setLimit(1_200_000)
        let after = await store.totalCachedBytes()
        XCTAssertLessThanOrEqual(after, 1_200_000)
    }
}
