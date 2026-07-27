import XCTest
@testable import TonearmCore

final class WatchTrackResolverTests: XCTestCase {

    private let localFile = URL(fileURLWithPath: "/var/mobile/WatchAudio/t1.wav")

    // MARK: - streamURL

    func testStreamURLPrefersPrimaryHTTPS() {
        let url = WatchTrackResolver.streamURL(
            remoteURL: "https://example.com/a.mp3",
            altRemoteURL: "https://example.com/b.mp3")
        XCTAssertEqual(url, URL(string: "https://example.com/a.mp3"))
    }

    func testStreamURLFallsBackToAltWhenPrimaryMissing() {
        let url = WatchTrackResolver.streamURL(
            remoteURL: nil,
            altRemoteURL: "http://example.com/b.mp3")
        XCTAssertEqual(url, URL(string: "http://example.com/b.mp3"))
    }

    func testStreamURLSkipsNonHTTPPrimaryForHTTPAlt() {
        let url = WatchTrackResolver.streamURL(
            remoteURL: "file:///Users/x/song.wav",
            altRemoteURL: "https://cdn.example.com/song.wav")
        XCTAssertEqual(url, URL(string: "https://cdn.example.com/song.wav"))
    }

    func testStreamURLRejectsRelativePath() {
        XCTAssertNil(WatchTrackResolver.streamURL(remoteURL: "WatchAudio/t1.wav"))
    }

    func testStreamURLRejectsEmptyAndWhitespace() {
        XCTAssertNil(WatchTrackResolver.streamURL(remoteURL: "", altRemoteURL: "   "))
    }

    func testStreamURLNilWhenNoCandidates() {
        XCTAssertNil(WatchTrackResolver.streamURL(remoteURL: nil, altRemoteURL: nil))
    }

    // MARK: - resolve

    func testResolvePrefersLocalOverStream() {
        let source = WatchTrackResolver.resolve(
            localURL: localFile,
            remoteURL: "https://example.com/a.mp3")
        XCTAssertEqual(source, .local(localFile))
    }

    func testResolveStreamsWhenNoLocalFile() {
        let source = WatchTrackResolver.resolve(
            localURL: nil,
            remoteURL: "https://example.com/a.mp3")
        XCTAssertEqual(source, .stream(URL(string: "https://example.com/a.mp3")!))
    }

    func testResolveNilWhenNeitherLocalNorStreamable() {
        // Local-file-only track that hasn't been downloaded yet: must fetch from phone.
        let source = WatchTrackResolver.resolve(
            localURL: nil,
            remoteURL: "WatchAudio/t1.wav",
            altRemoteURL: nil)
        XCTAssertNil(source)
    }

    // MARK: - playableURL

    func testPlayableURLReturnsLocalWhenPresent() {
        let url = WatchTrackResolver.playableURL(
            localURL: localFile,
            remoteURL: "https://example.com/a.mp3")
        XCTAssertEqual(url, localFile)
    }

    func testPlayableURLReturnsStreamWhenNoLocal() {
        let url = WatchTrackResolver.playableURL(
            localURL: nil,
            remoteURL: "https://example.com/a.mp3")
        XCTAssertEqual(url, URL(string: "https://example.com/a.mp3"))
    }

    func testPlayableURLNilWhenNothingAvailable() {
        XCTAssertNil(WatchTrackResolver.playableURL(localURL: nil, remoteURL: nil))
    }
}
