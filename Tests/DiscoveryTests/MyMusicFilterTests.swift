import Testing
import ParsoAudioAnalysis
import TonearmCore
@testable import TonearmDiscovery

@Suite struct MyMusicFilterTests {
    @Test func testBPMAndKeyFilterUsesKnownMetadataOnly() {
        let filter = MyMusicFilter(bpmMin: 120, bpmMax: 130, key: "8A")
        #expect(filter.matches(DJLoadTrackInfo(bpm: 126, camelotKey: "8a")))
        #expect(!filter.matches(DJLoadTrackInfo(bpm: 126, camelotKey: nil)))
        #expect(!filter.matches(DJLoadTrackInfo(bpm: 131, camelotKey: "8A")))
    }

    @Test func testDJMixMatchUsesCompatibleKeyAndEightPercentBPMWindow() {
        let filter = MyMusicFilter(mixBPM: 125, mixKey: "8A")
        #expect(filter.matches(DJLoadTrackInfo(bpm: 130, camelotKey: "8B")))
        #expect(!filter.matches(DJLoadTrackInfo(bpm: 145, camelotKey: "8B")))
        #expect(!filter.matches(DJLoadTrackInfo(bpm: 130, camelotKey: "2A")))
    }

    @Test func testMixPresetRangeIsAppliedAsAnExplicitGenreRange() {
        let filter = MyMusicFilter(mixBPMRange: 120...130)
        #expect(filter.matches(DJLoadTrackInfo(bpm: 120, camelotKey: nil)))
        #expect(filter.matches(DJLoadTrackInfo(bpm: 130, camelotKey: nil)))
        #expect(!filter.matches(DJLoadTrackInfo(bpm: 131, camelotKey: nil)))
        #expect(!filter.matches(DJLoadTrackInfo(bpm: nil, camelotKey: nil)))
    }

    @Test func testMixKeyCanBeSelectedWithoutABPMPreset() {
        let filter = MyMusicFilter(mixKey: "8A")
        #expect(filter.matches(DJLoadTrackInfo(bpm: nil, camelotKey: "8B")))
        #expect(!filter.matches(DJLoadTrackInfo(bpm: nil, camelotKey: "2A")))
    }
}
