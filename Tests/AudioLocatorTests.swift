import Foundation
import Testing
@testable import TonearmCore

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

@Suite struct AudioLocatorTests {
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

    @Test func testValidCachedURLIsUsedWithoutRefresh() async throws {
        let r = Counter()
        let url = try await resolver(refreshes: r).open(
            .jamendo(trackID: "1", cachedURL: stale, expiry: Date().addingTimeInterval(60))) { $0 }
        #expect(url == stale)
        #expect(r.value == 0)
    }

    @Test func testMissingOrExpiredLocatorResolvesFromIdentity() async throws {
        let r = Counter()
        let a = try await resolver(refreshes: r).open(.jamendo(trackID: "1", cachedURL: nil, expiry: nil)) { $0 }
        let b = try await resolver(refreshes: r).open(
            .jamendo(trackID: "1", cachedURL: stale, expiry: Date().addingTimeInterval(-1))) { $0 }
        #expect([a, b] == [fresh, fresh])
        #expect(r.value == 2)
    }

    @Test func testUnauthorizedRefreshesExactlyOnceThenRetries() async throws {
        let r = Counter()
        let opens = Counter()
        let url = try await resolver(refreshes: r).open(.jamendo(trackID: "1", cachedURL: stale, expiry: nil)) { [stale] u in
            _ = opens.next()
            if u == stale { throw JamendoLocatorFailure.expiredOrInvalid }
            return u
        }
        #expect(url == fresh)
        #expect(r.value == 1)
        #expect(opens.value == 2)
    }

    @Test func testStillInvalidAfterRefreshFailsWithoutSecondRefresh() async {
        let r = Counter()
        do {
            _ = try await resolver(refreshes: r).open(.jamendo(trackID: "1", cachedURL: stale, expiry: nil)) { _ -> URL in
                throw JamendoLocatorFailure.expiredOrInvalid
            }
            Issue.record("expected open to throw")
        } catch { #expect(error as? JamendoResolveError == .refreshFailed) }
        #expect(r.value == 1)
    }

    @Test func testRefreshFailureIsTruthful() async {
        let r = Counter()
        do {
            _ = try await resolver(refreshes: r, fail: true).open(.jamendo(trackID: "1", cachedURL: nil, expiry: nil)) { $0 }
            Issue.record("expected open to throw")
        } catch { #expect(error as? JamendoResolveError == .refreshFailed) }
    }

    @Test func testTransientRetriesAreBoundedAndDoNotRefresh() async {
        let r = Counter(), opens = Counter(), sleeps = Counter()
        do {
            _ = try await resolver(refreshes: r, sleeps: sleeps).open(.jamendo(trackID: "1", cachedURL: stale, expiry: nil)) { _ -> URL in
                _ = opens.next(); throw JamendoLocatorFailure.transient
            }
            Issue.record("expected open to throw")
        } catch { #expect(error as? JamendoResolveError == .transientExhausted) }
        #expect(opens.value == 3)
        #expect(sleeps.value == 2)
        #expect(r.value == 0)
    }

    @Test func testTransientThenSuccess() async throws {
        let opens = Counter()
        let url = try await resolver(refreshes: Counter()).open(.jamendo(trackID: "1", cachedURL: stale, expiry: nil)) { u in
            if opens.next() == 1 { throw JamendoLocatorFailure.transient }
            return u
        }
        #expect(url == stale)
    }

    @Test func testPermanentFailureStopsImmediately() async {
        let r = Counter(), opens = Counter()
        do {
            _ = try await resolver(refreshes: r).open(.jamendo(trackID: "1", cachedURL: stale, expiry: nil)) { _ -> URL in
                _ = opens.next(); throw JamendoLocatorFailure.permanent
            }
            Issue.record("expected open to throw")
        } catch { #expect(error as? JamendoResolveError == .permanent) }
        #expect(opens.value == 1)
        #expect(r.value == 0)
    }

    @Test func testCancellationPropagates() async {
        let opens = Counter()
        do {
            _ = try await resolver(refreshes: Counter()).open(.jamendo(trackID: "1", cachedURL: stale, expiry: nil)) { _ -> URL in
                _ = opens.next(); throw CancellationError()
            }
            Issue.record("expected open to throw")
        } catch { #expect(error is CancellationError) }
        #expect(opens.value == 1)
    }

    // MARK: - refreshOnly / identity-resolve transient retry
    //
    // Real report: a Starter Blend track (`.local` source, `jamendo://track/<id>` locator) failed
    // to play from Find with an immediate "Jamendo unavailable" toast; a manual retry also failed;
    // after enough time/attempts had passed (favoriting, force-quitting, relaunching) the exact
    // same track played fine. `CatalogPlaybackURLResolver.resolve` calls `refreshOnly` directly for
    // this exact kind of row (see its own test, `testMoodStarterJamendoLocatorRefreshesWithoutCatalogLookup`
    // in CatalogPlaybackURLResolverTests.swift) — `refreshOnly`, and `open`'s own initial identity
    // resolve (`refreshURL`), each made exactly one network attempt with none of the bounded
    // retry/backoff `open`'s own transient-failure path already has for the *streaming* open —
    // a single momentary timeout/DNS blip/5xx on the "ask Jamendo for a URL" step permanently
    // failed the whole play attempt instead of being absorbed the same way a transient streaming
    // failure already is.

    @Test func testRefreshOnlyRetriesATransientFailureBeforeGivingUp() async throws {
        let attempts = Counter()
        let sleeps = Counter()
        let resolver = JamendoLocatorResolver(maxTransientAttempts: 3, backoff: { _ in 0 },
                                              sleep: { _ in _ = sleeps.next() }, refresh: { [fresh] _ in
            let n = attempts.next()
            if n < 3 { throw URLError(.timedOut) }
            return (fresh, nil)
        })
        let result = try await resolver.refreshOnly(.jamendo(trackID: "1", cachedURL: nil, expiry: nil))
        #expect(result.url == fresh)
        #expect(attempts.value == 3)
        #expect(sleeps.value == 2)
    }

    @Test func testRefreshOnlyGivesUpAfterExhaustingTransientAttempts() async {
        let attempts = Counter()
        let resolver = JamendoLocatorResolver(maxTransientAttempts: 3, backoff: { _ in 0 }, sleep: { _ in },
                                              refresh: { _ in
            _ = attempts.next()
            throw URLError(.timedOut)
        })
        do {
            _ = try await resolver.refreshOnly(.jamendo(trackID: "1", cachedURL: nil, expiry: nil))
            Issue.record("must give up, not retry forever")
        } catch {
            #expect(error as? JamendoResolveError == .refreshFailed)
        }
        #expect(attempts.value == 3)
    }

    @Test func testRefreshOnlyPropagatesCancellationWithoutRetrying() async {
        let attempts = Counter()
        let resolver = JamendoLocatorResolver(maxTransientAttempts: 3, backoff: { _ in 0 }, sleep: { _ in },
                                              refresh: { _ in
            _ = attempts.next()
            throw CancellationError()
        })
        do {
            _ = try await resolver.refreshOnly(.jamendo(trackID: "1", cachedURL: nil, expiry: nil))
            Issue.record("expected refreshOnly to throw")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(attempts.value == 1)
    }

    @Test func testOpenRetriesTheInitialIdentityResolveOnTransientFailure() async throws {
        let attempts = Counter()
        let resolver = JamendoLocatorResolver(maxTransientAttempts: 3, backoff: { _ in 0 }, sleep: { _ in },
                                              refresh: { [fresh] _ in
            let n = attempts.next()
            if n < 2 { throw URLError(.timedOut) }
            return (fresh, nil)
        })
        let url = try await resolver.open(.jamendo(trackID: "1", cachedURL: nil, expiry: nil)) { $0 }
        #expect(url == fresh)
        #expect(attempts.value == 2)
    }
}
