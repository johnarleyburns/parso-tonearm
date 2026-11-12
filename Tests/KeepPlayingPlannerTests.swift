import XCTest
@testable import TonearmCore

final class KeepPlayingPlannerTests: XCTestCase {
    private typealias C = KeepPlayingPicker.Candidate

    private func attempt(queueCount: Int, index: Int, auto: Int) -> Bool {
        KeepPlayingPicker.shouldAttemptExtension(
            enabled: true, isAmbient: false, repeatMode: .off, queueCount: queueCount, index: index,
            lastAttemptedIndex: nil, extensionInFlight: false, unplayedAutoCount: auto)
    }

    func testBudget() {
        XCTAssertEqual(KeepPlayingPicker.horizonBudget(unplayedAutoCount: 0), 10)
        XCTAssertEqual(KeepPlayingPicker.horizonBudget(unplayedAutoCount: 7), 3)
        XCTAssertEqual(KeepPlayingPicker.horizonBudget(unplayedAutoCount: 10), 0)
        XCTAssertFalse(attempt(queueCount: 11, index: 0, auto: 10))
    }

    func testOrdinaryEntriesTriggerOnlyWhenTwoRemain() {
        XCTAssertFalse(attempt(queueCount: 5, index: 0, auto: 0))
        XCTAssertFalse(attempt(queueCount: 4, index: 0, auto: 0))
        XCTAssertTrue(attempt(queueCount: 3, index: 0, auto: 0))
    }

    func testAutoTailLowTriggers() {
        // 1 ordinary + 7 auto: budget 3, fires, appends at most 3.
        XCTAssertTrue(attempt(queueCount: 9, index: 0, auto: 7))
        XCTAssertEqual(KeepPlayingPicker.horizonBudget(unplayedAutoCount: 7), 3)
        // 6 ordinary + 3 auto fires on the auto trigger; 6 ordinary + 4 auto does not.
        XCTAssertTrue(attempt(queueCount: 10, index: 0, auto: 3))
        XCTAssertFalse(attempt(queueCount: 11, index: 0, auto: 4))
        let plan = KeepPlayingPicker.plan(
            candidates: (1...8).map { C(id: Int64($0)) }, excluded: [], lookback: [], budget: 3)
        XCTAssertEqual(plan.picks.count, 3)
    }

    func testArtistLookback() {
        let lookback = [C(id: 1, artist: "A"), C(id: 2, artist: "B"), C(id: 3, artist: "C")]
        let plan = KeepPlayingPicker.plan(
            candidates: [C(id: 10, artist: "C"), C(id: 11, artist: "A"), C(id: 12, artist: "D")],
            excluded: [], lookback: lookback, budget: 1)
        XCTAssertEqual(plan.picks.map(\.id), [12])
        let older = [C(id: 0, artist: "A")] + lookback.dropFirst()
        XCTAssertEqual(KeepPlayingPicker.plan(
            candidates: [C(id: 11, artist: "A")], excluded: [], lookback: older + [C(id: 4, artist: "Z")],
            budget: 1).picks.map(\.id), [11])
    }

    func testAlbumLookback() {
        let lookback = [C(id: 1, album: "X"), C(id: 2, album: "Y"), C(id: 3, album: "Z")]
        let plan = KeepPlayingPicker.plan(
            candidates: [C(id: 10, album: "Z"), C(id: 11, album: "W")], excluded: [],
            lookback: lookback, budget: 1)
        XCTAssertEqual(plan.picks.map(\.id), [11])
        let four = [C(id: 0, album: "X")] + lookback.dropFirst() + [C(id: 4, album: "Q")]
        XCTAssertEqual(KeepPlayingPicker.plan(
            candidates: [C(id: 12, album: "X")], excluded: [], lookback: four, budget: 1).picks.map(\.id), [12])
    }

    func testRelaxesAlbumBeforeArtist() {
        let lookback = [C(id: 1, artist: "A", album: "X")]
        let plan = KeepPlayingPicker.plan(
            candidates: [C(id: 10, artist: "A", album: "Q"), C(id: 11, artist: "B", album: "X"),
                         C(id: 12, artist: "B", album: "Y")],
            excluded: [], lookback: lookback, budget: 1)
        XCTAssertEqual(plan.picks.map(\.id), [12])
        let only = KeepPlayingPicker.plan(
            candidates: [C(id: 10, artist: "A", album: "Q"), C(id: 11, artist: "B", album: "X")],
            excluded: [], lookback: lookback, budget: 1)
        XCTAssertEqual(only.picks.map(\.id), [11])
        XCTAssertTrue(only.relaxedAlbum)
        XCTAssertFalse(only.relaxedArtist)
    }

    func testRelaxingArtistNeverReturnsExcluded() {
        let lookback = [C(id: 1, artist: "A", album: "X")]
        let plan = KeepPlayingPicker.plan(
            candidates: [C(id: 1, artist: "B"), C(id: 10, artist: "A", album: "X"), C(id: 11, artist: "A")],
            excluded: [1, 2], lookback: lookback, budget: 1)
        XCTAssertEqual(plan.picks.map(\.id), [10])
        XCTAssertTrue(plan.relaxedArtist)
        XCTAssertEqual(KeepPlayingPicker.plan(
            candidates: [C(id: 1), C(id: 2)], excluded: [1, 2], lookback: [], budget: 5).picks, [])
    }

    func testMissingMetadataNeverExcludesAndOrderIsPreserved() {
        let lookback = [C(id: 1)]
        let plan = KeepPlayingPicker.plan(
            candidates: [C(id: 30), C(id: 10), C(id: 20)], excluded: [10], lookback: lookback, budget: 5)
        XCTAssertEqual(plan.picks.map(\.id), [30, 20])
    }

    func testBatchSizeSettingIsGone() throws {
        let needle = "keepPlaying" + "BatchSize"
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for dir in ["Sources", "Tests"] {
            let e = FileManager.default.enumerator(at: root.appendingPathComponent(dir), includingPropertiesForKeys: nil)
            while let url = e?.nextObject() as? URL, url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                XCTAssertFalse(text.contains(needle), "\(url.lastPathComponent) still references the removed setting")
            }
        }
    }
}
