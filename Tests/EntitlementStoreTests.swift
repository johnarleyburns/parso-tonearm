import XCTest
@testable import TonearmCore

/// T.2 rules 2–4 and FR-STORE-1/2/3/7, unit-tested without a live StoreKit
/// configuration: the cached value wins offline and is read before any StoreKit
/// call, a failed StoreKit call never revokes, a verified revocation clears
/// (T.4 row 3), a grant arriving mid-session flips `isPro` (AT-STORE-2), and
/// the purchase/restore path runs through the fake source and needs no
/// relaunch.
@MainActor
final class EntitlementStoreTests: XCTestCase {

    private let productID = FoundersGrant.productID

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
        writeCache(EntitlementCache(isPro: true, source: .purchased, timestamp: Date()),
                   at: cacheURL)
        let store = makeStore(current: [], cacheURL: cacheURL)  // StoreKit would report nothing
        XCTAssertTrue(store.isPro)
        XCTAssertEqual(store.source, .purchased)
    }

    // T.2 rule 2 + M4 decision 1: a legacy cache row written before the product
    // repurpose (`.foundersGrant`) still decodes and grants — the cache enum is
    // stable even though the decision table no longer produces that source.
    func testLegacyFoundersGrantCacheStillDecodes() {
        let (cacheURL, _) = freshCacheLocation()
        writeCache(EntitlementCache(isPro: true, source: .foundersGrant, timestamp: Date()),
                   at: cacheURL)
        let store = makeStore(current: [], cacheURL: cacheURL)
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
        writeCache(EntitlementCache(isPro: true, source: .purchased, timestamp: Date()),
                   at: cacheURL)
        let store = makeStore(current: [], cacheURL: cacheURL)
        await store.refresh()
        XCTAssertTrue(store.isPro)
        XCTAssertEqual(store.source, .purchased)
    }

    // A verified own purchase grants `.purchased` and persists the cache
    // (T.4 row 1).
    func testVerifiedOwnPurchaseGrantsPurchased() async {
        let (store, cacheURL) = makeStore(current: [
            TransactionFact(productID: productID, isVerified: true, isRevoked: false, isFamilyShared: false),
        ])
        await store.refresh()
        XCTAssertTrue(store.isPro)
        XCTAssertEqual(store.source, .purchased)
        XCTAssertEqual(EntitlementCacheStore(fileURL: cacheURL).load()?.source, .purchased)
    }

    // Family-shared copy grants `.familyShared` (T.4 row 2).
    func testFamilySharedCopyGrantsFamilyShared() async {
        let (store, _) = makeStore(current: [
            TransactionFact(productID: productID, isVerified: true, isRevoked: false, isFamilyShared: true),
        ])
        await store.refresh()
        XCTAssertEqual(store.source, .familyShared)
    }

    // T.4 row 3: a revoked transaction clears a previously granted entitlement.
    func testRevocationClearsGrant() async {
        let (cacheURL, _) = freshCacheLocation()
        writeCache(EntitlementCache(isPro: true, source: .purchased, timestamp: Date()),
                   at: cacheURL)
        let store = makeStore(current: [
            TransactionFact(productID: productID, isVerified: true, isRevoked: true, isFamilyShared: false),
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
            TransactionFact(productID: productID, isVerified: true, isRevoked: false, isFamilyShared: true),
        ])
        await upgraded.refresh()
        XCTAssertTrue(upgraded.isPro)
        XCTAssertEqual(upgraded.source, .familyShared)
    }

    // FR-STORE-7 / T.2 rule 5: the cache file holds only a boolean, a source
    // enum, and a timestamp — no user identifier, no receipt, no device ID.
    func testCacheFileContainsNoUserIdentifier() async throws {
        let (store, cacheURL) = makeStore(current: [
            TransactionFact(productID: productID, isVerified: true, isRevoked: false, isFamilyShared: false),
        ])
        await store.refresh()

        let data = try XCTUnwrap(try? Data(contentsOf: cacheURL))
        let json = try XCTUnwrap(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["isPro", "source", "timestamp"],
                       "Only a boolean, a source enum, and a timestamp (FR-STORE-7)")
    }

    // FR-STORE-1 / AT-STORE-2: a verified purchase through the store flips
    // `isPro` immediately — the decks unlock without a relaunch.
    func testPurchaseGrantsWithoutRelaunch() async {
        let (store, cacheURL) = makeStore(source: FakeEntitlementSource(current: [], grantOnPurchase: true))
        XCTAssertFalse(store.isPro)

        let ok = await store.purchase()
        XCTAssertTrue(ok, "the verified purchase succeeded")
        XCTAssertTrue(store.isPro, "the purchase flipped isPro in-process (AT-STORE-2)")
        XCTAssertEqual(store.source, .purchased)
        XCTAssertEqual(EntitlementCacheStore(fileURL: cacheURL).load()?.source, .purchased)
    }

    // A cancelled or failed purchase grants nothing.
    func testCancelledPurchaseGrantsNothing() async {
        let (store, _) = makeStore(source: FakeEntitlementSource(current: []))
        XCTAssertFalse(store.isPro)

        let ok = await store.purchase()
        XCTAssertFalse(ok)
        XCTAssertFalse(store.isPro)
    }

    // FR-STORE-3: restore re-derives from currentEntitlements and flips isPro
    // without a relaunch.
    func testRestoreReDerivesTheGrant() async {
        let (store, _) = makeStore(source: FakeEntitlementSource(current: [], grantOnRestore: true))
        XCTAssertFalse(store.isPro)

        await store.restore()
        XCTAssertTrue(store.isPro, "restore re-derived the entitlement (FR-STORE-3)")
        XCTAssertEqual(store.source, .purchased)
    }

    // A restore that finds nothing grants nothing.
    func testRestoreWithNoPurchasesGrantsNothing() async {
        let (store, _) = makeStore(source: FakeEntitlementSource(current: []))
        await store.restore()
        XCTAssertFalse(store.isPro)
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

    /// Builds a store over an injected source (the purchase/restore path).
    private func makeStore(source: FakeEntitlementSource) -> (store: EntitlementStore, cacheURL: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EntitlementStoreTests-\(UUID().uuidString)", isDirectory: true)
        let cacheURL = dir.appendingPathComponent("entitlement-cache.json")
        return (EntitlementStore(entitlementSource: source,
                                 cacheStore: EntitlementCacheStore(fileURL: cacheURL)),
                cacheURL)
    }
}

/// A `Sendable` StoreKit stand-in (a struct, the original pattern): returns
/// canned facts, optionally throwing, with a controllable `Transaction.updates`
/// stream and a scripted purchase/restore path. A purchase/restore that
/// "succeeds" surfaces the verified grant fact in `currentTransactions`, exactly
/// as StoreKit's `currentEntitlements` would after a real purchase — so the
/// store's own `refresh()` re-derives it (AT-STORE-2).
private struct FakeEntitlementSource: EntitlementSource {
    let current: [TransactionFact]
    let shouldThrow: Bool
    let stream: AsyncStream<TransactionFact>
    let grantOnPurchase: Bool
    let grantOnRestore: Bool

    init(current: [TransactionFact],
         shouldThrow: Bool = false,
         stream: AsyncStream<TransactionFact>? = nil,
         grantOnPurchase: Bool = false,
         grantOnRestore: Bool = false) {
        self.current = current
        self.shouldThrow = shouldThrow
        self.stream = stream ?? AsyncStream { _ in }
        self.grantOnPurchase = grantOnPurchase
        self.grantOnRestore = grantOnRestore
    }

    func currentTransactions() async throws -> [TransactionFact] {
        if shouldThrow { throw FakeEntitlementSourceError.failed }
        if grantOnPurchase || grantOnRestore {
            if current.contains(where: { $0.productID == FoundersGrant.productID && $0.isVerified }) {
                return current
            }
            return current + [grant]
        }
        return current
    }

    func transactionUpdates() -> AsyncStream<TransactionFact> {
        stream
    }

    func purchase() async -> Bool { grantOnPurchase }
    func restore() async {}

    private var grant: TransactionFact {
        TransactionFact(productID: FoundersGrant.productID,
                        isVerified: true,
                        isRevoked: false,
                        isFamilyShared: false)
    }
}

private enum FakeEntitlementSourceError: Error {
    case failed
}
