import Foundation
import Testing

@testable import TonearmCore

@Suite struct MetadataNormalizerTests {

    @Test func testCommonKeysWinOverVendorConflicts() {
        let metadata = MetadataNormalizer.normalize(
            items: [
                item(key: "TIT2", keySpace: "org.id3", stringValue: "ID3 Title"),
                item(commonKey: "title", identifier: "commonIdentifierTitle", stringValue: "Common Title"),
                item(key: "©ART", keySpace: "com.apple.itunes", stringValue: "iTunes Artist"),
                item(commonKey: "artist", identifier: "commonIdentifierArtist", stringValue: "Common Artist"),
            ],
            fallbackFilename: "Fallback.flac")

        #expect(metadata.title == "Common Title")
        #expect(metadata.artist == "Common Artist")
    }

    @Test func testID3KeysNormalizeAllCoreFields() {
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

        #expect(metadata.title == "Song")
        #expect(metadata.artist == "Track Artist")
        #expect(metadata.albumArtist == "Album Artist")
        #expect(metadata.albumTitle == "Album")
        #expect(metadata.genre == "Jazz")
        #expect(metadata.composer == "Composer")
        #expect(metadata.trackNo == 1)
        #expect(metadata.discNo == 2)
        #expect(metadata.year == 1977)
    }

    @Test func testITunesKeysAndPackedNumbersNormalize() {
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

        #expect(metadata.title == "iTunes Song")
        #expect(metadata.artist == "iTunes Artist")
        #expect(metadata.albumArtist == "iTunes Album Artist")
        #expect(metadata.albumTitle == "iTunes Album")
        #expect(metadata.genre == "Rock")
        #expect(metadata.composer == "Writer")
        #expect(metadata.trackNo == 7)
        #expect(metadata.discNo == 2)
        #expect(metadata.year == 1984)
    }

    @Test func testMissingMetadataFallsBackToFilename() {
        let metadata = MetadataNormalizer.normalize(
            items: [],
            fallbackFilename: "01 - Stephan Bodzin - Singularity.flac")

        #expect(metadata.trackNo == 1)
        #expect(metadata.artist == "Stephan Bodzin")
        #expect(metadata.title == "Singularity")
    }

    @Test func testGarbageBytesDoNotCreateNumbers() {
        let metadata = MetadataNormalizer.normalize(
            items: [
                item(key: "trkn", keySpace: "com.apple.itunes", dataValue: Data([0xff])),
                item(key: "disk", keySpace: "com.apple.itunes", dataValue: Data([0xfe, 0xed])),
            ],
            fallbackFilename: "No Number.wav")

        #expect(metadata.trackNo == nil)
        #expect(metadata.discNo == nil)
        #expect(metadata.title == "No Number")
    }

    @Test func testFieldBagNormalizesIAStyleMetadata() {
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

        #expect(metadata.title == "IA Song")
        #expect(metadata.artist == "Track Artist")
        #expect(metadata.albumTitle == "IA Album")
        #expect(metadata.albumArtist == "Various Artists")
        #expect(metadata.genre == "Folk")
        #expect(metadata.composer == "The Composer")
        #expect(metadata.trackNo == 3)
        #expect(metadata.discNo == 1)
        #expect(metadata.year == 2020)
        #expect(metadata.bitDepthOrBitrate == "320 kbps")
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
