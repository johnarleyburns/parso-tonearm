import XCTest
import ParsoAudioStreaming
@testable import TonearmCore

/// Stubs `download(rows:)`'s own network fetch, not a provider — AppState.downloadSession is
/// the injection seam.
private final class DownloadStubProtocol: URLProtocol {
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var body = Data("fake audio bytes".utf8)
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requestCount += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.statusCode,
                                       httpVersion: "1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Real reports this covers: a Dropbox/Google Drive track that genuinely couldn't stream (an
/// expired temp link, a revoked token) got its error response body written to disk and marked
/// `complete`/durable anyway — a poisoned, permanently "downloaded" entry that silently fails
/// every later play and is never re-fetched (`download(rows:)`/`makeOffline(source:)` never
/// checked the HTTP status). And a track mid-stream/mid-prefetch (a genuinely partial blob
/// already sitting at the same cache path `CachingResourceLoader` writes to) got adopted as a
/// complete download purely because *some* file existed there, not because it actually was
/// complete.
@MainActor
final class AppStateDownloadHardeningTests: XCTestCase {
    private func stubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DownloadStubProtocol.self]
        DownloadStubProtocol.statusCode = 200
        DownloadStubProtocol.body = Data("fake audio bytes".utf8)
        DownloadStubProtocol.requestCount = 0
        return URLSession(configuration: config)
    }

    private func makeRemoteRow(store: LibraryStore, url: String) async throws -> TrackRow {
        let source = try await store.insertSource(Source(
            id: nil, kind: .dropbox, iaIdentifier: nil, originalURL: nil, title: "Dropbox",
            addedAt: Date(), lastResolvedAt: nil, followUpdates: false,
            licenseText: nil, memberCapHit: false))
        let track = try await store.insertTrack(Track(
            id: nil, albumId: nil, sourceId: source.id!, title: "Track", trackNo: 1,
            discNo: nil, durationSec: nil, codec: nil, sampleRate: nil,
            bitDepthOrBitrate: nil, sortKey: "a"))
        _ = try await store.insertAsset(Asset(
            id: nil, trackId: track.id!, kind: .remote, bookmark: nil, relPath: nil,
            remoteURL: url, altRemoteURL: nil, sizeBytes: nil, unsupportedReason: nil))
        let rows = try await store.tracks(forSource: source.id!)
        return try XCTUnwrap(rows.first)
    }

    func testFailedResponseIsNotWrittenOrAdoptedAsComplete() async throws {
        let appState = AppState(store: try LibraryStore(inMemory: true))
        appState.downloadSession = stubSession()
        DownloadStubProtocol.statusCode = 401
        let url = "https://stub.test/\(UUID().uuidString)/expired-link.mp3"
        let row = try await makeRemoteRow(store: appState.store, url: url)

        let downloaded = await appState.download(rows: [row])

        XCTAssertEqual(downloaded, 1, "download(rows:) still counts the attempt, same as before")
        XCTAssertFalse(AudioCache.completeCacheExists(for: URL(string: url)!),
            "a 401/expired-link response must never be written to disk and adopted as a complete download")
    }

    func testAlreadyCompleteCacheEntryIsTrustedWithoutRefetching() async throws {
        let appState = AppState(store: try LibraryStore(inMemory: true))
        appState.downloadSession = stubSession()
        let url = "https://stub.test/\(UUID().uuidString)/already-cached.mp3"
        let row = try await makeRemoteRow(store: appState.store, url: url)
        let remoteURL = URL(string: url)!
        let cacheKey = AudioCache.key(for: remoteURL)

        // Simulate the track having already been fully streamed/prefetched earlier, under
        // AudioCache's own completeness bookkeeping (not just "a file happens to exist").
        await AudioCache.shared.adoptCompleteFile(byteCount: 17, for: cacheKey, durable: false)
        XCTAssertTrue(AudioCache.completeCacheExists(for: remoteURL))

        let downloaded = await appState.download(rows: [row])

        XCTAssertEqual(downloaded, 1)
        XCTAssertEqual(DownloadStubProtocol.requestCount, 0,
            "an entry AudioCache already knows is complete must not be re-fetched over the network")
        let meta = await AudioCache.shared.meta(for: cacheKey)
        XCTAssertEqual(meta?.isDurable, true, "trusting an existing complete entry must still pin it durable")
    }

    func testPartialBlobAtTheSamePathIsNotAdoptedAsComplete() async throws {
        let appState = AppState(store: try LibraryStore(inMemory: true))
        appState.downloadSession = stubSession()
        let url = "https://stub.test/\(UUID().uuidString)/mid-stream.mp3"
        let row = try await makeRemoteRow(store: appState.store, url: url)
        let remoteURL = URL(string: url)!
        let cacheKey = AudioCache.key(for: remoteURL)

        // A genuinely partial blob: some bytes written (e.g. by a prefetch or an in-progress
        // stream to the same cache path), but the cache's own bookkeeping knows it is NOT
        // complete (a real expected total larger than what's been written so far).
        await AudioCache.shared.setContentLength(1_000, for: cacheKey)
        await AudioCache.shared.recordWrite(range: 0..<17, for: cacheKey)
        XCTAssertFalse(AudioCache.completeCacheExists(for: remoteURL))

        let downloaded = await appState.download(rows: [row])

        XCTAssertEqual(downloaded, 1)
        XCTAssertEqual(DownloadStubProtocol.requestCount, 1,
            "a genuinely partial entry must be fetched fresh, not adopted as-is")
        XCTAssertTrue(AudioCache.completeCacheExists(for: remoteURL),
            "the fresh, successful fetch must leave the entry actually complete")
    }
}
