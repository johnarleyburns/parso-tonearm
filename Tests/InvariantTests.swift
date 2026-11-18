import Foundation
import Testing
import ParsoAudioStreaming
@testable import TonearmCore

@Suite struct InvariantTests {

    // Invariant #3: URL layer allowlist — only archive.org hosts.
    @Test func testHostAllowlist() {
        #expect(IAClient.isAllowedHost("archive.org"))
        #expect(IAClient.isAllowedHost("www.archive.org"))
        #expect(IAClient.isAllowedHost("ia800304.us.archive.org"))
        #expect(!IAClient.isAllowedHost("example.com"))
        #expect(!IAClient.isAllowedHost("archive.org.evil.com"))
        #expect(!IAClient.isAllowedHost("web.archive.org.hax.io"))
    }
}

@Suite struct ByteRangeMapTests {

    @Test func testInsertAndContiguous() {
        var map = ByteRangeMap()
        map.insert(0..<100)
        #expect(map.contiguousBytes(from: 0) == 100)
        #expect(map.totalBytes() == 100)
    }

    @Test func testMergeAdjacent() {
        var map = ByteRangeMap()
        map.insert(0..<100)
        map.insert(100..<200)
        #expect(map.ranges.count == 1)
        #expect(map.contiguousBytes(from: 0) == 200)
    }

    @Test func testMergeOverlapping() {
        var map = ByteRangeMap()
        map.insert(0..<100)
        map.insert(50..<150)
        #expect(map.ranges.count == 1)
        #expect(map.totalBytes() == 150)
    }

    @Test func testDisjoint() {
        var map = ByteRangeMap()
        map.insert(0..<100)
        map.insert(200..<300)
        #expect(map.ranges.count == 2)
        #expect(map.contiguousBytes(from: 0) == 100)
        #expect(map.contiguousBytes(from: 150) == 0)
    }

    @Test func testCoversFull() {
        var map = ByteRangeMap()
        map.insert(0..<500)
        #expect(map.covers(total: 500))
        #expect(!map.covers(total: 600))
    }

    @Test func testCodableRoundTrip() {
        var map = ByteRangeMap()
        map.insert(0..<100)
        map.insert(200..<250)
        let restored = ByteRangeMap(data: map.encoded())
        #expect(map == restored)
    }
}

@Suite struct FileSelectionTests {

    @Test func testPrefersFLACOverMP3() {
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
        #expect(tracks.count == 1)
        #expect(tracks.first?.codec == "FLAC")
    }

    @Test func testSkipsSpectrogramsAndSamples() {
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
        #expect(tracks.count == 1)
    }
}
