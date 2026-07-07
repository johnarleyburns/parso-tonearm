import XCTest
@testable import Tonearm

final class BuiltInContentProviderTests: XCTestCase {

    func testThreeAmbientTracks() {
        let tracks = BuiltInContentProvider.tracks
        XCTAssertEqual(tracks.count, 3)
        let titles = Set(tracks.map { $0.title })
        XCTAssertTrue(titles.contains("Rainy Day"))
        XCTAssertTrue(titles.contains("Ocean Waves"))
        XCTAssertTrue(titles.contains("Flowing Water"))
    }

    func testBundledAudioExists() {
        for ambient in BuiltInContentProvider.tracks {
            let url = BuiltInContentProvider.bundledAudioURL(forChannelId: ambient.channelId)
            XCTAssertNotNil(url, "Missing bundled audio for \(ambient.channelId)")
        }
    }

    func testBundledVideoExists() {
        for ambient in BuiltInContentProvider.tracks {
            let url = BuiltInContentProvider.bundledVideoURL(forChannelId: ambient.channelId)
            XCTAssertNotNil(url, "Missing bundled video for \(ambient.channelId)")
        }
    }

    func testTrackRowConstruction() {
        let rows = BuiltInContentProvider.allTrackRows
        XCTAssertEqual(rows.count, 3)

        for row in rows {
            XCTAssertEqual(row.asset?.kind, .builtIn)
            XCTAssertNotNil(row.asset?.relPath)
            XCTAssertEqual(row.source?.id, BuiltInContentProvider.ambientSourceId)
            XCTAssertEqual(row.track.sourceId, BuiltInContentProvider.ambientSourceId)
            XCTAssertEqual(row.album?.title, "Ambient Sounds")
            XCTAssertEqual(row.source?.licenseText, "CC0 Public Domain")
        }
    }

    func testRowForSpecificTrack() {
        let rain = BuiltInContentProvider.tracks.first { $0.channelId == "ambient-rain" }!
        let row = BuiltInContentProvider.row(for: rain)
        XCTAssertEqual(row.track.title, "Rainy Day")
        XCTAssertEqual(row.album?.artist, "speakwithanimals")
        XCTAssertEqual(row.track.codec, "WAV")
        XCTAssertEqual(row.asset?.relPath, "ambient-rain.wav")
    }

    func testBundledURLPreference() {
        let audioName = BuiltInContentProvider.bundledAudioName(for: "ambient-rain")
        XCTAssertEqual(audioName, "ambient-rain.wav")
    }

    func testAllChannelsUnique() {
        let ids = BuiltInContentProvider.tracks.map { $0.channelId }
        XCTAssertEqual(ids.count, Set(ids).count)
    }
}
