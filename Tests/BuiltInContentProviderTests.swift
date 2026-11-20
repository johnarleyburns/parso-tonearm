import Testing
@testable import TonearmCore

@Suite struct BuiltInContentProviderTests {

    @Test func testThreeAmbientTracks() {
        let tracks = BuiltInContentProvider.tracks
        #expect(tracks.count == 3)
        let titles = Set(tracks.map { $0.title })
        #expect(titles.contains("Rainy Day"))
        #expect(titles.contains("Ocean Waves"))
        #expect(titles.contains("Flowing Water"))
    }

    @Test func testBundledAudioExists() {
        for ambient in BuiltInContentProvider.tracks {
            let url = BuiltInContentProvider.bundledAudioURL(forChannelId: ambient.channelId)
            #expect(url != nil, "Missing bundled audio for \(ambient.channelId)")
        }
    }

    @Test func testBundledVideoExists() {
        for ambient in BuiltInContentProvider.tracks {
            let url = BuiltInContentProvider.bundledVideoURL(forChannelId: ambient.channelId)
            #expect(url != nil, "Missing bundled video for \(ambient.channelId)")
        }
    }

    @Test func testTrackRowConstruction() {
        let rows = BuiltInContentProvider.allTrackRows
        #expect(rows.count == 3)

        for row in rows {
            #expect(row.asset?.kind == .builtIn)
            #expect(row.asset?.relPath != nil)
            #expect(row.source?.id == BuiltInContentProvider.ambientSourceId)
            #expect(row.track.sourceId == BuiltInContentProvider.ambientSourceId)
            #expect(row.album?.title == "Ambient Sounds")
            #expect(row.source?.licenseText == "CC0 Public Domain")
        }
    }

    @Test func testRowForSpecificTrack() {
        let rain = BuiltInContentProvider.tracks.first { $0.channelId == "ambient-rain" }!
        let row = BuiltInContentProvider.row(for: rain)
        #expect(row.track.title == "Rainy Day")
        #expect(row.album?.artist == "speakwithanimals")
        #expect(row.track.codec == "WAV")
        #expect(row.asset?.relPath == "ambient-rain.wav")
    }

    @Test func testBundledURLPreference() {
        let audioName = BuiltInContentProvider.bundledAudioName(for: "ambient-rain")
        #expect(audioName == "ambient-rain.wav")
    }

    @Test func testAllChannelsUnique() {
        let ids = BuiltInContentProvider.tracks.map { $0.channelId }
        #expect(ids.count == Set(ids).count)
    }
}
