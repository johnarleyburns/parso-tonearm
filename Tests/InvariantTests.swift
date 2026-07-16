import XCTest
@testable import TonearmCore

final class InvariantTests: XCTestCase {

    // Invariant #3: URL layer allowlist — only archive.org hosts.
    func testHostAllowlist() {
        XCTAssertTrue(IAClient.isAllowedHost("archive.org"))
        XCTAssertTrue(IAClient.isAllowedHost("www.archive.org"))
        XCTAssertTrue(IAClient.isAllowedHost("ia800304.us.archive.org"))
        XCTAssertFalse(IAClient.isAllowedHost("example.com"))
        XCTAssertFalse(IAClient.isAllowedHost("archive.org.evil.com"))
        XCTAssertFalse(IAClient.isAllowedHost("web.archive.org.hax.io"))
    }
}

final class ByteRangeMapTests: XCTestCase {

    func testInsertAndContiguous() {
        var map = ByteRangeMap()
        map.insert(0..<100)
        XCTAssertEqual(map.contiguousBytes(from: 0), 100)
        XCTAssertEqual(map.totalBytes(), 100)
    }

    func testMergeAdjacent() {
        var map = ByteRangeMap()
        map.insert(0..<100)
        map.insert(100..<200)
        XCTAssertEqual(map.ranges.count, 1)
        XCTAssertEqual(map.contiguousBytes(from: 0), 200)
    }

    func testMergeOverlapping() {
        var map = ByteRangeMap()
        map.insert(0..<100)
        map.insert(50..<150)
        XCTAssertEqual(map.ranges.count, 1)
        XCTAssertEqual(map.totalBytes(), 150)
    }

    func testDisjoint() {
        var map = ByteRangeMap()
        map.insert(0..<100)
        map.insert(200..<300)
        XCTAssertEqual(map.ranges.count, 2)
        XCTAssertEqual(map.contiguousBytes(from: 0), 100)
        XCTAssertEqual(map.contiguousBytes(from: 150), 0)
    }

    func testCoversFull() {
        var map = ByteRangeMap()
        map.insert(0..<500)
        XCTAssertTrue(map.covers(total: 500))
        XCTAssertFalse(map.covers(total: 600))
    }

    func testCodableRoundTrip() {
        var map = ByteRangeMap()
        map.insert(0..<100)
        map.insert(200..<250)
        let restored = ByteRangeMap(data: map.encoded())
        XCTAssertEqual(map, restored)
    }
}

final class FileSelectionTests: XCTestCase {

    func testPrefersFLACOverMP3() {
        let files = [
            IAFile(name: "track01.mp3", format: "VBR MP3", source: "derivative",
                   original: "track01.flac", length: "212", size: "5000000",
                   title: "Prélude", track: "1", album: nil, artist: nil, bitrate: "220", height: nil),
            IAFile(name: "track01.flac", format: "FLAC", source: "original",
                   original: nil, length: "212", size: "25000000",
                   title: "Prélude", track: "1", album: nil, artist: nil, bitrate: nil, height: nil)
        ]
        let tracks = FileSelectionPolicy(preferFLAC: true)
            .selectTracks(files: files, identifier: "x", itemArtist: "Bach")
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.codec, "FLAC")
    }

    func testSkipsSpectrogramsAndSamples() {
        let files = [
            IAFile(name: "track01_sample.mp3", format: "MP3", source: nil, original: nil,
                   length: "30", size: "1000", title: nil, track: nil, album: nil, artist: nil, bitrate: nil, height: nil),
            IAFile(name: "spectrogram.png", format: "PNG", source: nil, original: nil,
                   length: nil, size: "1000", title: nil, track: nil, album: nil, artist: nil, bitrate: nil, height: "500"),
            IAFile(name: "track01.flac", format: "FLAC", source: "original", original: nil,
                   length: "212", size: "25000000", title: "A", track: "1", album: nil, artist: nil, bitrate: nil, height: nil)
        ]
        let tracks = FileSelectionPolicy(preferFLAC: true)
            .selectTracks(files: files, identifier: "x", itemArtist: nil)
        XCTAssertEqual(tracks.count, 1)
    }
}
