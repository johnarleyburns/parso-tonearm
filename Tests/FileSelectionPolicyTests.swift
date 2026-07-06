import XCTest
@testable import Tonearm

/// Locks down the FileSelectionPolicy rewrite against the real archive.org
/// shapes that previously produced empty sources and Opus junk.
final class FileSelectionPolicyTests: XCTestCase {

    private func file(_ name: String, format: String, source: String? = nil,
                      original: String? = nil, track: String? = nil,
                      title: String? = nil, height: String? = "0") -> IAFile {
        IAFile(name: name, format: format, source: source, original: original,
               length: "100", size: "1000", title: title, track: track,
               album: nil, artist: nil, bitrate: nil, height: height)
    }

    // Regression: audio files carry height="0"; they must not be rejected.
    func testDoesNotRejectAudioWithHeightZero() {
        let files = [file("Kimiko_-_01_-_Aria.mp3", format: "VBR MP3", source: "original", track: "1", title: "Aria")]
        let tracks = FileSelectionPolicy(preferFLAC: false)
            .selectTracks(files: files, identifier: "The_Open_Goldberg_Variations-11823", itemArtist: nil)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.codec, "MP3")
    }

    // Opus is unsupported and must never appear as a track.
    func testExcludesOpusEntirely() {
        let files = [
            file("side1.opus", format: "Unknown", source: "original"),
            file("01. Movement.mp3", format: "VBR MP3", source: "derivative",
                 original: "segments.json", track: "1", title: "Movement")
        ]
        let tracks = FileSelectionPolicy(preferFLAC: false)
            .selectTracks(files: files, identifier: "album", itemArtist: nil)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.codec, "MP3")
        XCTAssertNil(tracks.first?.unsupportedReason)
    }

    // Per-movement MP3s share a segments.json `original`; grouping by that would
    // collapse them. Grouping by own stem keeps them distinct.
    func testMultiMovementDerivativesStayDistinct() {
        let files = [
            file("01.01 Allegro.mp3", format: "VBR MP3", source: "derivative",
                 original: "x_segments.json", track: "1", title: "Allegro"),
            file("01.02 Adagio.mp3", format: "VBR MP3", source: "derivative",
                 original: "x_segments.json", track: "2", title: "Adagio"),
            file("01.03 Rondo.mp3", format: "VBR MP3", source: "derivative",
                 original: "x_segments.json", track: "3", title: "Rondo")
        ]
        let tracks = FileSelectionPolicy(preferFLAC: false)
            .selectTracks(files: files, identifier: "beethoven-sonatas", itemArtist: nil)
        XCTAssertEqual(tracks.count, 3)
    }

    // Raw side-long rips embed the item identifier in their filename and must be
    // excluded so they don't duplicate the finer movement tracks.
    func testExcludesIdentifierSideRips() {
        let id = "lp_beethoven_sonatas_0"
        let files = [
            file("disc1/\(id)_disc1side1.flac", format: "24bit Flac", source: "original", track: "01"),
            file("disc1/01.01 Allegro.mp3", format: "VBR MP3", source: "derivative",
                 original: "\(id)_segments.json", track: "1", title: "Allegro")
        ]
        let tracks = FileSelectionPolicy(preferFLAC: false)
            .selectTracks(files: files, identifier: id, itemArtist: nil)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.codec, "MP3")
    }

    // MP3 is chosen by default; the FLAC in the same group is kept as an alternate.
    func testMP3DefaultWithFLACAlternate() {
        let files = [
            file("01 Prelude.flac", format: "24bit Flac", source: "original", track: "1", title: "Prelude"),
            file("01 Prelude.mp3", format: "VBR MP3", source: "derivative",
                 original: "01 Prelude.flac", track: "1", title: "Prelude")
        ]
        let tracks = FileSelectionPolicy(preferFLAC: false)
            .selectTracks(files: files, identifier: "wtc", itemArtist: nil)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.codec, "MP3")
        XCTAssertNotNil(tracks.first?.altFlacURL)
        XCTAssertEqual(tracks.first?.altFlacURL?.absoluteString.hasSuffix(".flac"), true)
    }

    func testPreferFLACChoosesFLAC() {
        let files = [
            file("01 Prelude.flac", format: "24bit Flac", source: "original", track: "1", title: "Prelude"),
            file("01 Prelude.mp3", format: "VBR MP3", source: "derivative",
                 original: "01 Prelude.flac", track: "1", title: "Prelude")
        ]
        let tracks = FileSelectionPolicy(preferFLAC: true)
            .selectTracks(files: files, identifier: "wtc", itemArtist: nil)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.codec, "FLAC")
    }
}
