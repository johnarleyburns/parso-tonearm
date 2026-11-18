import Testing
@testable import TonearmCore

@Suite struct KeepPlayingPlannerTests {
    private typealias C = KeepPlayingPicker.Candidate

    private func attempt(queueCount: Int, index: Int, auto: Int) -> Bool {
        KeepPlayingPicker.shouldAttemptExtension(
            enabled: true, isAmbient: false, repeatMode: .off, queueCount: queueCount, index: index,
            lastAttemptedIndex: nil, extensionInFlight: false, unplayedAutoCount: auto)
    }

    @Test func testBudget() {
        #expect(KeepPlayingPicker.horizonBudget(unplayedAutoCount: 0) == 10)
        #expect(KeepPlayingPicker.horizonBudget(unplayedAutoCount: 7) == 3)
        #expect(KeepPlayingPicker.horizonBudget(unplayedAutoCount: 10) == 0)
        #expect(!attempt(queueCount: 11, index: 0, auto: 10))
    }

    @Test func testOrdinaryEntriesTriggerOnlyWhenTwoRemain() {
        #expect(!attempt(queueCount: 5, index: 0, auto: 0))
        #expect(!attempt(queueCount: 4, index: 0, auto: 0))
        #expect(attempt(queueCount: 3, index: 0, auto: 0))
    }

    @Test func testAutoTailLowTriggers() {
        // 1 ordinary + 7 auto: budget 3, fires, appends at most 3.
        #expect(attempt(queueCount: 9, index: 0, auto: 7))
        #expect(KeepPlayingPicker.horizonBudget(unplayedAutoCount: 7) == 3)
        // 6 ordinary + 3 auto fires on the auto trigger; 6 ordinary + 4 auto does not.
        #expect(attempt(queueCount: 10, index: 0, auto: 3))
        #expect(!attempt(queueCount: 11, index: 0, auto: 4))
        let plan = KeepPlayingPicker.plan(
            candidates: (1...8).map { C(id: Int64($0)) }, excluded: [], lookback: [], budget: 3)
        #expect(plan.picks.count == 3)
    }

    @Test func testArtistLookback() {
        let lookback = [C(id: 1, artist: "A"), C(id: 2, artist: "B"), C(id: 3, artist: "C")]
        let plan = KeepPlayingPicker.plan(
            candidates: [C(id: 10, artist: "C"), C(id: 11, artist: "A"), C(id: 12, artist: "D")],
            excluded: [], lookback: lookback, budget: 1)
        #expect(plan.picks.map(\.id) == [12])
        let older = [C(id: 0, artist: "A")] + lookback.dropFirst()
        #expect(KeepPlayingPicker.plan(
            candidates: [C(id: 11, artist: "A")], excluded: [], lookback: older + [C(id: 4, artist: "Z")],
            budget: 1).picks.map(\.id) == [11])
    }

    @Test func testAlbumLookback() {
        let lookback = [C(id: 1, album: "X"), C(id: 2, album: "Y"), C(id: 3, album: "Z")]
        let plan = KeepPlayingPicker.plan(
            candidates: [C(id: 10, album: "Z"), C(id: 11, album: "W")], excluded: [],
            lookback: lookback, budget: 1)
        #expect(plan.picks.map(\.id) == [11])
        let four = [C(id: 0, album: "X")] + lookback.dropFirst() + [C(id: 4, album: "Q")]
        #expect(KeepPlayingPicker.plan(
            candidates: [C(id: 12, album: "X")], excluded: [], lookback: four, budget: 1).picks.map(\.id) == [12])
    }

    @Test func testRelaxesAlbumBeforeArtist() {
        let lookback = [C(id: 1, artist: "A", album: "X")]
        let plan = KeepPlayingPicker.plan(
            candidates: [C(id: 10, artist: "A", album: "Q"), C(id: 11, artist: "B", album: "X"),
                         C(id: 12, artist: "B", album: "Y")],
            excluded: [], lookback: lookback, budget: 1)
        #expect(plan.picks.map(\.id) == [12])
        let only = KeepPlayingPicker.plan(
            candidates: [C(id: 10, artist: "A", album: "Q"), C(id: 11, artist: "B", album: "X")],
            excluded: [], lookback: lookback, budget: 1)
        #expect(only.picks.map(\.id) == [11])
        #expect(only.relaxedAlbum)
        #expect(!only.relaxedArtist)
    }

    @Test func testRelaxingArtistNeverReturnsExcluded() {
        let lookback = [C(id: 1, artist: "A", album: "X")]
        let plan = KeepPlayingPicker.plan(
            candidates: [C(id: 1, artist: "B"), C(id: 10, artist: "A", album: "X"), C(id: 11, artist: "A")],
            excluded: [1, 2], lookback: lookback, budget: 1)
        #expect(plan.picks.map(\.id) == [10])
        #expect(plan.relaxedArtist)
        #expect(KeepPlayingPicker.plan(
            candidates: [C(id: 1), C(id: 2)], excluded: [1, 2], lookback: [], budget: 5).picks == [])
    }

    @Test func testMissingMetadataNeverExcludesAndOrderIsPreserved() {
        let lookback = [C(id: 1)]
        let plan = KeepPlayingPicker.plan(
            candidates: [C(id: 30), C(id: 10), C(id: 20)], excluded: [10], lookback: lookback, budget: 5)
        #expect(plan.picks.map(\.id) == [30, 20])
    }

    @Test func testBatchSizeSettingIsGone() throws {
        let needle = "keepPlaying" + "BatchSize"
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for dir in ["Sources", "Tests"] {
            let e = FileManager.default.enumerator(at: root.appendingPathComponent(dir), includingPropertiesForKeys: nil)
            while let url = e?.nextObject() as? URL, url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                #expect(!text.contains(needle), "\(url.lastPathComponent) still references the removed setting")
            }
        }
    }
}
