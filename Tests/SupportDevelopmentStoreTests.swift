import XCTest
@testable import TonearmCore

/// Fake seam — StoreKit's own `Product`/`Transaction` have no public
/// initializer outside StoreKitTest (simulator-only), so this fake speaks in
/// the store's own vocabulary instead of StoreKit's.
final class FakeSupportDevelopmentPurchasing: SupportDevelopmentPurchasing, @unchecked Sendable {
    var stubbedLookup: SupportProductLookup = .productNotFound
    var stubbedOutcome: SupportPurchaseOutcome = .cancelled
    var stubbedDisplayPrice: String? {
        get { nil }
        set { stubbedLookup = newValue.map { .found(productID: SupportDevelopmentStore.productID, displayPrice: $0) } ?? .productNotFound }
    }
    var stubbedPurchaseResult: Bool {
        get { stubbedOutcome == .success(productID: SupportDevelopmentStore.productID) }
        set { stubbedOutcome = newValue ? .success(productID: SupportDevelopmentStore.productID) : .cancelled }
    }
    private(set) var loadCallCount = 0
    private(set) var purchaseCallCount = 0

    func loadProduct() async -> SupportProductLookup {
        loadCallCount += 1
        return stubbedLookup
    }

    func purchase() async -> SupportPurchaseOutcome {
        purchaseCallCount += 1
        return stubbedOutcome
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

    func testWrongProductLookupIsUnavailable() async {
        let fake = FakeSupportDevelopmentPurchasing()
        fake.stubbedLookup = .found(productID: "other.product", displayPrice: "$1.00")
        let store = makeStore(purchasing: fake)
        await store.loadProduct()
        XCTAssertEqual(store.loadState, .unavailable)
        XCTAssertFalse(store.isPurchaseAvailable)
    }

    func testProductNotFoundAndTransportFailureAreDistinct() async {
        let fake = FakeSupportDevelopmentPurchasing()
        let store = makeStore(purchasing: fake)
        fake.stubbedLookup = .productNotFound
        await store.loadProduct()
        XCTAssertEqual(store.loadState, .unavailable)
        let notFoundReason = store.unavailableReason
        fake.stubbedLookup = .failed(diagnostic: "offline (NSURLErrorDomain -1009)")
        await store.loadProduct()
        XCTAssertEqual(store.loadState, .failed(diagnostic: "offline (NSURLErrorDomain -1009)"))
        XCTAssertEqual(store.lastDiagnostic, "offline (NSURLErrorDomain -1009)")
        XCTAssertNotNil(store.unavailableReason)
        XCTAssertNotEqual(store.unavailableReason, notFoundReason)
    }

    func testNonSuccessOutcomesLeaveSupporterFalse() async {
        let outcomes: [SupportPurchaseOutcome] = [
            .cancelled, .pending, .unverified, .productNotFound, .failed(diagnostic: "x"),
            .success(productID: "other.product")]
        for outcome in outcomes {
            let fake = FakeSupportDevelopmentPurchasing()
            fake.stubbedOutcome = outcome
            let store = makeStore(purchasing: fake)
            let ok = await store.purchase()
            XCTAssertFalse(ok, "\(outcome)")
            XCTAssertFalse(store.isSupporter, "\(outcome)")
            XCTAssertFalse(store.purchasing)
            XCTAssertEqual(store.lastPurchaseOutcome, outcome)
        }
    }
}
