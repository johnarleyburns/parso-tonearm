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

    /// Every remote URL any test in this file loads. `loadCurrent` consults the real,
    /// persistent `AudioCache` (`~/Library/Caches/Tonearm/StreamCacheV2` in production,
    /// unchanged for `swift test`) before this file's fake resolver is ever reached: if
    /// a prior run — on a developer machine or a self-hosted CI runner that does not
    /// get a clean filesystem between jobs — already wrote a complete blob under one of
    /// these fixture URLs' cache keys, the "already fully cached, play from disk"
    /// shortcut in `AudioPlayer+Loading.swift` fires on this run too, bypassing the
    /// resolver and every assertion in this file that depends on it running. This is
    /// what made `testJamendoRowMissingNodeIDFailsAndNeverBuildsRawURLItem` fail: a
    /// stale complete blob for "https://stale.example" let a malformed Jamendo locator
    /// skip straight to "cached" instead of being rejected. Purge every fixture URL's
    /// cache entry before AND after each test, so this file never depends on — and
    /// never leaves behind — real on-disk cache state.
    private static let fixtureURLs: [String] = [
        "https://example.test/stale.mp3",
        "https://example.test/fresh.mp3",
        "jamendo://track/99123",
        "https://example.test/current.mp3",
        "https://example.test/ia.mp3",
        "https://stale.example"
    ]

    /// `static` so this never has to "send" `self` across an isolation boundary
    /// from `setUp`/`tearDown` (Swift 6 region isolation flags that as a data-race
    /// risk even though every call here is synchronous) - it only needs the
    /// `static let fixtureURLs` and `AudioCache`'s own nonisolated statics.
    private static func purgeFixtureCacheEntries() {
        for string in Self.fixtureURLs {
            guard let url = URL(string: string) else { continue }
            let key = AudioCache.key(for: url)
            for fileURL in [AudioCache.fileURL(for: key), AudioCache.metaURL(for: key)] {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    override func setUp() {
        super.setUp()
        Self.purgeFixtureCacheEntries()
        savedResolver = AudioPlayer.shared.catalogPlaybackURLResolver
    }

    /// Reproduces the exact contamination that made
    /// `testJamendoRowMissingNodeIDFailsAndNeverBuildsRawURLItem` fail (issue #351):
    /// a prior run leaves a real "complete" cache entry under a fixture URL's key,
    /// so `AudioCache.completeCacheExists` — the gate `AudioPlayer+Loading.swift`'s
    /// "already fully cached, play from disk" shortcut checks before ever reaching
    /// this file's fake resolver — wrongly reports true. Proves `setUp`/`tearDown`'s
    /// purge actually removes that contamination rather than merely assuming a clean
    /// starting directory.
    func testPurgeFixtureCacheEntriesRemovesAPriorCompleteCacheEntry() async throws {
        let url = URL(string: "https://stale.example")!
        let key = AudioCache.key(for: url)
        let blobURL = AudioCache.fileURL(for: key)
        try FileManager.default.createDirectory(at: blobURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let bytes = Data([0, 1, 2, 3])
        try bytes.write(to: blobURL)
        await AudioCache.shared.registerComplete(key: key, bytes: Int64(bytes.count), kind: "audio")
        XCTAssertTrue(AudioCache.completeCacheExists(for: url),
                     "fixture setup must actually simulate a prior complete cache entry")

        Self.purgeFixtureCacheEntries()

        XCTAssertFalse(AudioCache.completeCacheExists(for: url),
                      "a stale complete cache entry must not survive setUp/tearDown, or it silently " +
                      "bypasses the malformed-locator rejection path the same way it did for issue #351")
    }

    override func tearDown() {
        Self.purgeFixtureCacheEntries()
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

    private func moodStarterJamendo() -> TrackRow {
        CatalogPlaybackURLResolverTests.row(
            kind: .local, nodeID: nil, url: "jamendo://track/99123")
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

    /// A Mood Starter row is intentionally a local source (it is bundled
    /// metadata), but its remote asset is a Jamendo provider locator. It must
    /// take the ordinary Jamendo resolver path instead of handing the custom
    /// `jamendo://` scheme directly to AVFoundation and stalling forever.
    func testMoodStarterJamendoRowResolvesBeforeBuildingItsPlayerItem() async throws {
        let spy = Spy()
        try install(spy: spy)

        load([moodStarterJamendo()])
        await settle()

        XCTAssertEqual(spy.refreshes, 1)
        XCTAssertEqual(spy.urls, [fresh.absoluteString])
    }

    /// Issue #325: a fully downloaded Jamendo track must play from its local cache without a
    /// live locator resolve; an incomplete cache still resolves (covered by the test above).
    func testCompletelyCachedJamendoRowSkipsLiveResolve() async throws {
        let spy = Spy()
        try install(spy: spy)
        let staleURL = try XCTUnwrap(URL(string: stale))
        let key = AudioCache.key(for: staleURL)
        let blob = AudioCache.fileURL(for: key)
        try FileManager.default.createDirectory(at: blob.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 1000).write(to: blob)
        await AudioCache.shared.adoptCompleteFile(byteCount: 1000, for: key, durable: false)
        addTeardownBlock { await AudioCache.shared.remove(keys: [key]) }
        XCTAssertTrue(AudioCache.completeCacheExists(for: staleURL))

        load([jamendo()])
        await settle()
        XCTAssertEqual(spy.refreshes, 0, "complete local file must not hit the network resolver")
        XCTAssertEqual(spy.urls, [stale], "item is built from the cached URL, not a re-signed one")
    }

    func testDropboxRowIsReResolvedThroughFreshenerBeforeItemIsBuilt() async throws {
        let spy = Spy()
        try install(spy: spy)
        let player = AudioPlayer.shared
        defer { player.remoteRowFreshener = nil }
        let fresh = fresh
        player.remoteRowFreshener = { row in
            var r = row
            r.asset?.remoteURL = fresh.absoluteString
            return r
        }
        load([CatalogPlaybackURLResolverTests.row(kind: .dropbox, nodeID: "id:abc", url: stale)])
        await settle()
        XCTAssertEqual(spy.urls, [fresh.absoluteString], "OAuth cloud rows must be re-resolved, not played from the stale stored URL")
    }

    /// Real report: a cloud-drive track played fine the FIRST time a queue reached it directly,
    /// but silently failed whenever it was reached via the near-gapless prefetch path instead —
    /// `prefetchNext` read `asset.transientRemoteHeaders`/the stored `remoteURL` straight off the
    /// queue, never through `remoteRowFreshener` the way `loadCurrent` does for the current track.
    func testPrefetchNextFreshensACloudDriveRowBeforeBuildingItsLoader() async throws {
        let player = AudioPlayer.shared
        defer { player.remoteRowFreshener = nil; player.prefetchDepth = 0 }
        let fresh = fresh
        player.remoteRowFreshener = { row in
            var r = row
            r.asset?.remoteURL = fresh.absoluteString
            return r
        }
        var current = CatalogPlaybackURLResolverTests.row(kind: .webDAV, nodeID: nil, url: "https://example.test/current.mp3")
        current.track.id = 101
        var next = CatalogPlaybackURLResolverTests.row(kind: .dropbox, nodeID: "id:abc", url: stale)
        next.track.id = 102

        player.queue = [current, next]
        player.index = 0
        player.prefetchDepth = 1
        player.prefetchNext()
        await settle()

        XCTAssertEqual(player.prefetchedURLs[102], fresh,
            "the prefetched-ahead row must use the freshened URL, not the stale one straight off the queue")
    }

    /// Same gap as the prefetch test above, for the near-gapless PRELOADED item
    /// (`preloadNextItem`/the `finishOrdinaryLoad` branch that reuses it directly, bypassing
    /// `loadCurrent`'s own freshening entirely).
    func testPreloadNextItemFreshensACloudDriveRowBeforeBuildingItem() async throws {
        let player = AudioPlayer.shared
        defer { player.remoteRowFreshener = nil }
        let fresh = fresh
        player.remoteRowFreshener = { row in
            var r = row
            r.asset?.remoteURL = fresh.absoluteString
            return r
        }
        var current = CatalogPlaybackURLResolverTests.row(kind: .webDAV, nodeID: nil, url: "https://example.test/current.mp3")
        current.track.id = 201
        var next = CatalogPlaybackURLResolverTests.row(kind: .dropbox, nodeID: "id:abc", url: stale)
        next.track.id = 202

        player.queue = [current, next]
        player.index = 0
        player.preloadNextItem()
        await settle()

        XCTAssertEqual(player.preloadedNextTrackId, 202)
        XCTAssertEqual(player.preloadedNextLoader?.cacheKey, AudioCache.key(for: fresh),
            "the preloaded item's loader must be built from the freshened URL, not the stale one straight off the queue")
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
