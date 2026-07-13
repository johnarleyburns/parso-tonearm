import XCTest
@testable import Tonearm

/// T2.4 — "Opus when ready" selection policy. Verifies that a mixed IA item
/// exposes its Opus derivative for the prefetch/remux upgrade path while cold
/// play stays on an instantly-streamable format, and that Opus-only groups are
/// flagged for the remux-before-play pipeline.
final class OpusPolicyTests: XCTestCase {

    private func file(_ name: String, format: String, track: String? = nil,
                      title: String? = nil) -> IAFile {
        IAFile(name: name, format: format, source: "derivative", original: nil,
               length: "100", size: "1000", title: title, track: track,
               album: nil, artist: nil, bitrate: nil, height: "0")
    }

    func testMixedItemExposesOpusForUpgradeButColdPlaysMP3() {
        let files = [
            file("01 Aria.mp3", format: "VBR MP3", track: "1", title: "Aria"),
            file("01 Aria.opus", format: "Opus", track: "1", title: "Aria")
        ]
        let track = FileSelectionPolicy(preferFLAC: false)
            .selectTracks(files: files, identifier: "gv", itemArtist: nil).first
        let resolved = try! XCTUnwrap(track)
        XCTAssertEqual(resolved.codec, "MP3")
        XCTAssertFalse(resolved.requiresRemux)
        XCTAssertNotNil(resolved.opusURL)
    }

    func testWiFiPreferFLACStillExposesOpus() {
        let files = [
            file("01 Aria.flac", format: "24bit Flac", track: "1", title: "Aria"),
            file("01 Aria.mp3", format: "VBR MP3", track: "1", title: "Aria"),
            file("01 Aria.opus", format: "Opus", track: "1", title: "Aria")
        ]
        let track = FileSelectionPolicy(preferFLAC: true)
            .selectTracks(files: files, identifier: "gv", itemArtist: nil).first
        let resolved = try! XCTUnwrap(track)
        XCTAssertEqual(resolved.codec, "FLAC")
        XCTAssertNotNil(resolved.opusURL)
        XCTAssertNotNil(resolved.altFlacURL == nil ? resolved.opusURL : resolved.opusURL)
    }

    // The Opus derivative URL that flows to the Asset is what the prefetcher hands
    // to the remux pipeline; the CAF sibling path must be derivable from it.
    func testOpusURLYieldsStableCAFPath() throws {
        let files = [
            file("01 Aria.mp3", format: "VBR MP3", track: "1", title: "Aria"),
            file("01 Aria.opus", format: "Opus", track: "1", title: "Aria")
        ]
        let track = try XCTUnwrap(FileSelectionPolicy(preferFLAC: false)
            .selectTracks(files: files, identifier: "gv", itemArtist: nil).first)
        let opusURL = try XCTUnwrap(track.opusURL)
        let caf1 = CacheStore.cafURL(forRemoteOpus: opusURL)
        let caf2 = CacheStore.cafURL(forRemoteOpus: opusURL)
        XCTAssertEqual(caf1, caf2)
        XCTAssertEqual(caf1.pathExtension, "caf")
    }

    // An Opus-only item still produces a track flagged for remux-before-play.
    func testOpusOnlyItemRequiresRemux() throws {
        let files = [file("side1.opus", format: "Opus", track: "1", title: "Side 1")]
        let track = try XCTUnwrap(FileSelectionPolicy(preferFLAC: false)
            .selectTracks(files: files, identifier: "album", itemArtist: nil).first)
        XCTAssertTrue(track.requiresRemux)
        XCTAssertEqual(track.remoteURL.pathExtension, "opus")
    }
}
