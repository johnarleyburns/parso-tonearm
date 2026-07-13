import XCTest

@testable import Tonearm

final class MetadataNormalizerTests: XCTestCase {

    func testCommonKeysWinOverVendorConflicts() {
        let metadata = MetadataNormalizer.normalize(
            items: [
                item(key: "TIT2", keySpace: "org.id3", stringValue: "ID3 Title"),
                item(commonKey: "title", identifier: "commonIdentifierTitle", stringValue: "Common Title"),
                item(key: "©ART", keySpace: "com.apple.itunes", stringValue: "iTunes Artist"),
                item(commonKey: "artist", identifier: "commonIdentifierArtist", stringValue: "Common Artist"),
            ],
            fallbackFilename: "Fallback.flac")

        XCTAssertEqual(metadata.title, "Common Title")
        XCTAssertEqual(metadata.artist, "Common Artist")
    }

    func testID3KeysNormalizeAllCoreFields() {
        let metadata = MetadataNormalizer.normalize(
            items: [
                item(key: "TIT2", keySpace: "org.id3", stringValue: "Song"),
                item(key: "TPE1", keySpace: "org.id3", stringValue: "Track Artist"),
                item(key: "TPE2", keySpace: "org.id3", stringValue: "Album Artist"),
                item(key: "TALB", keySpace: "org.id3", stringValue: "Album"),
                item(key: "TCON", keySpace: "org.id3", stringValue: "Jazz"),
                item(key: "TCOM", keySpace: "org.id3", stringValue: "Composer"),
                item(key: "TRCK", keySpace: "org.id3", stringValue: "1/12"),
                item(key: "TPOS", keySpace: "org.id3", stringValue: "2/3"),
                item(key: "TDRC", keySpace: "org.id3", stringValue: "1977-05-08"),
            ],
            fallbackFilename: "fallback.mp3")

        XCTAssertEqual(metadata.title, "Song")
        XCTAssertEqual(metadata.artist, "Track Artist")
        XCTAssertEqual(metadata.albumArtist, "Album Artist")
        XCTAssertEqual(metadata.albumTitle, "Album")
        XCTAssertEqual(metadata.genre, "Jazz")
        XCTAssertEqual(metadata.composer, "Composer")
        XCTAssertEqual(metadata.trackNo, 1)
        XCTAssertEqual(metadata.discNo, 2)
        XCTAssertEqual(metadata.year, 1977)
    }

    func testITunesKeysAndPackedNumbersNormalize() {
        let metadata = MetadataNormalizer.normalize(
            items: [
                item(key: "©nam", keySpace: "com.apple.itunes", stringValue: "iTunes Song"),
                item(key: "©ART", keySpace: "com.apple.itunes", stringValue: "iTunes Artist"),
                item(key: "aART", keySpace: "com.apple.itunes", stringValue: "iTunes Album Artist"),
                item(key: "©alb", keySpace: "com.apple.itunes", stringValue: "iTunes Album"),
                item(key: "©gen", keySpace: "com.apple.itunes", stringValue: "Rock"),
                item(key: "©wrt", keySpace: "com.apple.itunes", stringValue: "Writer"),
                item(key: "trkn", keySpace: "com.apple.itunes", dataValue: Data([0, 0, 0, 7, 0, 12, 0, 0])),
                item(key: "disk", keySpace: "com.apple.itunes", dataValue: Data([0, 0, 0, 2, 0, 3, 0, 0])),
                item(key: "©day", keySpace: "com.apple.itunes", stringValue: "1984"),
            ],
            fallbackFilename: "fallback.m4a")

        XCTAssertEqual(metadata.title, "iTunes Song")
        XCTAssertEqual(metadata.artist, "iTunes Artist")
        XCTAssertEqual(metadata.albumArtist, "iTunes Album Artist")
        XCTAssertEqual(metadata.albumTitle, "iTunes Album")
        XCTAssertEqual(metadata.genre, "Rock")
        XCTAssertEqual(metadata.composer, "Writer")
        XCTAssertEqual(metadata.trackNo, 7)
        XCTAssertEqual(metadata.discNo, 2)
        XCTAssertEqual(metadata.year, 1984)
    }

    func testMissingMetadataFallsBackToFilename() {
        let metadata = MetadataNormalizer.normalize(
            items: [],
            fallbackFilename: "01 - Stephan Bodzin - Singularity.flac")

        XCTAssertEqual(metadata.trackNo, 1)
        XCTAssertEqual(metadata.artist, "Stephan Bodzin")
        XCTAssertEqual(metadata.title, "Singularity")
    }

    func testGarbageBytesDoNotCreateNumbers() {
        let metadata = MetadataNormalizer.normalize(
            items: [
                item(key: "trkn", keySpace: "com.apple.itunes", dataValue: Data([0xff])),
                item(key: "disk", keySpace: "com.apple.itunes", dataValue: Data([0xfe, 0xed])),
            ],
            fallbackFilename: "No Number.wav")

        XCTAssertNil(metadata.trackNo)
        XCTAssertNil(metadata.discNo)
        XCTAssertEqual(metadata.title, "No Number")
    }

    func testFieldBagNormalizesIAStyleMetadata() {
        var fields = MetadataNormalizer.FieldBag()
        fields.title = ["  IA Song  "]
        fields.artist = ["Track Artist"]
        fields.albumTitle = ["IA Album"]
        fields.albumArtist = ["VA"]
        fields.genre = ["Folk"]
        fields.composer = ["The Composer"]
        fields.trackNumber = ["03/10"]
        fields.discNumber = ["1/2"]
        fields.year = ["2020-01-02"]
        fields.bitDepthOrBitrate = ["320"]

        let metadata = MetadataNormalizer.normalize(fields: fields, fallbackFilename: "fallback.mp3")

        XCTAssertEqual(metadata.title, "IA Song")
        XCTAssertEqual(metadata.artist, "Track Artist")
        XCTAssertEqual(metadata.albumTitle, "IA Album")
        XCTAssertEqual(metadata.albumArtist, "Various Artists")
        XCTAssertEqual(metadata.genre, "Folk")
        XCTAssertEqual(metadata.composer, "The Composer")
        XCTAssertEqual(metadata.trackNo, 3)
        XCTAssertEqual(metadata.discNo, 1)
        XCTAssertEqual(metadata.year, 2020)
        XCTAssertEqual(metadata.bitDepthOrBitrate, "320 kbps")
    }

    private func item(
        key: String? = nil,
        commonKey: String? = nil,
        identifier: String? = nil,
        keySpace: String? = nil,
        stringValue: String? = nil,
        numberValue: Double? = nil,
        dataValue: Data? = nil
    ) -> MetadataNormalizer.Item {
        MetadataNormalizer.Item(
            key: key,
            commonKey: commonKey,
            identifier: identifier,
            keySpace: keySpace,
            stringValue: stringValue,
            numberValue: numberValue,
            dataValue: dataValue)
    }
}
