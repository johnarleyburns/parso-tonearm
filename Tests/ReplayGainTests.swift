import GRDB
import Testing

@testable import TonearmCore

@Suite struct ReplayGainTests {
    @Test func testParsesVorbisCommentTags() {
        let tags = ReplayGain.parse(items: [
            item(key: "REPLAYGAIN_TRACK_GAIN", stringValue: "-6.54 dB"),
            item(key: "REPLAYGAIN_ALBUM_GAIN", stringValue: "-5.25 dB"),
            item(key: "REPLAYGAIN_TRACK_PEAK", stringValue: "0.912345"),
            item(key: "REPLAYGAIN_ALBUM_PEAK", stringValue: "0.987654"),
        ])

        #expect(tags.trackGainDB == -6.54)
        #expect(tags.albumGainDB == -5.25)
        #expect(tags.trackPeak == 0.912345)
        #expect(tags.albumPeak == 0.987654)
    }

    @Test func testParsesID3TXXXFrames() {
        let tags = ReplayGain.parse(items: [
            item(key: "TXXX", keySpace: "org.id3", stringValue: "REPLAYGAIN_TRACK_GAIN\u{0}-7.00 dB"),
            item(key: "TXXX", keySpace: "org.id3", stringValue: "REPLAYGAIN_TRACK_PEAK=0.75"),
        ])

        #expect(tags.trackGainDB == -7)
        #expect(tags.trackPeak == 0.75)
    }

    @Test func testParsesITunesFreeformAtoms() {
        let tags = ReplayGain.parse(items: [
            item(identifier: "----:com.apple.iTunes:REPLAYGAIN_ALBUM_GAIN", keySpace: "itsk",
                 stringValue: "-4.50"),
            item(identifier: "----:com.apple.iTunes:REPLAYGAIN_ALBUM_PEAK", keySpace: "itsk",
                 stringValue: "0.80"),
        ])

        #expect(tags.albumGainDB == -4.5)
        #expect(tags.albumPeak == 0.8)
    }

    @Test func testGainFormsWithAndWithoutDBSuffix() {
        #expect(ReplayGain.parseGainDB("-6.54 dB") == -6.54)
        #expect(ReplayGain.parseGainDB("-6.54") == -6.54)
        #expect(ReplayGain.parseGainDB("+3,00 dB") == 3)
    }

    @Test func testMissingPeakUsesUnclippedGain() {
        let tags = ReplayGain.Tags(trackGainDB: -6, albumGainDB: nil,
                                   trackPeak: nil, albumPeak: nil)
        #expect(
            abs(ReplayGain.appliedGain(mode: .track, tags: tags) - pow(10, -6 / 20)) <= 0.000_001)
    }

    @Test func testClippingPreventionEngages() {
        let tags = ReplayGain.Tags(trackGainDB: 6, albumGainDB: nil,
                                   trackPeak: 0.8, albumPeak: nil)
        #expect(
            abs(ReplayGain.appliedGain(mode: .track, tags: tags, preventClipping: true) - 1.25) <= 0.000_001)
    }

    @Test func testAlbumModeFallsBackToTrackGain() {
        let tags = ReplayGain.Tags(trackGainDB: -3, albumGainDB: nil,
                                   trackPeak: 0.9, albumPeak: nil)
        #expect(
            abs(ReplayGain.appliedGain(mode: .album, tags: tags) -
            ReplayGain.appliedGain(mode: .track, tags: tags)) <= 0.000_001)
    }

    @Test func testPreampArithmetic() {
        let tags = ReplayGain.Tags(trackGainDB: -6, albumGainDB: nil,
                                   trackPeak: nil, albumPeak: nil)
        #expect(
            abs(ReplayGain.appliedGain(mode: .track, tags: tags, preampDB: 3) - pow(10, -3 / 20)) <= 0.000_001)
    }

    @Test func testNoTagsAreExactlyUnityGain() {
        #expect(ReplayGain.appliedGain(mode: .track, tags: .empty, preampDB: 6) == 1)
        #expect(ReplayGain.appliedGain(mode: .album, tags: .empty) == 1)
    }

    @Test func testOffModeIsUnityEvenWithTags() {
        let tags = ReplayGain.Tags(trackGainDB: 12, albumGainDB: 12,
                                   trackPeak: 0.1, albumPeak: 0.1)
        #expect(ReplayGain.appliedGain(mode: .off, tags: tags) == 1)
    }

    @Test func testMetadataNormalizerCarriesFieldBagReplayGain() {
        var fields = MetadataNormalizer.FieldBag()
        fields.replayGainTrackGain = ["-8.00 dB"]
        fields.replayGainAlbumGain = ["-5.00"]
        fields.replayGainTrackPeak = ["0.7"]
        fields.replayGainAlbumPeak = ["0.9"]

        let metadata = MetadataNormalizer.normalize(fields: fields, fallbackFilename: "song.flac")

        #expect(metadata.rgTrackGain == -8)
        #expect(metadata.rgAlbumGain == -5)
        #expect(metadata.rgTrackPeak == 0.7)
        #expect(metadata.rgAlbumPeak == 0.9)
    }

    @Test func testMigrationV10AddsReplayGainColumns() throws {
        let dbQueue = try DatabaseQueue()
        try Schema.migrator(upTo: "v9").migrate(dbQueue)
        try Schema.migrator().migrate(dbQueue)

        let columns = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(track)")
                .compactMap { row -> String? in row["name"] }
        }

        #expect(columns.contains("rgTrackGain"))
        #expect(columns.contains("rgAlbumGain"))
        #expect(columns.contains("rgTrackPeak"))
        #expect(columns.contains("rgAlbumPeak"))
    }

    private func item(
        key: String? = nil,
        commonKey: String? = nil,
        identifier: String? = nil,
        keySpace: String? = nil,
        stringValue: String? = nil,
        dataValue: Data? = nil
    ) -> ReplayGain.TagItem {
        ReplayGain.TagItem(
            key: key,
            commonKey: commonKey,
            identifier: identifier,
            keySpace: keySpace,
            stringValue: stringValue,
            dataValue: dataValue)
    }
}
