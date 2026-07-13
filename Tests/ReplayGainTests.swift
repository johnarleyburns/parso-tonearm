import GRDB
import XCTest

@testable import Tonearm

final class ReplayGainTests: XCTestCase {
    func testParsesVorbisCommentTags() {
        let tags = ReplayGain.parse(items: [
            item(key: "REPLAYGAIN_TRACK_GAIN", stringValue: "-6.54 dB"),
            item(key: "REPLAYGAIN_ALBUM_GAIN", stringValue: "-5.25 dB"),
            item(key: "REPLAYGAIN_TRACK_PEAK", stringValue: "0.912345"),
            item(key: "REPLAYGAIN_ALBUM_PEAK", stringValue: "0.987654"),
        ])

        XCTAssertEqual(tags.trackGainDB, -6.54)
        XCTAssertEqual(tags.albumGainDB, -5.25)
        XCTAssertEqual(tags.trackPeak, 0.912345)
        XCTAssertEqual(tags.albumPeak, 0.987654)
    }

    func testParsesID3TXXXFrames() {
        let tags = ReplayGain.parse(items: [
            item(key: "TXXX", keySpace: "org.id3", stringValue: "REPLAYGAIN_TRACK_GAIN\u{0}-7.00 dB"),
            item(key: "TXXX", keySpace: "org.id3", stringValue: "REPLAYGAIN_TRACK_PEAK=0.75"),
        ])

        XCTAssertEqual(tags.trackGainDB, -7)
        XCTAssertEqual(tags.trackPeak, 0.75)
    }

    func testParsesITunesFreeformAtoms() {
        let tags = ReplayGain.parse(items: [
            item(identifier: "----:com.apple.iTunes:REPLAYGAIN_ALBUM_GAIN", keySpace: "itsk",
                 stringValue: "-4.50"),
            item(identifier: "----:com.apple.iTunes:REPLAYGAIN_ALBUM_PEAK", keySpace: "itsk",
                 stringValue: "0.80"),
        ])

        XCTAssertEqual(tags.albumGainDB, -4.5)
        XCTAssertEqual(tags.albumPeak, 0.8)
    }

    func testGainFormsWithAndWithoutDBSuffix() {
        XCTAssertEqual(ReplayGain.parseGainDB("-6.54 dB"), -6.54)
        XCTAssertEqual(ReplayGain.parseGainDB("-6.54"), -6.54)
        XCTAssertEqual(ReplayGain.parseGainDB("+3,00 dB"), 3)
    }

    func testMissingPeakUsesUnclippedGain() {
        let tags = ReplayGain.Tags(trackGainDB: -6, albumGainDB: nil,
                                   trackPeak: nil, albumPeak: nil)
        XCTAssertEqual(
            ReplayGain.appliedGain(mode: .track, tags: tags),
            pow(10, -6 / 20),
            accuracy: 0.000_001)
    }

    func testClippingPreventionEngages() {
        let tags = ReplayGain.Tags(trackGainDB: 6, albumGainDB: nil,
                                   trackPeak: 0.8, albumPeak: nil)
        XCTAssertEqual(
            ReplayGain.appliedGain(mode: .track, tags: tags, preventClipping: true),
            1.25,
            accuracy: 0.000_001)
    }

    func testAlbumModeFallsBackToTrackGain() {
        let tags = ReplayGain.Tags(trackGainDB: -3, albumGainDB: nil,
                                   trackPeak: 0.9, albumPeak: nil)
        XCTAssertEqual(
            ReplayGain.appliedGain(mode: .album, tags: tags),
            ReplayGain.appliedGain(mode: .track, tags: tags),
            accuracy: 0.000_001)
    }

    func testPreampArithmetic() {
        let tags = ReplayGain.Tags(trackGainDB: -6, albumGainDB: nil,
                                   trackPeak: nil, albumPeak: nil)
        XCTAssertEqual(
            ReplayGain.appliedGain(mode: .track, tags: tags, preampDB: 3),
            pow(10, -3 / 20),
            accuracy: 0.000_001)
    }

    func testNoTagsAreExactlyUnityGain() {
        XCTAssertEqual(ReplayGain.appliedGain(mode: .track, tags: .empty, preampDB: 6), 1)
        XCTAssertEqual(ReplayGain.appliedGain(mode: .album, tags: .empty), 1)
    }

    func testOffModeIsUnityEvenWithTags() {
        let tags = ReplayGain.Tags(trackGainDB: 12, albumGainDB: 12,
                                   trackPeak: 0.1, albumPeak: 0.1)
        XCTAssertEqual(ReplayGain.appliedGain(mode: .off, tags: tags), 1)
    }

    func testMetadataNormalizerCarriesFieldBagReplayGain() {
        var fields = MetadataNormalizer.FieldBag()
        fields.replayGainTrackGain = ["-8.00 dB"]
        fields.replayGainAlbumGain = ["-5.00"]
        fields.replayGainTrackPeak = ["0.7"]
        fields.replayGainAlbumPeak = ["0.9"]

        let metadata = MetadataNormalizer.normalize(fields: fields, fallbackFilename: "song.flac")

        XCTAssertEqual(metadata.rgTrackGain, -8)
        XCTAssertEqual(metadata.rgAlbumGain, -5)
        XCTAssertEqual(metadata.rgTrackPeak, 0.7)
        XCTAssertEqual(metadata.rgAlbumPeak, 0.9)
    }

    func testMigrationV10AddsReplayGainColumns() throws {
        let dbQueue = try DatabaseQueue()
        try Schema.migrator(upTo: "v9").migrate(dbQueue)
        try Schema.migrator().migrate(dbQueue)

        let columns = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(track)")
                .compactMap { row -> String? in row["name"] }
        }

        XCTAssertTrue(columns.contains("rgTrackGain"))
        XCTAssertTrue(columns.contains("rgAlbumGain"))
        XCTAssertTrue(columns.contains("rgTrackPeak"))
        XCTAssertTrue(columns.contains("rgAlbumPeak"))
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
