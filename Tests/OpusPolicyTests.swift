import Foundation
import Testing
@testable import TonearmCore

/// T2.4 — "Opus when ready" selection policy. Verifies that a mixed IA item
/// exposes its Opus derivative for the prefetch/remux upgrade path while cold
/// play stays on an instantly-streamable format, and that Opus-only groups are
/// flagged for the remux-before-play pipeline.
@Suite struct OpusPolicyTests {

    private func file(_ name: String, format: String, track: String? = nil,
                      title: String? = nil) -> IAFile {
        IAFile(name: name, format: format, source: "derivative", original: nil,
               length: "100", size: "1000", title: title, track: track,
               album: nil, artist: nil, bitrate: nil, height: "0")
    }

    @Test func testMixedItemExposesOpusForUpgradeButColdPlaysMP3() {
        let files = [
            file("01 Aria.mp3", format: "VBR MP3", track: "1", title: "Aria"),
            file("01 Aria.opus", format: "Opus", track: "1", title: "Aria")
        ]
        let track = FileSelectionPolicy(preferFLAC: false)
            .selectTracks(files: files, identifier: "gv", itemArtist: nil).first
        let resolved = try! #require(track)
        #expect(resolved.codec == "MP3")
        #expect(!resolved.requiresRemux)
        #expect(resolved.opusURL != nil)
    }

    @Test func testWiFiPreferFLACStillExposesOpus() {
        let files = [
            file("01 Aria.flac", format: "24bit Flac", track: "1", title: "Aria"),
            file("01 Aria.mp3", format: "VBR MP3", track: "1", title: "Aria"),
            file("01 Aria.opus", format: "Opus", track: "1", title: "Aria")
        ]
        let track = FileSelectionPolicy(preferFLAC: true)
            .selectTracks(files: files, identifier: "gv", itemArtist: nil).first
        let resolved = try! #require(track)
        #expect(resolved.codec == "FLAC")
        #expect(resolved.opusURL != nil)
        #expect((resolved.altFlacURL == nil ? resolved.opusURL : resolved.opusURL) != nil)
    }

    // The Opus derivative URL that flows to the Asset is what the prefetcher hands
    // to the remux pipeline; the CAF sibling path must be derivable from it.
    @Test func testOpusURLYieldsStableCAFPath() throws {
        let files = [
            file("01 Aria.mp3", format: "VBR MP3", track: "1", title: "Aria"),
            file("01 Aria.opus", format: "Opus", track: "1", title: "Aria")
        ]
        let track = try #require(FileSelectionPolicy(preferFLAC: false)
            .selectTracks(files: files, identifier: "gv", itemArtist: nil).first)
        let opusURL = try #require(track.opusURL)
        let caf1 = AudioCache.cafURL(forRemoteOpus: opusURL)
        let caf2 = AudioCache.cafURL(forRemoteOpus: opusURL)
        #expect(caf1 == caf2)
        #expect(caf1.pathExtension == "caf")
        #expect(caf1.deletingLastPathComponent().lastPathComponent.hasSuffix("-opus"))
    }

    // An Opus-only item still produces a track flagged for remux-before-play.
    @Test func testOpusOnlyItemRequiresRemux() throws {
        let files = [file("side1.opus", format: "Opus", track: "1", title: "Side 1")]
        let track = try #require(FileSelectionPolicy(preferFLAC: false)
            .selectTracks(files: files, identifier: "album", itemArtist: nil).first)
        #expect(track.requiresRemux)
        #expect(track.remoteURL.pathExtension == "opus")
    }
}
