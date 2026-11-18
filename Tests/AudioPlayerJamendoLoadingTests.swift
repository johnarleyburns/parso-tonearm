#if !os(watchOS)
import AVFoundation
import Foundation
import ParsoAudioStreaming
import Testing
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

extension SharedProductionSingletonTests {
    @MainActor
    @Suite final class AudioPlayerJamendoLoadingTests {
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
        /// from `init`/`deinit` (Swift 6 region isolation flags that as a data-race
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

        init() {
            Self.purgeFixtureCacheEntries()
            savedResolver = AudioPlayer.shared.catalogPlaybackURLResolver
        }

        /// Reproduces the exact contamination that made
        /// `testJamendoRowMissingNodeIDFailsAndNeverBuildsRawURLItem` fail (issue #351):
        /// a prior run leaves a real "complete" cache entry under a fixture URL's key,
        /// so `AudioCache.completeCacheExists` — the gate `AudioPlayer+Loading.swift`'s
        /// "already fully cached, play from disk" shortcut checks before ever reaching
        /// this file's fake resolver — wrongly reports true. Proves `init`/`deinit`'s
        /// purge actually removes that contamination rather than merely assuming a clean
        /// starting directory.
        ///
        /// Writes the stale "complete" entry's meta.json directly (same shape
        /// `AudioCache.shared.registerComplete` would persist), rather than calling
        /// through the real shared actor: `completeCacheExists` only ever reads these
        /// files synchronously and never touches the actor, so this reproduces the
        /// exact contamination issue #351 hit without the real actor's first-touch-
        /// per-process directory scan and eviction pass against whatever has actually
        /// accumulated in the real, shared, non-ephemeral
        /// `~/Library/Caches/Tonearm/StreamCacheV2` on a self-hosted runner.
        @Test func testPurgeFixtureCacheEntriesRemovesAPriorCompleteCacheEntry() throws {
            let url = URL(string: "https://stale.example")!
            let key = AudioCache.key(for: url)
            let blobURL = AudioCache.fileURL(for: key)
            try FileManager.default.createDirectory(at: blobURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            let bytes = Data([0, 1, 2, 3])
            try bytes.write(to: blobURL)
            let meta = SparseCacheStore.Meta(
                totalBytes: Int64(bytes.count), cachedBytes: Int64(bytes.count), complete: true,
                lastAccessedAt: Date(), createdAt: Date(), rangeMap: ByteRangeMap(), kind: "audio")
            try JSONEncoder().encode(meta).write(to: AudioCache.metaURL(for: key))
            #expect(AudioCache.completeCacheExists(for: url),
                         "fixture setup must actually simulate a prior complete cache entry")

            Self.purgeFixtureCacheEntries()

            #expect(!AudioCache.completeCacheExists(for: url),
                          "a stale complete cache entry must not survive init/deinit, or it silently bypasses the malformed-locator rejection path the same way it did for issue #351")
        }

        isolated deinit {
            Self.purgeFixtureCacheEntries()
            let p = AudioPlayer.shared
            p.ordinaryBuildItemHook = nil
            p.catalogPlaybackURLResolver = savedResolver
            p.clearQueuePlayback()
            p.queue = []
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

        @Test func testLoadCurrentBuildsOrdinaryJamendoItemOnlyAfterFreshLocatorResolution() async throws {
            let spy = Spy(), gate = Gate()
            try install(gate: gate, spy: spy)
            load([jamendo()])
            await settle()
            #expect(spy.urls.isEmpty, "no item may be built before the locator resolves")
            gate.release()
            await settle()
            #expect(spy.urls == [fresh.absoluteString])
            #expect(!spy.urls.contains(stale))
        }

        /// Architecture-review finding: starting an async Jamendo resolve left the PREVIOUS item
        /// playing, under the NEW track's displayed title, for the entire resolve window — its
        /// elapsed time/duration kept showing on screen, and its natural end or stall timer could
        /// fire `next()`/a skip on behalf of the track that was actually still resolving. The outgoing
        /// item must be torn down synchronously, before the resolve even starts.
        @Test func testStartingAnAsyncJamendoResolveStopsTheOutgoingItemImmediately() async throws {
            let spy = Spy(), gate = Gate()
            try install(gate: gate, spy: spy)
            let player = AudioPlayer.shared
            load([CatalogPlaybackURLResolverTests.row(kind: .iaItem, nodeID: nil, url: "https://example.test/ia.mp3"),
                  jamendo()])
            #expect(player.player.currentItem != nil, "setup: the first track must actually have an item")
            let buildsBeforeTap = spy.urls.count
            // Simulate being deep into a long-running first track when the user taps the Jamendo one.
            player.isPlaying = true
            player.currentTime = 1234
            player.duration = 1500

            player.index = 1
            player.loadCurrent(autoplay: true)

            #expect(player.player.currentItem == nil,
                        "the outgoing item must be released before an async Jamendo resolve starts, not kept playing under the new track's title")
            #expect(player.currentTime == 0)
            #expect(!player.isPlaying)
            #expect(player.duration == 100, "duration must switch to the new track's own known value, not linger on the old one")

            gate.release()
            await settle()
            #expect(spy.urls.count == buildsBeforeTap + 1, "exactly one more item must be built: the resolved Jamendo track")
            #expect(spy.urls.last == fresh.absoluteString)
        }

        /// A Mood Starter row is intentionally a local source (it is bundled
        /// metadata), but its remote asset is a Jamendo provider locator. It must
        /// take the ordinary Jamendo resolver path instead of handing the custom
        /// `jamendo://` scheme directly to AVFoundation and stalling forever.
        @Test func testMoodStarterJamendoRowResolvesBeforeBuildingItsPlayerItem() async throws {
            let spy = Spy()
            try install(spy: spy)

            load([moodStarterJamendo()])
            await settle()

            #expect(spy.refreshes == 1)
            #expect(spy.urls == [fresh.absoluteString])
        }

        /// Issue #325: a fully downloaded Jamendo track must play from its local cache without a
        /// live locator resolve; an incomplete cache still resolves (covered by the test above).
        @Test func testCompletelyCachedJamendoRowSkipsLiveResolve() async throws {
            let spy = Spy()
            try install(spy: spy)
            let staleURL = try #require(URL(string: stale))
            let key = AudioCache.key(for: staleURL)
            let blob = AudioCache.fileURL(for: key)
            try FileManager.default.createDirectory(at: blob.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: 1000).write(to: blob)
            await AudioCache.shared.adoptCompleteFile(byteCount: 1000, for: key, durable: false)
            #expect(AudioCache.completeCacheExists(for: staleURL))

            load([jamendo()])
            await settle()
            #expect(spy.refreshes == 0, "complete local file must not hit the network resolver")
            #expect(spy.urls == [stale], "item is built from the cached URL, not a re-signed one")

            await AudioCache.shared.remove(keys: [key])
        }

        /// Architecture-review finding: the near-gapless preload built an `AVPlayerItem` straight
        /// from a Jamendo row's RAW, unresolved locator instead of skipping it, and `finishOrdinaryLoad`
        /// then reused that unresolved preload in place of the URL it had just correctly resolved. A
        /// raw `jamendo://` item can never open — combined with the just-reverted silent auto-advance,
        /// that cascaded through an entire queue with no error shown.
        @Test func testPreloadNextItemNeverBuildsFromARawJamendoLocator() async throws {
            let spy = Spy()
            try install(spy: spy)
            let player = AudioPlayer.shared
            player.queue = [CatalogPlaybackURLResolverTests.row(kind: .iaItem, nodeID: nil, url: "https://example.test/ia.mp3"),
                            moodStarterJamendo()]
            player.index = 0
            player.preloadedNextItem = nil
            player.preloadedNextTrackId = nil

            player.preloadNextItem()
            await settle()

            #expect(player.preloadedNextTrackId == nil, "a Jamendo-locator row must never be preloaded from its raw URL")
            #expect(player.preloadedNextItem == nil)
        }

        @Test func testDropboxRowIsReResolvedThroughFreshenerBeforeItemIsBuilt() async throws {
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
            #expect(spy.urls == [fresh.absoluteString], "OAuth cloud rows must be re-resolved, not played from the stale stored URL")
        }

        /// Same raw-locator defect as the preload test above, for the prefetch warm path.
        @Test func testPrefetchNextNeverWarmsARawJamendoLocator() async throws {
            let player = AudioPlayer.shared
            defer { player.prefetchDepth = 0 }
            var current = CatalogPlaybackURLResolverTests.row(kind: .iaItem, nodeID: nil, url: "https://example.test/current.mp3")
            current.track.id = 301
            let next = moodStarterJamendo()

            player.queue = [current, next]
            player.index = 0
            player.prefetchDepth = 1
            player.prefetchNext()
            await settle()

            #expect(player.prefetchLoaders[next.track.id ?? -1] == nil, "a Jamendo-locator row must never be warmed from its raw URL")
            #expect(player.prefetchedURLs[next.track.id ?? -1] == nil)
        }

        /// Real report: a cloud-drive track played fine the FIRST time a queue reached it directly,
        /// but silently failed whenever it was reached via the near-gapless prefetch path instead —
        /// `prefetchNext` read `asset.transientRemoteHeaders`/the stored `remoteURL` straight off the
        /// queue, never through `remoteRowFreshener` the way `loadCurrent` does for the current track.
        @Test func testPrefetchNextFreshensACloudDriveRowBeforeBuildingItsLoader() async throws {
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

            #expect(player.prefetchedURLs[102] == fresh,
                "the prefetched-ahead row must use the freshened URL, not the stale one straight off the queue")
        }

        /// Same gap as the prefetch test above, for the near-gapless PRELOADED item
        /// (`preloadNextItem`/the `finishOrdinaryLoad` branch that reuses it directly, bypassing
        /// `loadCurrent`'s own freshening entirely).
        @Test func testPreloadNextItemFreshensACloudDriveRowBeforeBuildingItem() async throws {
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

            #expect(player.preloadedNextTrackId == 202)
            #expect(player.preloadedNextLoader?.cacheKey == AudioCache.key(for: fresh),
                "the preloaded item's loader must be built from the freshened URL, not the stale one straight off the queue")
        }

        @Test func testStaleResolverCompletionCannotReplaceNewQueueOrResumeStoppedPlayback() async throws {
            let spy = Spy(), gate = Gate()
            try install(gate: gate, spy: spy)
            let player = AudioPlayer.shared
            load([jamendo()])
            load([CatalogPlaybackURLResolverTests.row(kind: .iaItem, nodeID: nil, url: "https://example.test/ia.mp3")])
            gate.release()
            await settle()
            #expect(!spy.urls.contains(fresh.absoluteString), "stale Jamendo result replaced a newer queue")

            let spy2 = Spy(), gate2 = Gate()
            try install(gate: gate2, spy: spy2)
            load([jamendo()])
            player.clearQueuePlayback()
            gate2.release()
            await settle()
            #expect(spy2.urls.isEmpty)
            #expect(!player.isPlaying)
        }

        @Test func testOrdinaryJamendoStaleHTTPFailureRefreshesOnceThenFailsTruthfully() async throws {
            let spy = Spy()
            try install(spy: spy)
            let player = AudioPlayer.shared
            player.networkSkipMessage = nil
            load([jamendo()])
            await settle()
            #expect(spy.urls.count == 1)

            player.handleOrdinaryJamendoLoaderFailure(httpStatus: 403)
            await settle()
            #expect(spy.urls.count == 2, "one retry after the first stale failure")
            #expect(spy.refreshes == 2)

            player.handleOrdinaryJamendoLoaderFailure(httpStatus: 403)
            await settle()
            #expect(spy.urls.count == 2, "no second retry")
            #expect(spy.refreshes == 2)
            #expect(player.networkSkipMessage == RemotePlaybackFailure.jamendoLocatorUnavailable.userMessage)
            #expect(!player.isPlaying)
        }

        @Test func testStatuslessFailedJamendoItemPublishesTruthfulFailure() async throws {
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
            #expect(player.networkSkipMessage == RemotePlaybackFailure.jamendoLocatorUnavailable.userMessage)
            #expect(player.player.currentItem == nil)
            #expect(!player.isPlaying)
        }

        @Test func testTerminalTransientLoaderFailureDoesNotLeaveFailedItemStranded() async throws {
            let spy = Spy()
            try install(spy: spy)
            let player = AudioPlayer.shared
            player.networkSkipMessage = nil
            load([jamendo()])
            await settle()
            let builds = spy.urls.count, refreshes = spy.refreshes
            player.handleOrdinaryJamendoTerminalLoaderFailure(httpStatus: 503)
            await settle()
            #expect(player.networkSkipMessage == RemotePlaybackFailure.jamendoLocatorUnavailable.userMessage)
            #expect(player.player.currentItem == nil)
            #expect(spy.urls.count == builds, "no extra build/open loop")
            #expect(spy.refreshes == refreshes, "no extra refresh")
            player.handleOrdinaryJamendoTerminalLoaderFailure(httpStatus: 503)
            #expect(spy.refreshes == refreshes)
        }

        @Test func testStaleTerminalLoaderFailureCannotStopReplacementQueue() async throws {
            let spy = Spy()
            try install(spy: spy)
            let player = AudioPlayer.shared
            load([jamendo()])
            await settle()
            load([CatalogPlaybackURLResolverTests.row(kind: .iaItem, nodeID: nil, url: "https://example.test/ia.mp3")])
            await settle()
            player.networkSkipMessage = nil
            let item = player.player.currentItem
            #expect(item != nil)
            player.handleOrdinaryJamendoTerminalLoaderFailure(httpStatus: nil)
            player.handleOrdinaryJamendoTerminalLoaderFailure(httpStatus: 503)
            #expect(player.player.currentItem === item)
            #expect(player.networkSkipMessage == nil)
        }

        @Test func testTransientBrowseRowPlaysFreshURLWithoutCatalogInsert() async throws {
            let spy = Spy()
            try install(spy: spy)
            let store = FakeCatalog()
            let player = AudioPlayer.shared
            // Empty catalog: a catalog lookup would fail this load.
            player.catalogPlaybackURLResolver.lookup = { _ in Issue.record("browse row must not look up catalog"); return nil }
            load([CatalogPlaybackURLResolverTests.row(kind: .jamendoGenre, nodeID: "99123", url: stale, sourceID: nil)])
            await settle()
            #expect(spy.urls == [fresh.absoluteString])
            #expect(store.row(BlendCatalogTrack.jamendoKey(trackID: "99123")) == nil)
        }

        @Test func testNonJamendoRemoteRowStillUsesUnchangedBuildPath() async throws {
            let spy = Spy()
            try install(spy: spy)
            load([CatalogPlaybackURLResolverTests.row(kind: .iaItem, nodeID: nil, url: "https://example.test/ia.mp3")])
            #expect(spy.urls == ["https://example.test/ia.mp3"], "synchronous, no resolver")
            #expect(spy.refreshes == 0)
        }

        @Test func testJamendoRowMissingNodeIDFailsAndNeverBuildsRawURLItem() async throws {
            let spy = Spy()
            try install(spy: spy)
            let player = AudioPlayer.shared
            player.networkSkipMessage = nil
            load([CatalogPlaybackURLResolverTests.row(kind: .jamendoGenre, nodeID: nil, url: "https://stale.example")])
            await settle()
            #expect(player.networkSkipMessage == RemotePlaybackFailure.jamendoLocatorUnavailable.userMessage)
            #expect(spy.urls.isEmpty, "raw URL must never reach buildItem")
            #expect(spy.refreshes == 0)
        }

        /// #387 regressed this: it added a "silently advance past the dead track" branch gated on
        /// `catalogPlaybackAutoplay || isPlaying`, which is true for an ordinary manual tap (not just
        /// an unattended autoplay chain), and announced at most the FIRST skip in a sequence. Combined
        /// with other defects that could make every queued Jamendo row fail the same way, that walked
        /// silently through the whole queue. A failed remote track must always stop and say why — the
        /// queue position must never move as a side effect of a failure, under any `isPlaying`/
        /// `catalogPlaybackAutoplay` combination, and repeating the failure must not change that.
        @Test func testFailedRemotePlaybackAlwaysStopsAndNeverSilentlyAdvancesTheQueue() async throws {
            let spy = Spy()
            try install(spy: spy)
            let player = AudioPlayer.shared
            player.networkSkipMessage = nil
            load([jamendo(), CatalogPlaybackURLResolverTests.row(kind: .iaItem, nodeID: nil, url: "https://example.test/ia.mp3")])
            // Emulate the exact condition #387 misread as "an unattended autoplay chain":
            // the engine happens to be in a playing state when the failure lands.
            player.isPlaying = true

            player.failRemotePlayback(.jamendoLocatorUnavailable)
            #expect(player.index == 0, "a failed remote track must never silently advance the queue")
            #expect(player.networkSkipMessage == RemotePlaybackFailure.jamendoLocatorUnavailable.userMessage)
            #expect(!player.isPlaying)

            // A second failure (e.g. a retry) must not behave any differently.
            player.isPlaying = true
            player.failRemotePlayback(.jamendoLocatorUnavailable)
            #expect(player.index == 0)
            #expect(player.networkSkipMessage == RemotePlaybackFailure.jamendoLocatorUnavailable.userMessage)
        }
    }
}
#endif
