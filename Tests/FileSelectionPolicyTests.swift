import XCTest
@testable import Tonearm

/// Locks down the FileSelectionPolicy rewrite against the real archive.org
/// shapes that previously produced empty sources and Opus junk.
final class FileSelectionPolicyTests: XCTestCase {

    private func file(_ name: String, format: String, source: String? = nil,
                      original: String? = nil, track: String? = nil,
                      title: String? = nil, height: String? = "0",
                      album: String? = nil, artist: String? = nil,
                      genre: String? = nil, composer: String? = nil,
                      disc: String? = nil, year: String? = nil,
                      bitrate: String? = nil) -> IAFile {
        IAFile(name: name, format: format, source: source, original: original,
               length: "100", size: "1000", title: title, track: track,
               album: album, artist: artist, bitrate: bitrate, height: height,
               genre: genre, composer: composer, disc: disc, year: year)
    }

    // Regression: audio files carry height="0"; they must not be rejected.
    func testDoesNotRejectAudioWithHeightZero() {
        let files = [file("Kimiko_-_01_-_Aria.mp3", format: "VBR MP3", source: "original", track: "1", title: "Aria")]
        let tracks = FileSelectionPolicy(preferFLAC: false)
            .selectTracks(files: files, identifier: "The_Open_Goldberg_Variations-11823", itemArtist: nil)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.codec, "MP3")
    }

    // Opus is a free format via the CAF pipeline (D9), but it is not cold-streamed:
    // a mixed MP3+Opus group still cold-plays the instant MP3 and exposes the Opus
    // derivative for the prefetch/remux upgrade path.
    func testOpusAllowedButNotColdStreamed() {
        let files = [
            file("01. Movement.opus", format: "Opus", source: "derivative",
                 original: "01. Movement.flac", track: "1", title: "Movement"),
            file("01. Movement.mp3", format: "VBR MP3", source: "derivative",
                 original: "01. Movement.flac", track: "1", title: "Movement")
        ]
        let tracks = FileSelectionPolicy(preferFLAC: false)
            .selectTracks(files: files, identifier: "album", itemArtist: nil)
        XCTAssertEqual(tracks.count, 1)
        // Cold play stays on the instant MP3, never Opus.
        XCTAssertEqual(tracks.first?.codec, "MP3")
        XCTAssertFalse(tracks.first?.requiresRemux ?? true)
        XCTAssertNil(tracks.first?.unsupportedReason)
        // The Opus derivative is exposed for the prefetch/remux upgrade path.
        XCTAssertNotNil(tracks.first?.opusURL)
        XCTAssertEqual(tracks.first?.opusURL?.absoluteString.hasSuffix(".opus"), true)
    }

    // An Opus-only group still produces a track (not filtered out), but that track
    // is flagged as requiring remux-before-play since it can't cold-stream.
    func testOpusOnlyGroupProducesRemuxTrack() {
        let files = [
            file("side1.opus", format: "Opus", source: "original", track: "1", title: "Side 1")
        ]
        let tracks = FileSelectionPolicy(preferFLAC: false)
            .selectTracks(files: files, identifier: "album", itemArtist: nil)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.codec, "OPUS")
        XCTAssertTrue(tracks.first?.requiresRemux ?? false)
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

    func testArchiveMetadataMapsToResolvedTrackFields() {
        let files = [
            file("03 Song.mp3", format: "VBR MP3", track: "3/12", title: "Song",
                 album: "Album", artist: "Track Artist", genre: "Folk",
                 composer: "Composer", disc: "2/3", year: "1972", bitrate: "256")
        ]

        let track = FileSelectionPolicy(preferFLAC: false)
            .selectTracks(files: files, identifier: "album", itemArtist: "Album Artist",
                          itemGenre: "Fallback Genre", itemYear: 1970)
            .first

        XCTAssertEqual(track?.title, "Song")
        XCTAssertEqual(track?.artist, "Track Artist")
        XCTAssertEqual(track?.albumTitle, "Album")
        XCTAssertEqual(track?.albumArtist, "Album Artist")
        XCTAssertEqual(track?.genre, "Folk")
        XCTAssertEqual(track?.composer, "Composer")
        XCTAssertEqual(track?.trackNo, 3)
        XCTAssertEqual(track?.discNo, 2)
        XCTAssertEqual(track?.year, 1972)
        XCTAssertEqual(track?.bitDepthOrBitrate, "256 kbps")
    }

    // MARK: - Ranked policy (T1.1)

    // Wi-Fi + preferFLAC: FLAC wins even when MP3 and Opus are also present.
    func testRankingPrefersFLACOverAllWhenEnabled() {
        let files = [
            file("01 Aria.mp3", format: "VBR MP3", track: "1", title: "Aria"),
            file("01 Aria.flac", format: "24bit Flac", track: "1", title: "Aria"),
            file("01 Aria.opus", format: "Opus", track: "1", title: "Aria")
        ]
        let tracks = FileSelectionPolicy(preferFLAC: true)
            .selectTracks(files: files, identifier: "gv", itemArtist: nil)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.codec, "FLAC")
        XCTAssertNotNil(tracks.first?.opusURL)
    }

    // Default (no preferFLAC): MP3 is chosen for cold play; FLAC retained as alt.
    func testRankingDefaultPrefersMP3AndRetainsFLACAlternate() {
        let files = [
            file("01 Aria.mp3", format: "VBR MP3", track: "1", title: "Aria"),
            file("01 Aria.flac", format: "24bit Flac", track: "1", title: "Aria"),
            file("01 Aria.opus", format: "Opus", track: "1", title: "Aria")
        ]
        let tracks = FileSelectionPolicy(preferFLAC: false)
            .selectTracks(files: files, identifier: "gv", itemArtist: nil)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.codec, "MP3")
        XCTAssertNotNil(tracks.first?.altFlacURL)
        XCTAssertNotNil(tracks.first?.opusURL)
        XCTAssertFalse(tracks.first?.requiresRemux ?? true)
    }

    // Opus never wins a mixed group even when it's the only lossy alternative
    // to a format the user didn't prefer.
    func testRankingNeverColdPlaysOpusInMixedGroup() {
        let files = [
            file("01 Aria.opus", format: "Opus", track: "1", title: "Aria"),
            file("01 Aria.mp3", format: "VBR MP3", track: "1", title: "Aria")
        ]
        let tracks = FileSelectionPolicy(preferFLAC: true)
            .selectTracks(files: files, identifier: "gv", itemArtist: nil)
        XCTAssertEqual(tracks.first?.codec, "MP3")
        XCTAssertFalse(tracks.first?.requiresRemux ?? true)
    }
}
