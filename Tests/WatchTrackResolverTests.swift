import Foundation
import Testing
@testable import TonearmCore

@Suite struct WatchTrackResolverTests {

    private let localFile = URL(fileURLWithPath: "/var/mobile/WatchAudio/t1.wav")

    // MARK: - streamURL

    @Test func testStreamURLPrefersPrimaryHTTPS() {
        let url = WatchTrackResolver.streamURL(
            remoteURL: "https://example.com/a.mp3",
            altRemoteURL: "https://example.com/b.mp3")
        #expect(url == URL(string: "https://example.com/a.mp3"))
    }

    @Test func testStreamURLFallsBackToAltWhenPrimaryMissing() {
        let url = WatchTrackResolver.streamURL(
            remoteURL: nil,
            altRemoteURL: "http://example.com/b.mp3")
        #expect(url == URL(string: "http://example.com/b.mp3"))
    }

    @Test func testStreamURLSkipsNonHTTPPrimaryForHTTPAlt() {
        let url = WatchTrackResolver.streamURL(
            remoteURL: "file:///Users/x/song.wav",
            altRemoteURL: "https://cdn.example.com/song.wav")
        #expect(url == URL(string: "https://cdn.example.com/song.wav"))
    }

    @Test func testStreamURLRejectsRelativePath() {
        #expect(WatchTrackResolver.streamURL(remoteURL: "WatchAudio/t1.wav") == nil)
    }

    @Test func testStreamURLRejectsEmptyAndWhitespace() {
        #expect(WatchTrackResolver.streamURL(remoteURL: "", altRemoteURL: "   ") == nil)
    }

    @Test func testStreamURLNilWhenNoCandidates() {
        #expect(WatchTrackResolver.streamURL(remoteURL: nil, altRemoteURL: nil) == nil)
    }

    // MARK: - resolve

    @Test func testResolvePrefersLocalOverStream() {
        let source = WatchTrackResolver.resolve(
            localURL: localFile,
            remoteURL: "https://example.com/a.mp3")
        #expect(source == .local(localFile))
    }

    @Test func testResolveStreamsWhenNoLocalFile() {
        let source = WatchTrackResolver.resolve(
            localURL: nil,
            remoteURL: "https://example.com/a.mp3")
        #expect(source == .stream(URL(string: "https://example.com/a.mp3")!))
    }

    @Test func testResolveNilWhenNeitherLocalNorStreamable() {
        // Local-file-only track that hasn't been downloaded yet: must fetch from phone.
        let source = WatchTrackResolver.resolve(
            localURL: nil,
            remoteURL: "WatchAudio/t1.wav",
            altRemoteURL: nil)
        #expect(source == nil)
    }

    // MARK: - playableURL

    @Test func testPlayableURLReturnsLocalWhenPresent() {
        let url = WatchTrackResolver.playableURL(
            localURL: localFile,
            remoteURL: "https://example.com/a.mp3")
        #expect(url == localFile)
    }

    @Test func testPlayableURLReturnsStreamWhenNoLocal() {
        let url = WatchTrackResolver.playableURL(
            localURL: nil,
            remoteURL: "https://example.com/a.mp3")
        #expect(url == URL(string: "https://example.com/a.mp3"))
    }

    @Test func testPlayableURLNilWhenNothingAvailable() {
        #expect(WatchTrackResolver.playableURL(localURL: nil, remoteURL: nil) == nil)
    }
}
