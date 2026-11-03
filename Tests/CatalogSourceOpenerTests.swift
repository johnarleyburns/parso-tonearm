#if !os(watchOS)
import XCTest
import GRDB
import AudioToolbox
@testable import TonearmCore

private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var opened: [(URL, AudioFileTypeID)] = []
    private var refreshCount = 0
    func open(_ url: URL, _ type: AudioFileTypeID) { lock.withLock { opened.append((url, type)) } }
    func refresh() { lock.withLock { refreshCount += 1 } }
    var urls: [URL] { lock.withLock { opened.map(\.0) } }
    var types: [AudioFileTypeID] { lock.withLock { opened.map(\.1) } }
    var refreshes: Int { lock.withLock { refreshCount } }
}

/// Production path: catalog row → locator → opener → range source, with only the byte-range reader and the
/// Jamendo HTTP call replaced.
final class CatalogSourceOpenerTests: XCTestCase {
    private let stale = URL(string: "https://example.test/stale.mp3")!
    private let fresh = URL(string: "https://example.test/fresh.mp3")!
    private let jamendoID = "424242"

    private func opener(_ store: LibraryStore, log: Log, refreshFails: Bool = false,
                        range: @escaping @Sendable (URL) throws -> Void) -> CatalogSourceOpener {
        let fresh = fresh
        return CatalogSourceOpener(
            lookup: { try? await store.blendCatalogTrack(key: $0) },
            resolver: JamendoLocatorResolver(maxTransientAttempts: 3, backoff: { _ in 0 }, sleep: { _ in }, refresh: { _ in
                log.refresh()
                if refreshFails { throw URLError(.notConnectedToInternet) }
                return (fresh, nil)
            }),
            openRange: { url, type, _ in
                log.open(url, type)
                try range(url)
                return SynthSource(low: 100, high: 200, seconds: 1)
            },
            persist: { key, url, expiry in try? await store.updateCachedLocator(key: key, url: url, expiry: expiry) })
    }

    private func jamendoStore(cached: URL?) async throws -> LibraryStore {
        let store = try LibraryStore(inMemory: true)
        try await store.upsertJamendoCatalogTrack(trackID: jamendoID, cachedURL: nil)
        if let cached { try await store.updateCachedLocator(key: BlendCatalogTrack.jamendoKey(trackID: jamendoID), url: cached, expiry: nil) }
        return store
    }

    private func open(_ opener: CatalogSourceOpener, _ id: String) async throws -> any StarterDeckSource {
        try await Task.detached { try opener.openBlocking(trackID: id, cancellation: StarterCancellation()) }.value
    }

    func testJamendoRowWithNoCachedURLResolvesThroughTheResolverAndPersistsIt() async throws {
        let store = try await jamendoStore(cached: nil)
        let log = Log()
        _ = try await open(opener(store, log: log) { _ in }, jamendoID)
        XCTAssertEqual(log.refreshes, 1)
        XCTAssertEqual(log.urls, [fresh])
        XCTAssertEqual(log.types, [kAudioFileMP3Type])
        try await waitForCachedURL(store, fresh)
    }

    func testExpiredCachedURLRefreshesExactlyOnceAndRetries() async throws {
        let store = try await jamendoStore(cached: stale)
        let log = Log()
        let stale = stale
        _ = try await open(opener(store, log: log) { if $0 == stale { throw ReleaseRangeError.permanent("not found (HTTP 410)") } }, jamendoID)
        XCTAssertEqual(log.refreshes, 1)
        XCTAssertEqual(log.urls, [stale, fresh])
        try await waitForCachedURL(store, fresh)
    }

    func testValidCachedURLIsUsedWithoutRefresh() async throws {
        let store = try await jamendoStore(cached: stale)
        let log = Log()
        _ = try await open(opener(store, log: log) { _ in }, jamendoID)
        XCTAssertEqual(log.refreshes, 0)
        XCTAssertEqual(log.urls, [stale])
    }

    func testStillInvalidAfterRefreshIsAPermanentTruthfulFailure() async throws {
        let store = try await jamendoStore(cached: stale)
        let log = Log()
        do {
            _ = try await open(opener(store, log: log) { _ in throw ReleaseRangeError.permanent("HTTP 401") }, jamendoID)
            XCTFail()
        } catch { XCTAssertEqual(error as? ReleaseRangeError, .permanent("the stream link could not be refreshed")) }
        XCTAssertEqual(log.refreshes, 1, "refresh happens once, never in a loop")
        XCTAssertEqual(log.urls.count, 2)
        let fetched = try await store.blendCatalogTrack(key: BlendCatalogTrack.jamendoKey(trackID: jamendoID))
        let row = try XCTUnwrap(fetched)
        XCTAssertEqual(row.cachedURL, stale.absoluteString, "a refreshed URL that never played is not persisted")
    }

    func testRefreshFailureIsReported() async throws {
        let store = try await jamendoStore(cached: nil)
        let log = Log()
        do { _ = try await open(opener(store, log: log, refreshFails: true) { _ in }, jamendoID); XCTFail() }
        catch { XCTAssertEqual(error as? ReleaseRangeError, .permanent("the stream link could not be refreshed")) }
        XCTAssertTrue(log.urls.isEmpty)
    }

    func testTransientFailuresAreBoundedAndDoNotRefresh() async throws {
        let store = try await jamendoStore(cached: stale)
        let log = Log()
        do {
            _ = try await open(opener(store, log: log) { _ in throw ReleaseRangeError.transient("HTTP 503") }, jamendoID)
            XCTFail()
        } catch { XCTAssertEqual(error as? ReleaseRangeError, .transient("Jamendo could not be reached")) }
        XCTAssertEqual(log.urls.count, 3)
        XCTAssertEqual(log.refreshes, 0)
    }

    func testPermanentFailureStopsImmediately() async throws {
        let store = try await jamendoStore(cached: stale)
        let log = Log()
        do {
            _ = try await open(opener(store, log: log) { _ in throw ReleaseRangeError.permanent("server ignored the byte range") }, jamendoID)
            XCTFail()
        } catch { XCTAssertEqual(error as? ReleaseRangeError, .permanent("this track is not available to stream")) }
        XCTAssertEqual(log.urls.count, 1, "no full-file fallback: a whole-body answer just fails")
        XCTAssertEqual(log.refreshes, 0)
    }

    func testCancellationPropagates() async throws {
        let store = try await jamendoStore(cached: stale)
        let log = Log()
        do {
            _ = try await open(opener(store, log: log) { _ in throw ReleaseRangeError.cancelled }, jamendoID)
            XCTFail()
        } catch { XCTAssertEqual(error as? ReleaseRangeError, .cancelled) }
        XCTAssertEqual(log.urls.count, 1)
        XCTAssertEqual(log.refreshes, 0)
    }

    func testUnknownIDsNeverResolve() async throws {
        let store = try LibraryStore(inMemory: true)
        let log = Log()
        let o = opener(store, log: log) { _ in }
        do { _ = try await open(o, "999999999"); XCTFail() } catch { XCTAssertTrue(error is ReleaseRangeError) }
        XCTAssertTrue(log.urls.isEmpty)
        XCTAssertEqual(log.refreshes, 0)
    }

    func testClassifyMapsRangeFailuresForTheResolver() {
        XCTAssertEqual(CatalogSourceOpener.classify(ReleaseRangeError.permanent("HTTP 403")) as? JamendoLocatorFailure, .expiredOrInvalid)
        XCTAssertEqual(CatalogSourceOpener.classify(ReleaseRangeError.permanent("not found (HTTP 404)")) as? JamendoLocatorFailure, .expiredOrInvalid)
        XCTAssertEqual(CatalogSourceOpener.classify(ReleaseRangeError.permanent("range not satisfiable")) as? JamendoLocatorFailure, .permanent)
        XCTAssertEqual(CatalogSourceOpener.classify(ReleaseRangeError.transient("x")) as? JamendoLocatorFailure, .transient)
        XCTAssertTrue(CatalogSourceOpener.classify(ReleaseRangeError.cancelled) is CancellationError)
    }

    func testMigrationBackfillsSourceIdentityAndDemotesURLsToCache() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator(upTo: "v37").migrate(queue)
        try queue.write { db in
            for (key, tag, url) in [("starter-blends-aac-v2:555", "starter-blends-aac-v2", "https://github.com/johnarleyburns/parso-tonearm/releases/download/starter-blends-aac-v2/555.m4a"),
                                    ("legacy:777", "legacy", "https://example.test/777.mp3")] {
                try db.execute(sql: "INSERT INTO blend_catalog_track (catalogKey, packTag, state, updatedAt, sourceURL) VALUES (?, ?, 'unindexed', ?, ?)",
                               arguments: [key, tag, Date(), url])
            }
        }
        try Schema.migrator().migrate(queue)
        try queue.read { db in
            // Every pre-v38 row becomes an ordinary Jamendo row now — there is no more curated-blend
            // pack to distinguish, and seeding (which used to add 54 more rows) no longer runs.
            let formerStarter = try XCTUnwrap(BlendCatalogTrack.fetchOne(db, key: "starter-blends-aac-v2:555"))
            XCTAssertEqual(formerStarter.sourceKind, .jamendo)
            XCTAssertEqual(formerStarter.providerTrackID, "555")
            XCTAssertNil(formerStarter.cachedURL, "a GitHub Release URL is never kept as a Jamendo locator")
            let legacy = try XCTUnwrap(BlendCatalogTrack.fetchOne(db, key: "legacy:777"))
            XCTAssertEqual(legacy.sourceKind, .jamendo)
            XCTAssertEqual(legacy.providerTrackID, "777")
            XCTAssertEqual(legacy.cachedURL, "https://example.test/777.mp3")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM blend_catalog_track"), 2, "seeding no longer adds rows")
        }
    }

    private func waitForCachedURL(_ store: LibraryStore, _ url: URL) async throws {
        let key = BlendCatalogTrack.jamendoKey(trackID: jamendoID)
        for _ in 0..<100 {
            if try await store.blendCatalogTrack(key: key)?.cachedURL == url.absoluteString { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("refreshed locator was not persisted")
    }
}
#endif
