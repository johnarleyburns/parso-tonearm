#if !os(watchOS)
import AVFoundation
import XCTest
@testable import TonearmCore

private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var open = false
    func wait() async {
        await withCheckedContinuation { c in
            lock.lock()
            if open { lock.unlock(); c.resume() } else { continuation = c; lock.unlock() }
        }
    }
    func release() {
        lock.lock(); open = true; let c = continuation; continuation = nil; lock.unlock()
        c?.resume()
    }
}

private final class Spy: @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [String] = []
    private var _refreshes = 0
    func built(_ s: String?) { lock.withLock { _urls.append(s ?? "nil") } }
    func refreshed() { lock.withLock { _refreshes += 1 } }
    var urls: [String] { lock.withLock { _urls } }
    var refreshes: Int { lock.withLock { _refreshes } }
}

@MainActor
final class AudioPlayerJamendoLoadingTests: XCTestCase {
    private let stale = "https://example.test/stale.mp3"
    private let fresh = URL(string: "https://example.test/fresh.mp3")!
    private var savedResolver: CatalogPlaybackURLResolver!

    override func setUp() {
        super.setUp()
        savedResolver = AudioPlayer.shared.catalogPlaybackURLResolver
    }

    override func tearDown() {
        let p = AudioPlayer.shared
        p.ordinaryBuildItemHook = nil
        p.catalogPlaybackURLResolver = savedResolver
        p.clearQueuePlayback()
        p.queue = []
        super.tearDown()
    }

    private func install(gate: Gate? = nil, spy: Spy) throws {
        let store = FakeCatalog()
        store.add(jamendoID: "99123", cached: URL(string: stale))
        let fresh = fresh
        let player = AudioPlayer.shared
        player.catalogPlaybackURLResolver = CatalogPlaybackURLResolver(
            lookup: { store.row($0) },
            resolver: JamendoLocatorResolver(maxTransientAttempts: 1, backoff: { _ in 0 }, sleep: { _ in },
                                             refresh: { _ in spy.refreshed(); await gate?.wait(); return (fresh, nil) }),
            persist: { _, _, _ in })
        player.ordinaryBuildItemHook = { asset in
            spy.built(asset.remoteURL)
            // A non-failing item: a real unreachable URL would now (correctly) fail statuslessly.
            return (AVPlayerItem(asset: AVMutableComposition()), nil)
        }
    }

    private func jamendo() -> TrackRow {
        CatalogPlaybackURLResolverTests.row(kind: .jamendoGenre, nodeID: "99123", url: stale)
    }

    /// Installs a queue and loads it without autoplay (keeps the shared library store out of the test).
    private func load(_ rows: [TrackRow]) {
        let player = AudioPlayer.shared
        player.keepPlayingEnabled = false
        player.queue = rows
        player.index = 0
        player.loadCurrent(autoplay: false)
    }

    private func settle() async { for _ in 0..<20 { await Task.yield(); try? await Task.sleep(nanoseconds: 10_000_000) } }

    func testLoadCurrentBuildsOrdinaryJamendoItemOnlyAfterFreshLocatorResolution() async throws {
        let spy = Spy(), gate = Gate()
        try install(gate: gate, spy: spy)
        load([jamendo()])
        await settle()
        XCTAssertTrue(spy.urls.isEmpty, "no item may be built before the locator resolves")
        gate.release()
        await settle()
        XCTAssertEqual(spy.urls, [fresh.absoluteString])
        XCTAssertFalse(spy.urls.contains(stale))
    }

    func testStaleResolverCompletionCannotReplaceNewQueueOrResumeStoppedPlayback() async throws {
        let spy = Spy(), gate = Gate()
        try install(gate: gate, spy: spy)
        let player = AudioPlayer.shared
        load([jamendo()])
        load([CatalogPlaybackURLResolverTests.row(kind: .iaItem, nodeID: nil, url: "https://example.test/ia.mp3")])
        gate.release()
        await settle()
        XCTAssertFalse(spy.urls.contains(fresh.absoluteString), "stale Jamendo result replaced a newer queue")

        let spy2 = Spy(), gate2 = Gate()
        try install(gate: gate2, spy: spy2)
        load([jamendo()])
        player.clearQueuePlayback()
        gate2.release()
        await settle()
        XCTAssertTrue(spy2.urls.isEmpty)
        XCTAssertFalse(player.isPlaying)
    }

    func testOrdinaryJamendoStaleHTTPFailureRefreshesOnceThenFailsTruthfully() async throws {
        let spy = Spy()
        try install(spy: spy)
        let player = AudioPlayer.shared
        player.networkSkipMessage = nil
        load([jamendo()])
        await settle()
        XCTAssertEqual(spy.urls.count, 1)

        player.handleOrdinaryJamendoLoaderFailure(httpStatus: 403)
        await settle()
        XCTAssertEqual(spy.urls.count, 2, "one retry after the first stale failure")
        XCTAssertEqual(spy.refreshes, 2)

        player.handleOrdinaryJamendoLoaderFailure(httpStatus: 403)
        await settle()
        XCTAssertEqual(spy.urls.count, 2, "no second retry")
        XCTAssertEqual(spy.refreshes, 2)
        XCTAssertEqual(player.networkSkipMessage, RemotePlaybackFailure.jamendoLocatorUnavailable.userMessage)
        XCTAssertFalse(player.isPlaying)
    }

    func testStatuslessFailedJamendoItemPublishesTruthfulFailure() async throws {
        let spy = Spy()
        try install(spy: spy)
        let player = AudioPlayer.shared
        player.ordinaryBuildItemHook = { _ in
            (AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent/tonearm-missing.mp3")), nil)
        }
        player.networkSkipMessage = nil
        load([jamendo()])
        for _ in 0..<100 where player.networkSkipMessage == nil {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(player.networkSkipMessage, RemotePlaybackFailure.jamendoLocatorUnavailable.userMessage)
        XCTAssertNil(player.player.currentItem)
        XCTAssertFalse(player.isPlaying)
    }

    func testTerminalTransientLoaderFailureDoesNotLeaveFailedItemStranded() async throws {
        let spy = Spy()
        try install(spy: spy)
        let player = AudioPlayer.shared
        player.networkSkipMessage = nil
        load([jamendo()])
        await settle()
        let builds = spy.urls.count, refreshes = spy.refreshes
        player.handleOrdinaryJamendoTerminalLoaderFailure(httpStatus: 503)
        await settle()
        XCTAssertEqual(player.networkSkipMessage, RemotePlaybackFailure.jamendoLocatorUnavailable.userMessage)
        XCTAssertNil(player.player.currentItem)
        XCTAssertEqual(spy.urls.count, builds, "no extra build/open loop")
        XCTAssertEqual(spy.refreshes, refreshes, "no extra refresh")
        player.handleOrdinaryJamendoTerminalLoaderFailure(httpStatus: 503)
        XCTAssertEqual(spy.refreshes, refreshes)
    }

    func testStaleTerminalLoaderFailureCannotStopReplacementQueue() async throws {
        let spy = Spy()
        try install(spy: spy)
        let player = AudioPlayer.shared
        load([jamendo()])
        await settle()
        load([CatalogPlaybackURLResolverTests.row(kind: .iaItem, nodeID: nil, url: "https://example.test/ia.mp3")])
        await settle()
        player.networkSkipMessage = nil
        let item = player.player.currentItem
        XCTAssertNotNil(item)
        player.handleOrdinaryJamendoTerminalLoaderFailure(httpStatus: nil)
        player.handleOrdinaryJamendoTerminalLoaderFailure(httpStatus: 503)
        XCTAssertTrue(player.player.currentItem === item)
        XCTAssertNil(player.networkSkipMessage)
    }

    func testTransientBrowseRowPlaysFreshURLWithoutCatalogInsert() async throws {
        let spy = Spy()
        try install(spy: spy)
        let store = FakeCatalog()
        let player = AudioPlayer.shared
        // Empty catalog: a catalog lookup would fail this load.
        player.catalogPlaybackURLResolver.lookup = { _ in XCTFail("browse row must not look up catalog"); return nil }
        load([CatalogPlaybackURLResolverTests.row(kind: .jamendoGenre, nodeID: "99123", url: stale, sourceID: nil)])
        await settle()
        XCTAssertEqual(spy.urls, [fresh.absoluteString])
        XCTAssertNil(store.row(BlendCatalogTrack.jamendoKey(trackID: "99123")))
    }

    func testNonJamendoRemoteRowStillUsesUnchangedBuildPath() async throws {
        let spy = Spy()
        try install(spy: spy)
        load([CatalogPlaybackURLResolverTests.row(kind: .iaItem, nodeID: nil, url: "https://example.test/ia.mp3")])
        XCTAssertEqual(spy.urls, ["https://example.test/ia.mp3"], "synchronous, no resolver")
        XCTAssertEqual(spy.refreshes, 0)
    }

    func testJamendoRowMissingNodeIDFailsAndNeverBuildsRawURLItem() async throws {
        let spy = Spy()
        try install(spy: spy)
        let player = AudioPlayer.shared
        player.networkSkipMessage = nil
        load([CatalogPlaybackURLResolverTests.row(kind: .jamendoGenre, nodeID: nil, url: "https://stale.example")])
        await settle()
        XCTAssertEqual(player.networkSkipMessage, RemotePlaybackFailure.jamendoLocatorUnavailable.userMessage)
        XCTAssertTrue(spy.urls.isEmpty, "raw URL must never reach buildItem")
        XCTAssertEqual(spy.refreshes, 0)
    }
}
#endif
