import XCTest
@testable import TonearmCore

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

final class AudioLocatorTests: XCTestCase {
    private let fresh = URL(string: "https://example.test/fresh.mp3")!
    private let stale = URL(string: "https://example.test/stale.mp3")!

    private func resolver(refreshes: Counter, fail: Bool = false, sleeps: Counter = Counter()) -> JamendoLocatorResolver {
        JamendoLocatorResolver(maxTransientAttempts: 3, backoff: { _ in 0 }, sleep: { _ in _ = sleeps.next() },
                               refresh: { [fresh] _ in
            _ = refreshes.next()
            if fail { throw URLError(.notConnectedToInternet) }
            return (fresh, nil)
        })
    }

    func testStarterUsesPinnedReleaseAndNonStarterHasNoReleaseURL() {
        let pack = StarterBlendPack.v2
        XCTAssertEqual(pack.locator(trackID: "337997"),
                       .starterRelease(packTag: "starter-blends-aac-v2", assetName: "337997.m4a"))
        XCTAssertEqual(StarterBlendCatalog.starterTrackIDs.count, 36)
        XCTAssertNil(pack.assetURL(trackID: "999999999"))
        XCTAssertNil(pack.locator(trackID: "999999999"))
    }

    func testStarterLocatorNeverResolvesThroughJamendo() async {
        let r = Counter()
        do {
            _ = try await resolver(refreshes: r).open(.starterRelease(packTag: "t", assetName: "a.m4a")) { $0 }
            XCTFail()
        } catch { XCTAssertEqual(error as? JamendoResolveError, .permanent) }
        XCTAssertEqual(r.value, 0)
    }

    func testValidCachedURLIsUsedWithoutRefresh() async throws {
        let r = Counter()
        let url = try await resolver(refreshes: r).open(
            .jamendo(trackID: "1", cachedURL: stale, expiry: Date().addingTimeInterval(60))) { $0 }
        XCTAssertEqual(url, stale)
        XCTAssertEqual(r.value, 0)
    }

    func testMissingOrExpiredLocatorResolvesFromIdentity() async throws {
        let r = Counter()
        let a = try await resolver(refreshes: r).open(.jamendo(trackID: "1", cachedURL: nil, expiry: nil)) { $0 }
        let b = try await resolver(refreshes: r).open(
            .jamendo(trackID: "1", cachedURL: stale, expiry: Date().addingTimeInterval(-1))) { $0 }
        XCTAssertEqual([a, b], [fresh, fresh])
        XCTAssertEqual(r.value, 2)
    }

    func testUnauthorizedRefreshesExactlyOnceThenRetries() async throws {
        let r = Counter()
        let opens = Counter()
        let url = try await resolver(refreshes: r).open(.jamendo(trackID: "1", cachedURL: stale, expiry: nil)) { [stale] u in
            _ = opens.next()
            if u == stale { throw JamendoLocatorFailure.expiredOrInvalid }
            return u
        }
        XCTAssertEqual(url, fresh)
        XCTAssertEqual(r.value, 1)
        XCTAssertEqual(opens.value, 2)
    }

    func testStillInvalidAfterRefreshFailsWithoutSecondRefresh() async {
        let r = Counter()
        do {
            _ = try await resolver(refreshes: r).open(.jamendo(trackID: "1", cachedURL: stale, expiry: nil)) { _ -> URL in
                throw JamendoLocatorFailure.expiredOrInvalid
            }
            XCTFail()
        } catch { XCTAssertEqual(error as? JamendoResolveError, .refreshFailed) }
        XCTAssertEqual(r.value, 1)
    }

    func testRefreshFailureIsTruthful() async {
        let r = Counter()
        do {
            _ = try await resolver(refreshes: r, fail: true).open(.jamendo(trackID: "1", cachedURL: nil, expiry: nil)) { $0 }
            XCTFail()
        } catch { XCTAssertEqual(error as? JamendoResolveError, .refreshFailed) }
    }

    func testTransientRetriesAreBoundedAndDoNotRefresh() async {
        let r = Counter(), opens = Counter(), sleeps = Counter()
        do {
            _ = try await resolver(refreshes: r, sleeps: sleeps).open(.jamendo(trackID: "1", cachedURL: stale, expiry: nil)) { _ -> URL in
                _ = opens.next(); throw JamendoLocatorFailure.transient
            }
            XCTFail()
        } catch { XCTAssertEqual(error as? JamendoResolveError, .transientExhausted) }
        XCTAssertEqual(opens.value, 3)
        XCTAssertEqual(sleeps.value, 2)
        XCTAssertEqual(r.value, 0)
    }

    func testTransientThenSuccess() async throws {
        let opens = Counter()
        let url = try await resolver(refreshes: Counter()).open(.jamendo(trackID: "1", cachedURL: stale, expiry: nil)) { u in
            if opens.next() == 1 { throw JamendoLocatorFailure.transient }
            return u
        }
        XCTAssertEqual(url, stale)
    }

    func testPermanentFailureStopsImmediately() async {
        let r = Counter(), opens = Counter()
        do {
            _ = try await resolver(refreshes: r).open(.jamendo(trackID: "1", cachedURL: stale, expiry: nil)) { _ -> URL in
                _ = opens.next(); throw JamendoLocatorFailure.permanent
            }
            XCTFail()
        } catch { XCTAssertEqual(error as? JamendoResolveError, .permanent) }
        XCTAssertEqual(opens.value, 1)
        XCTAssertEqual(r.value, 0)
    }

    func testCancellationPropagates() async {
        let opens = Counter()
        do {
            _ = try await resolver(refreshes: Counter()).open(.jamendo(trackID: "1", cachedURL: stale, expiry: nil)) { _ -> URL in
                _ = opens.next(); throw CancellationError()
            }
            XCTFail()
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(opens.value, 1)
    }
}
