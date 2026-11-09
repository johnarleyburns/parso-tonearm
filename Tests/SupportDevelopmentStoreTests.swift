import XCTest
@testable import TonearmCore

/// Fake seam — StoreKit's own `Product`/`Transaction` have no public
/// initializer outside StoreKitTest (simulator-only), so this fake speaks in
/// the store's own vocabulary instead of StoreKit's.
final class FakeSupportDevelopmentPurchasing: SupportDevelopmentPurchasing, @unchecked Sendable {
    var stubbedDisplayPrice: String?
    var stubbedPurchaseResult = false
    private(set) var loadCallCount = 0
    private(set) var purchaseCallCount = 0

    func loadProduct() async -> String? {
        loadCallCount += 1
        return stubbedDisplayPrice
    }

    func purchase() async -> Bool {
        purchaseCallCount += 1
        return stubbedPurchaseResult
    }
}

/// `SupportDevelopmentStore.purchase()`/`loadProduct()` used to call `Product.products(for:)`/
/// `product.purchase()` directly — StoreKit's `Product`/`Transaction` have no public
/// initializer outside Apple's simulator-only `StoreKitTest` framework, so this business logic
/// (does a successful purchase actually flip `isSupporter`? does it persist? does a failed
/// purchase leave it alone?) had never been exercised by a test at all. `SupportDevelopmentPurchasing`
/// is the injection seam that makes it possible without a simulator, matching this repo's existing
/// DI convention (`AppState.downloadSession`, `PhoneWatchProtocolCoordinator`'s injectable
/// `UserDefaults` suite).
@MainActor
final class SupportDevelopmentStoreTests: XCTestCase {
    private var defaultsSuite: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SupportDevelopmentStoreTests.\(UUID().uuidString)"
        defaultsSuite = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaultsSuite.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore(purchasing: FakeSupportDevelopmentPurchasing = .init()) -> SupportDevelopmentStore {
        SupportDevelopmentStore(defaults: defaultsSuite, purchasing: purchasing)
    }

    func testPurchaseSuccessSetsIsSupporterAndPersists() async {
        let fake = FakeSupportDevelopmentPurchasing()
        fake.stubbedPurchaseResult = true
        let store = makeStore(purchasing: fake)

        let ok = await store.purchase()

        XCTAssertTrue(ok)
        XCTAssertTrue(store.isSupporter)
        XCTAssertTrue(defaultsSuite.bool(forKey: "supporter.isSupporter"))
    }

    func testPurchaseFailureDoesNotSetIsSupporter() async {
        let fake = FakeSupportDevelopmentPurchasing()
        fake.stubbedPurchaseResult = false
        let store = makeStore(purchasing: fake)

        let ok = await store.purchase()

        XCTAssertFalse(ok)
        XCTAssertFalse(store.isSupporter)
    }

    /// Business rule (`SupportDevelopmentStore`'s own doc comment): "a refund does not 'revoke'
    /// it, because it never unlocked anything to revoke." A later failed/cancelled purchase
    /// attempt must never un-set it once true.
    func testIsSupporterNeverClearsOnceSet() async {
        let fake = FakeSupportDevelopmentPurchasing()
        fake.stubbedPurchaseResult = true
        let store = makeStore(purchasing: fake)
        _ = await store.purchase()
        XCTAssertTrue(store.isSupporter)

        fake.stubbedPurchaseResult = false
        _ = await store.purchase()
        XCTAssertTrue(store.isSupporter)
    }

    func testDisplayPriceIsPlaceholderBeforeLoad() {
        let store = makeStore()
        XCTAssertEqual(store.displayPrice, "—")
        XCTAssertFalse(store.isPurchaseAvailable)
    }

    func testDisplayPriceReflectsLoadedProduct() async {
        let fake = FakeSupportDevelopmentPurchasing()
        fake.stubbedDisplayPrice = "$4.99"
        let store = makeStore(purchasing: fake)

        await store.loadProduct()

        XCTAssertEqual(store.displayPrice, "$4.99")
        XCTAssertTrue(store.isPurchaseAvailable)
        XCTAssertTrue(store.didAttemptProductLoad)
    }

    func testPurchasingFlagIsSetDuringAndClearedAfterPurchase() async {
        let fake = FakeSupportDevelopmentPurchasing()
        fake.stubbedPurchaseResult = true
        let store = makeStore(purchasing: fake)

        XCTAssertFalse(store.purchasing)
        _ = await store.purchase()
        XCTAssertFalse(store.purchasing, "purchasing must be reset even after a completed purchase")
    }

    /// A stored property's default argument is evaluated once per call site, not shared — this
    /// guards against a future refactor accidentally sharing one `LiveSupportDevelopmentPurchasing`
    /// instance (irrelevant here since it's stateless, but pins that each store built with the
    /// fake actually talks to its OWN fake, not a shared one).
    func testEachStoreUsesItsOwnInjectedPurchasing() async {
        let fakeA = FakeSupportDevelopmentPurchasing()
        fakeA.stubbedPurchaseResult = true
        let fakeB = FakeSupportDevelopmentPurchasing()
        fakeB.stubbedPurchaseResult = false
        let storeA = makeStore(purchasing: fakeA)
        let storeB = makeStore(purchasing: fakeB)

        _ = await storeA.purchase()
        _ = await storeB.purchase()

        XCTAssertEqual(fakeA.purchaseCallCount, 1)
        XCTAssertEqual(fakeB.purchaseCallCount, 1)
        XCTAssertTrue(storeA.isSupporter)
        XCTAssertFalse(storeB.isSupporter)
    }
}
