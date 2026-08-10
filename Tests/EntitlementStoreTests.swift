import XCTest
@testable import TonearmCore

/// T.2 rules 2–4 and FR-STORE-2/7, unit-tested without a live StoreKit
/// configuration: the cached value wins offline and is read before any StoreKit
/// call, a failed StoreKit call never revokes, a verified revocation clears
/// (T.4 row 4), and a grant arriving mid-session flips `isPro` (AT-STORE-2).
@MainActor
final class EntitlementStoreTests: XCTestCase {

    private let retired = FoundersGrant.retiredProductID
    private let dj = FoundersGrant.djProductID

    /// Creates an isolated cache file and a store over it. Each call gets a
    /// fresh temp directory so tests never share entitlement state.
    private func makeStore(current: [TransactionFact],
                           shouldThrow: Bool = false,
                           stream: AsyncStream<TransactionFact>? = nil)
        -> (store: EntitlementStore, cacheURL: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EntitlementStoreTests-\(UUID().uuidString)", isDirectory: true)
        let cacheURL = dir.appendingPathComponent("entitlement-cache.json")
        let cacheStore = EntitlementCacheStore(fileURL: cacheURL)
        let store = EntitlementStore(
            entitlementSource: FakeEntitlementSource(current: current,
                                                     shouldThrow: shouldThrow,
                                                     stream: stream),
            cacheStore: cacheStore)
        return (store, cacheURL)
    }

    private func writeCache(_ cache: EntitlementCache, at url: URL) {
        EntitlementCacheStore(fileURL: url).save(cache)
    }

    // T.2 rule 2: the cached value is read at launch, before any StoreKit call.
    func testLaunchReadsCacheBeforeAnyStoreKitCall() {
        let (cacheURL, _) = freshCacheLocation()
        writeCache(EntitlementCache(isPro: true, source: .foundersGrant, timestamp: Date()),
                   at: cacheURL)
        let store = makeStore(current: [], cacheURL: cacheURL)  // StoreKit would report nothing
        XCTAssertTrue(store.isPro)
        XCTAssertEqual(store.source, .foundersGrant)
    }

    // T.2 rule 3: a failed StoreKit call never revokes — the cache stands.
    func testFailedStoreKitCallNeverRevokes() async {
        let (cacheURL, _) = freshCacheLocation()
        writeCache(EntitlementCache(isPro: true, source: .purchased, timestamp: Date()),
                   at: cacheURL)
        let store = makeStore(current: [], shouldThrow: true, cacheURL: cacheURL)
        await store.refresh()
        XCTAssertTrue(store.isPro)
        XCTAssertEqual(store.source, .purchased)
    }

    // T.2 rule 2: an empty scan (airplane mode / StoreKit delay) does not
    // revoke an existing grant.
    func testEmptyScanDoesNotRevoke() async {
        let (cacheURL, _) = freshCacheLocation()
        writeCache(EntitlementCache(isPro: true, source: .foundersGrant, timestamp: Date()),
                   at: cacheURL)
        let store = makeStore(current: [], cacheURL: cacheURL)
        await store.refresh()
        XCTAssertTrue(store.isPro)
        XCTAssertEqual(store.source, .foundersGrant)
    }

    // A verified DJ purchase grants `.purchased` and persists the cache.
    func testVerifiedDJPurchaseGrantsPurchased() async {
        let (store, cacheURL) = makeStore(current: [
            TransactionFact(productID: dj, isVerified: true, isRevoked: false, isFamilyShared: false),
        ])
        await store.refresh()
        XCTAssertTrue(store.isPro)
        XCTAssertEqual(store.source, .purchased)
        XCTAssertEqual(EntitlementCacheStore(fileURL: cacheURL).load()?.source, .purchased)
    }

    // A verified retired-product transaction grants `.foundersGrant` (row 1).
    func testVerifiedRetiredProductGrantsFounders() async {
        let (store, _) = makeStore(current: [
            TransactionFact(productID: retired, isVerified: true, isRevoked: false, isFamilyShared: false),
        ])
        await store.refresh()
        XCTAssertTrue(store.isPro)
        XCTAssertEqual(store.source, .foundersGrant)
    }

    // Family-shared DJ purchase grants `.familyShared`.
    func testFamilySharedDJGrantsFamilyShared() async {
        let (store, _) = makeStore(current: [
            TransactionFact(productID: dj, isVerified: true, isRevoked: false, isFamilyShared: true),
        ])
        await store.refresh()
        XCTAssertEqual(store.source, .familyShared)
    }

    // T.4 row 4: a revoked transaction clears a previously granted entitlement.
    func testRevocationClearsGrant() async {
        let (cacheURL, _) = freshCacheLocation()
        writeCache(EntitlementCache(isPro: true, source: .foundersGrant, timestamp: Date()),
                   at: cacheURL)
        let store = makeStore(current: [
            TransactionFact(productID: retired, isVerified: true, isRevoked: true, isFamilyShared: false),
        ], cacheURL: cacheURL)
        await store.refresh()
        XCTAssertFalse(store.isPro)
        XCTAssertEqual(store.source, .none)
        XCTAssertNil(EntitlementCacheStore(fileURL: cacheURL).load())
    }

    // T.2 rule 4 / AT-STORE-2: a grant arriving mid-session flips isPro without
    // a relaunch — a later scan (the updates observer's refresh path) reflects
    // it immediately.
    func testGrantArrivingMidSessionFlipsIsPro() async {
        let (store, _) = makeStore(current: [])
        await store.refresh()
        XCTAssertFalse(store.isPro)

        let (upgraded, _) = makeStore(current: [
            TransactionFact(productID: dj, isVerified: true, isRevoked: false, isFamilyShared: true),
        ])
        await upgraded.refresh()
        XCTAssertTrue(upgraded.isPro)
        XCTAssertEqual(upgraded.source, .familyShared)
    }

    // FR-STORE-7 / T.2 rule 5: the cache file holds only a boolean, a source
    // enum, and a timestamp — no user identifier, no receipt, no device ID.
    func testCacheFileContainsNoUserIdentifier() async throws {
        let (store, cacheURL) = makeStore(current: [
            TransactionFact(productID: dj, isVerified: true, isRevoked: false, isFamilyShared: false),
        ])
        await store.refresh()

        let data = try XCTUnwrap(try? Data(contentsOf: cacheURL))
        let json = try XCTUnwrap(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["isPro", "source", "timestamp"],
                       "Only a boolean, a source enum, and a timestamp (FR-STORE-7)")
    }

    // Revoked retired product but owns DJ: the DJ purchase still grants.
    func testRevokedRetiredWithDJPurchaseStillGrants() async {
        let (store, _) = makeStore(current: [
            TransactionFact(productID: retired, isVerified: true, isRevoked: true, isFamilyShared: false),
            TransactionFact(productID: dj, isVerified: true, isRevoked: false, isFamilyShared: false),
        ])
        await store.refresh()
        XCTAssertTrue(store.isPro)
        XCTAssertEqual(store.source, .purchased)
    }

    // MARK: - Helpers

    /// Returns a unique temp cache file URL and its parent directory.
    private func freshCacheLocation() -> (url: URL, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EntitlementStoreTests-\(UUID().uuidString)", isDirectory: true)
        return (dir.appendingPathComponent("entitlement-cache.json"), dir)
    }

    /// Builds a store over an explicit cache file (used to seed the cache).
    private func makeStore(current: [TransactionFact],
                           shouldThrow: Bool = false,
                           stream: AsyncStream<TransactionFact>? = nil,
                           cacheURL: URL) -> EntitlementStore {
        EntitlementStore(
            entitlementSource: FakeEntitlementSource(current: current,
                                                     shouldThrow: shouldThrow,
                                                     stream: stream),
            cacheStore: EntitlementCacheStore(fileURL: cacheURL))
    }
}

/// A `Sendable` StoreKit stand-in: returns canned facts, optionally throwing,
/// with a controllable `Transaction.updates` stream.
private struct FakeEntitlementSource: EntitlementSource {
    private let current: [TransactionFact]
    private let shouldThrow: Bool
    private let stream: AsyncStream<TransactionFact>

    init(current: [TransactionFact],
         shouldThrow: Bool = false,
         stream: AsyncStream<TransactionFact>? = nil) {
        self.current = current
        self.shouldThrow = shouldThrow
        self.stream = stream ?? AsyncStream { _ in }
    }

    func currentTransactions() async throws -> [TransactionFact] {
        if shouldThrow { throw FakeEntitlementSourceError.failed }
        return current
    }

    func transactionUpdates() -> AsyncStream<TransactionFact> {
        stream
    }
}

private enum FakeEntitlementSourceError: Error {
    case failed
}
