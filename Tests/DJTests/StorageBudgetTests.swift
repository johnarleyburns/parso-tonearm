import XCTest

@testable import TonearmDJ

/// Commit 5.9 — the §43.6 storage budget (plan 5.9, decision 11, FR-ANL-9,
/// AT-STEM-\*): the pure budget decision — LRU by `lastPerformedAt`, the
/// eviction preview shown BEFORE any eviction, protected crates never evicted,
/// and mixes never evictable. All pure math; no database, no files.
final class StorageBudgetTests: XCTestCase {

    // MARK: - Defaults (§43.6 table)

    func testDefaultBudgetsPerDeviceClass() {
        XCTAssertEqual(StorageBudgetService.defaultStemBudget(deviceClass: .iphone8GB),
                       4_000_000_000)
        XCTAssertEqual(StorageBudgetService.defaultStemBudget(deviceClass: .iphone6GB),
                       4_000_000_000)
        XCTAssertEqual(StorageBudgetService.defaultStemBudget(deviceClass: .ipad),
                       12_000_000_000)
        XCTAssertEqual(StorageBudgetService.defaultWaveformBudget(deviceClass: .iphone8GB),
                       300_000_000)
        XCTAssertEqual(StorageBudgetService.defaultWaveformBudget(deviceClass: .ipad),
                       600_000_000)
    }

    func testEstimatedPerTrackMatchesTheSpecArithmetic() {
        // §43.6: "a 300-track crate at ~13 MB/track is ~4 GB" — inside the
        // 12 GB iPad budget, comfortably outside the 4 GB phone one.
        let projected = 300 * StorageBudgetService.estimatedStemsBytesPerTrack
        XCTAssertLessThan(projected, 4_000_000_000)
        XCTAssertLessThan(projected, 12_000_000_000)
        XCTAssertEqual(Double(projected) / 1_000_000_000, 3.9, accuracy: 0.01)
    }

    func testMixesNeverEvictable() {
        XCTAssertFalse(StorageBudgetService.mixesEvictable,
                       "mixes are user content and cannot be re-derived (§43.6)")
    }

    // MARK: - The pure plan

    private func usage(_ id: Int64, _ name: String, _ bytes: Int64,
                       performed date: Date?) -> StorageBudgetService.CrateUsage {
        StorageBudgetService.CrateUsage(crateID: id, name: name,
                                        stemsBytes: bytes, lastPerformedAt: date)
    }

    private func date(hoursAgo: Double) -> Date {
        Date(timeIntervalSinceNow: -hoursAgo * 3600)
    }

    func testFitsWithinBudgetEvictsNothing() {
        let plan = StorageBudgetService.plan(addingBytes: 1_000_000_000,
                                             budget: 12_000_000_000,
                                             currentStemsBytes: 2_000_000_000,
                                             usages: [usage(1, "old", 1_000_000_000,
                                                            performed: date(hoursAgo: 48))])
        XCTAssertTrue(plan.fits)
        XCTAssertFalse(plan.needsEviction)
        XCTAssertTrue(plan.evictions.isEmpty,
                      "an addition that fits shows an empty preview — nothing evicted")
        XCTAssertEqual(plan.projectedTotal, 3_000_000_000)
        XCTAssertEqual(plan.freeBytes, 10_000_000_000)
    }

    func testEvictsOldestPerformedFirst() {
        // Current usage 11 GB + 2 GB addition = 13 GB against a 12 GB budget.
        let older = usage(1, "performed 2 days ago", 1_000_000_000,
                          performed: date(hoursAgo: 48))
        let newer = usage(2, "performed 1 hour ago", 1_000_000_000,
                          performed: date(hoursAgo: 1))
        let plan = StorageBudgetService.plan(addingBytes: 2_000_000_000,
                                             budget: 12_000_000_000,
                                             currentStemsBytes: 11_000_000_000,
                                             usages: [newer, older])
        XCTAssertTrue(plan.needsEviction)
        XCTAssertEqual(plan.evictions.map(\.name), ["performed 2 days ago"],
                       "the oldest-performed crate is evicted first (LRU)")
        XCTAssertTrue(plan.fits, "dropping 1 GB reclaims the 1 GB overrun")
    }

    func testEvictionOrderIsChronologicalNotInputOrder() {
        let mostRecent = usage(1, "recent", 500_000_000, performed: date(hoursAgo: 1))
        let middle = usage(2, "middle", 500_000_000, performed: date(hoursAgo: 24))
        let oldest = usage(3, "oldest", 500_000_000, performed: date(hoursAgo: 96))
        // Input deliberately scrambled: the decision must sort by recency.
        // Budget 8.25 GB over a 9 GB projection → a 0.75 GB overrun, exactly the
        // two oldest crates' 1.0 GB, so eviction stops after the second.
        let plan = StorageBudgetService.plan(addingBytes: 6_000_000_000,
                                             budget: 8_250_000_000,
                                             currentStemsBytes: 3_000_000_000,
                                             usages: [mostRecent, oldest, middle])
        XCTAssertEqual(plan.evictions.map(\.name), ["oldest", "middle"],
                       "evictions run oldest-performed first regardless of input order")
    }

    func testNeverPerformedCrateEvictsFirst() {
        let neverPerformed = usage(1, "never", 500_000_000, performed: nil)
        let performed = usage(2, "old", 500_000_000, performed: date(hoursAgo: 72))
        // A 0.5 GB overrun — exactly the never-performed crate, so eviction
        // stops after it: a crate never performed is the oldest.
        let plan = StorageBudgetService.plan(addingBytes: 5_000_000_000,
                                             budget: 5_500_000_000,
                                             currentStemsBytes: 1_000_000_000,
                                             usages: [performed, neverPerformed])
        XCTAssertEqual(plan.evictions.map(\.name), ["never"],
                       "a crate never performed is the oldest")
    }

    func testProtectedCratesAreNeverEvicted() {
        let protected = usage(1, "protected (loaded deck)", 1_000_000_000,
                              performed: date(hoursAgo: 96))
        let older = usage(2, "candidate", 1_000_000_000, performed: date(hoursAgo: 120))
        let plan = StorageBudgetService.plan(addingBytes: 4_000_000_000,
                                             budget: 5_000_000_000,
                                             currentStemsBytes: 3_000_000_000,
                                             usages: [protected, older],
                                             protectedIDs: [1])
        XCTAssertFalse(plan.evictions.contains { $0.crateID == 1 },
                       "a crate backing a loaded deck is never evicted (§43.6)")
        XCTAssertEqual(plan.evictions.map(\.name), ["candidate"])
    }

    func testCannotFitEvenAfterEvictingEverything() {
        let only = usage(1, "only", 500_000_000, performed: date(hoursAgo: 24))
        let plan = StorageBudgetService.plan(addingBytes: 4_000_000_000,
                                             budget: 1_000_000_000,
                                             currentStemsBytes: 500_000_000,
                                             usages: [only])
        XCTAssertTrue(plan.needsEviction)
        XCTAssertFalse(plan.fits,
                       "even evicting the only candidate cannot close a 3.5 GB gap")
    }

    func testProtectedSetIncludesTheCrateBeingPrepared() {
        let candidate = usage(1, "candidate", 1_000_000_000,
                              performed: date(hoursAgo: 24))
        let preparing = usage(2, "the crate being prepared", 0,
                              performed: nil)
        let plan = StorageBudgetService.plan(addingBytes: 2_000_000_000,
                                             budget: 2_000_000_000,
                                             currentStemsBytes: 1_000_000_000,
                                             usages: [candidate, preparing],
                                             protectedIDs: [2])
        XCTAssertEqual(plan.evictions.map(\.name), ["candidate"])
        XCTAssertFalse(plan.evictions.contains { $0.crateID == 2 })
    }

    // MARK: - Display

    func testBytesText() {
        XCTAssertEqual(StorageBudgetService.bytesText(1_900_000_000), "1.9 GB")
        XCTAssertEqual(StorageBudgetService.bytesText(412_000_000), "412 MB")
        XCTAssertEqual(StorageBudgetService.bytesText(0), "0 B")
    }
}
