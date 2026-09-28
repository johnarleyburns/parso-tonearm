import XCTest
import ParsoAudioAnalysis
import TonearmCore
@testable import TonearmDiscovery

final class MyMusicFilterTests: XCTestCase {
    func testBPMAndKeyFilterUsesKnownMetadataOnly() {
        let filter = MyMusicFilter(bpmMin: 120, bpmMax: 130, key: "8A")
        XCTAssertTrue(filter.matches(DJLoadTrackInfo(bpm: 126, camelotKey: "8a")))
        XCTAssertFalse(filter.matches(DJLoadTrackInfo(bpm: 126, camelotKey: nil)))
        XCTAssertFalse(filter.matches(DJLoadTrackInfo(bpm: 131, camelotKey: "8A")))
    }

    func testDJMixMatchUsesCompatibleKeyAndEightPercentBPMWindow() {
        let filter = MyMusicFilter(mixBPM: 125, mixKey: "8A")
        XCTAssertTrue(filter.matches(DJLoadTrackInfo(bpm: 130, camelotKey: "8B")))
        XCTAssertFalse(filter.matches(DJLoadTrackInfo(bpm: 145, camelotKey: "8B")))
        XCTAssertFalse(filter.matches(DJLoadTrackInfo(bpm: 130, camelotKey: "2A")))
    }
}
