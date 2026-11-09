import XCTest
@testable import TonearmCore

/// Responds after a short, deliberate delay so a caller that waits for it is measurably slower
/// than one that doesn't — `startLoading()` runs on URLSession's own background queue, so the
/// delay here never blocks the test's own task.
private final class SlowDownloadStubProtocol: URLProtocol {
    nonisolated(unsafe) static var delaySeconds: TimeInterval = 0.3

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Thread.sleep(forTimeInterval: Self.delaySeconds)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("fake audio bytes".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Real report: a direct browse-and-play tap on a cloud-drive track went dead for the entire
/// download, because `playRemote`/`DiscoveryRuntimeController.onPlay` awaited
/// `persistRemoteTrack` — which pinned the full file to disk — before `player.play` ever ran.
@MainActor
final class PersistRemoteTrackPrefetchBytesTests: XCTestCase {
    private func slowStubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SlowDownloadStubProtocol.self]
        SlowDownloadStubProtocol.delaySeconds = 0.3
        return URLSession(configuration: config)
    }

    private func makeTransientRow(url: String) -> (Source, TrackRow) {
        let source = Source(id: nil, kind: .googleDrive, iaIdentifier: nil, originalURL: nil,
                             title: "Drive", addedAt: Date(), lastResolvedAt: nil,
                             followUpdates: false, licenseText: nil, memberCapHit: false)
        let track = Track(id: -1, albumId: nil, sourceId: 0, title: "Song", trackNo: 1,
                           discNo: nil, durationSec: nil, codec: nil, sampleRate: nil,
                           bitDepthOrBitrate: nil, sortKey: "a")
        let asset = Asset(id: nil, trackId: -1, kind: .remote, bookmark: nil, relPath: nil,
                           remoteURL: url, altRemoteURL: nil, sizeBytes: nil, unsupportedReason: nil)
        return (source, TrackRow(track: track, album: nil, source: source, asset: asset))
    }

    func testPrefetchBytesFalseReturnsWithoutWaitingForTheDownload() async throws {
        let appState = AppState(store: try LibraryStore(inMemory: true))
        appState.downloadSession = slowStubSession()
        let (_, row) = makeTransientRow(url: "https://stub.test/\(UUID().uuidString)/track.mp3")

        let start = ContinuousClock.now
        let persisted = try XCTUnwrap(await appState.persistRemoteTrack(row, prefetchBytes: false))
        let elapsed = start.duration(to: .now)

        XCTAssertGreaterThan(persisted.id, 0, "must be a real, persisted track id")
        XCTAssertLessThan(elapsed, .milliseconds(200),
            "prefetchBytes: false must not block on the download before returning")
    }

    func testPrefetchBytesDefaultsTrueAndStillWaitsForTheDownload() async throws {
        let appState = AppState(store: try LibraryStore(inMemory: true))
        appState.downloadSession = slowStubSession()
        let (_, row) = makeTransientRow(url: "https://stub.test/\(UUID().uuidString)/track.mp3")

        let start = ContinuousClock.now
        let persisted = try XCTUnwrap(await appState.persistRemoteTrack(row))
        let elapsed = start.duration(to: .now)

        XCTAssertGreaterThan(persisted.id, 0)
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(250),
            "every other caller (favorites, edit metadata, custom artwork, watch prep) must keep its existing behavior of waiting for the download")
    }
}
