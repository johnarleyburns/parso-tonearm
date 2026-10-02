import XCTest
@testable import TonearmCore
@testable import TonearmDiscovery

final class MixSourcePickerTests: XCTestCase {
    private func track(_ id: Int64, bpm: Double = 120, key: String = "8A", seconds: Double = 200) -> MixCandidate {
        MixCandidate(trackID: id, bpm: bpm, camelot: key, duration: seconds)
    }

    func testPicksASingleGenreAtRandom() {
        let candidates = (0..<60).map { track(Int64($0)) }
        let genres = Dictionary(uniqueKeysWithValues: candidates.map { ($0.trackID, $0.trackID < 30 ? "House" : "Ambient") })
        var picked = Set<String>()
        for seed in UInt64(0)..<12 {
            let (source, plan) = MixSourcePicker.pick(candidates: candidates, genres: genres, playlists: [],
                                                      recentSources: [], shape: .steady, targetDuration: 1_200, seed: seed)
            guard case .genre(let name) = source else { return XCTFail("expected a genre, got \(source)") }
            picked.insert(name)
            XCTAssertTrue(plan.steps.allSatisfy { genres[$0.trackID] == name }, "a mix stays in one genre")
        }
        XCTAssertEqual(picked, ["House", "Ambient"], "the genre is random per seed")
    }

    func testFallsBackToAPlaylistNotUsedRecentlyThenToTheLibrary() {
        let candidates = (0..<40).map { track(Int64($0)) }
        let tooShortGenre = Dictionary(uniqueKeysWithValues: candidates.prefix(2).map { ($0.trackID, "Jazz") })
        let recent = MixSourcePicker.Playlist(id: 1, title: "Recent", trackIDs: (0..<40).map(Int64.init))
        let fresh = MixSourcePicker.Playlist(id: 2, title: "Fresh", trackIDs: (0..<40).map(Int64.init))
        let (source, _) = MixSourcePicker.pick(candidates: candidates, genres: tooShortGenre, playlists: [recent, fresh],
                                               recentSources: ["playlist:1"], shape: .steady, targetDuration: 1_200, seed: 3)
        XCTAssertEqual(source, .playlist(id: 2, title: "Fresh"))

        let (fallback, plan) = MixSourcePicker.pick(candidates: candidates, genres: [:], playlists: [recent],
                                                    recentSources: ["playlist:1"], shape: .steady,
                                                    targetDuration: 1_200, seed: 3)
        XCTAssertEqual(fallback, .library)
        XCTAssertFalse(plan.steps.isEmpty)
    }

    func testRecentGenresGoLastWhenOthersCanFillTheSession() {
        let candidates = (0..<60).map { track(Int64($0)) }
        let genres = Dictionary(uniqueKeysWithValues: candidates.map { ($0.trackID, $0.trackID < 30 ? "House" : "Ambient") })
        for seed in UInt64(0)..<8 {
            let (source, _) = MixSourcePicker.pick(candidates: candidates, genres: genres, playlists: [],
                                                   recentSources: ["genre:house"], shape: .steady,
                                                   targetDuration: 1_200, seed: seed)
            XCTAssertEqual(source, .genre("Ambient"))
        }
    }

    func testBundledLibraryMixesComeFromOneGenreAndObeyTheRules() {
        let tracks = BuiltInMoodIndexProvider.tracks
        let candidates = tracks.enumerated().compactMap { index, entry -> MixCandidate? in
            guard entry.hasMusicalAnalysis else { return nil }
            return MixCandidate(trackID: Int64(index), bpm: entry.bpm, camelot: entry.key, energy: entry.energy,
                                artist: entry.artist, duration: entry.durationSec)
        }
        let genres = Dictionary(uniqueKeysWithValues: tracks.enumerated().map { (Int64($0.offset), $0.element.genre) })
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.trackID, $0) })
        var genreCount = 0
        for seed in UInt64(1)...8 {
            let (source, plan) = MixSourcePicker.pick(candidates: candidates, genres: genres, playlists: [],
                                                      recentSources: [], shape: .risingBPM,
                                                      targetDuration: 30 * 60, seed: seed)
            if case .genre(let name) = source {
                genreCount += 1
                XCTAssertTrue(plan.steps.allSatisfy { genres[$0.trackID] == name })
            }
            let ordered = plan.steps.compactMap { byID[$0.trackID] }
            for (a, b) in zip(ordered, ordered.dropFirst()) {
                XCTAssertTrue(MixCompatibility.standard.bpmCompatible(a.bpm!, b.bpm!))
                XCTAssertTrue(MixCompatibility.keysCompatible(a.camelot!, b.camelot!))
            }
            let minutes = ordered.reduce(0) { $0 + $1.duration } / 60
            XCTAssertGreaterThanOrEqual(minutes, 27, "seed \(seed) \(source): \(minutes) min")
        }
        XCTAssertEqual(genreCount, 8, "the bundled library always has a genre that can fill 30 minutes")
    }
}
