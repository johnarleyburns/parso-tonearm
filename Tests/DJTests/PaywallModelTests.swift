import XCTest
@testable import TonearmCore
@testable import TonearmDJ

/// The §41.16 / §42.10 paywall view model (plan 4.13): contextual presentation
/// (FR-STORE-5, §40.4 rule 3 — shown only when the user reaches for a Pro
/// control), a purchase that flips `isPro` with no relaunch (AT-STORE-2),
/// restore (FR-STORE-3), and the no-nagging rule (FR-STORE-6, T.7 — nothing
/// re-presents the sheet after a dismissal). The model never touches StoreKit;
/// the fake source stands in for the boundary in `Sources/Pro/`.
@MainActor
final class PaywallModelTests: XCTestCase {

    private func makeStore(source: FakeSource) -> EntitlementStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaywallModelTests-\(UUID().uuidString)", isDirectory: true)
        let cacheURL = dir.appendingPathComponent("entitlement-cache.json")
        return EntitlementStore(entitlementSource: source,
                                cacheStore: EntitlementCacheStore(fileURL: cacheURL))
    }

    private func makeStore(isPro: Bool) -> EntitlementStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaywallModelTests-\(UUID().uuidString)", isDirectory: true)
        let cacheURL = dir.appendingPathComponent("entitlement-cache.json")
        EntitlementCacheStore(fileURL: cacheURL).save(
            EntitlementCache(isPro: isPro, source: isPro ? .purchased : .none, timestamp: Date()))
        return EntitlementStore(entitlementSource: FakeSource(current: []),
                                cacheStore: EntitlementCacheStore(fileURL: cacheURL))
    }

    // FR-STORE-5 / §40.4 rule 3: the sheet is never presented on init — no
    // launch interstitial, no timer — only by an explicit `present()`.
    func testPresentationIsContextualOnly() {
        let model = PaywallModel(store: makeStore(isPro: false))
        XCTAssertFalse(model.isPresented, "never on launch, never on a timer (§40.4)")
        model.present()
        XCTAssertTrue(model.isPresented, "the user reached for a Pro control — the sheet shows")
    }

    // Presenting to a Pro user is a no-op — there is nothing to sell.
    func testPresentingToAProUserIsANoOp() {
        let model = PaywallModel(store: makeStore(isPro: true))
        XCTAssertTrue(model.isPro)
        model.present()
        XCTAssertFalse(model.isPresented)
    }

    // AT-STORE-2: a verified purchase flips isPro in-process — the decks
    // unlock with no relaunch — and the sheet dismisses itself.
    func testPurchaseFlipsProWithoutRelaunch() async {
        let model = PaywallModel(store: makeStore(source: FakeSource(current: [], grantOnPurchase: true)))
        model.present()
        XCTAssertTrue(model.isPresented)

        await model.purchase()
        XCTAssertTrue(model.isPro, "the purchase flipped isPro in-process (AT-STORE-2)")
        XCTAssertTrue(model.store.isPro)
        XCTAssertFalse(model.isPresented, "a successful purchase dismisses the sheet")
        XCTAssertNil(model.lastError)
    }

    // A cancelled or failed purchase leaves the sheet up with an honest message.
    func testCancelledPurchaseLeavesTheSheetUp() async {
        let model = PaywallModel(store: makeStore(source: FakeSource(current: [])))
        model.present()
        await model.purchase()
        XCTAssertFalse(model.isPro)
        XCTAssertTrue(model.isPresented, "a failed purchase never slams the sheet shut")
        XCTAssertNotNil(model.lastError)
    }

    // FR-STORE-3: restore re-derives the grant and dismisses the sheet.
    func testRestoreReDerivesPro() async {
        let model = PaywallModel(store: makeStore(source: FakeSource(current: [], grantOnRestore: true)))
        model.present()
        await model.restore()
        XCTAssertTrue(model.isPro)
        XCTAssertFalse(model.isPresented)
    }

    func testRestoreFindingNothingLeavesTheSheetUp() async {
        let model = PaywallModel(store: makeStore(source: FakeSource(current: [])))
        model.present()
        await model.restore()
        XCTAssertFalse(model.isPro)
        XCTAssertTrue(model.isPresented)
    }

    // FR-STORE-6 / T.7: a dismissal is final for the session — nothing
    // re-presents the sheet automatically; only an explicit re-reach does.
    func testDismissalIsFinalAndNothingAutoRepresents() {
        let model = PaywallModel(store: makeStore(isPro: false))
        model.present()
        XCTAssertTrue(model.isPresented)
        model.dismiss()
        XCTAssertFalse(model.isPresented)
        XCTAssertTrue(model.dismissedThisSession)
        // No timer, no callback, no launch event flips it back.
        XCTAssertFalse(model.isPresented, "no repeat prompt after a dismissal in the same session (T.7)")

        // An explicit re-reach still shows — responsiveness is not nagging.
        model.present()
        XCTAssertTrue(model.isPresented)
    }

    // MARK: - The price is the store's, never ours (plan 6.2)

    /// The price shown is the one StoreKit gives, localised — not a constant.
    /// The old test pinned it to "$39.99", which is wrong in every storefront
    /// that does not use dollars and wrong everywhere the moment the price in
    /// App Store Connect changes.
    func testDisplayPriceComesFromTheStore() async {
        let store = makeStore(source: FakeSource(
            current: [],
            storeProduct: StoreProduct(displayPrice: "¥5,800", displayName: "Platterhead DJ")))
        let model = PaywallModel(store: store)

        XCTAssertEqual(model.displayPrice, PaywallModel.placeholderPrice,
                       "before the store answers there is no price to show — and none is invented")

        await model.loadProduct()
        XCTAssertEqual(model.displayPrice, "¥5,800",
                       "the localised price StoreKit returned, verbatim")
        XCTAssertTrue(model.isPurchaseAvailable)
        XCTAssertFalse(model.isStoreUnavailable)
    }

    /// The case a TestFlight tester meets when App Store Connect is not
    /// configured: the store answers with nothing. The sheet must say so and
    /// must not offer a Buy button that cannot work.
    func testAnUnavailableStoreIsHonestAndOffersNoBuyButton() async {
        let store = makeStore(source: FakeSource(current: [], storeProduct: nil))
        let model = PaywallModel(store: store)

        XCTAssertFalse(model.isStoreUnavailable, "not yet asked is not the same as unavailable")

        await model.loadProduct()
        XCTAssertTrue(model.isStoreUnavailable)
        XCTAssertFalse(model.isPurchaseAvailable,
                       "no product means no Buy button — the view renders the honest state instead")
        XCTAssertEqual(model.displayPrice, PaywallModel.placeholderPrice)
    }

    /// A failed load never blanks a price already obtained: the store being
    /// unreachable now does not make the figure it gave a minute ago wrong.
    func testAFailedReloadKeepsTheKnownPrice() async {
        let store = makeStore(source: FakeSource(
            current: [],
            storeProduct: StoreProduct(displayPrice: "$24.99", displayName: "Platterhead DJ")))
        let model = PaywallModel(store: store)
        await model.loadProduct()
        XCTAssertEqual(model.displayPrice, "$24.99")

        // The same store, now unable to answer (offline).
        let offline = makeStore(source: FakeSource(current: [], storeProduct: nil))
        let offlineModel = PaywallModel(store: offline)
        await offlineModel.loadProduct()
        XCTAssertEqual(offlineModel.displayPrice, PaywallModel.placeholderPrice,
                       "…but one that never had a price shows none, rather than a guess")
    }

    /// FR-STORE-3: a restore that finds nothing has to say so. Silence is
    /// indistinguishable from a broken button, and the user's next move is to
    /// buy something they may already own.
    func testARestoreThatFindsNothingSaysSo() async {
        let store = makeStore(source: FakeSource(current: [], grantOnRestore: false))
        let model = PaywallModel(store: store)
        await model.restore()

        XCTAssertFalse(model.isPro)
        XCTAssertEqual(model.lastError, "No previous purchase was found on this Apple Account.")
        XCTAssertFalse(model.isRestoring, "the flag clears however the restore ended")
    }

    func testASuccessfulRestoreUnlocksAndSaysNothingAlarming() async {
        let store = makeStore(source: FakeSource(current: [], grantOnRestore: true))
        let model = PaywallModel(store: store)
        model.present()
        await model.restore()

        XCTAssertTrue(model.isPro)
        XCTAssertNil(model.lastError)
        XCTAssertFalse(model.isPresented, "the sheet gets out of the way once there is nothing to sell")
    }
}

/// A StoreKit stand-in for the paywall seam. A struct (the original pattern),
/// so it stays `Sendable` under Swift 6: the grant fact the real StoreKit would
/// report after a successful purchase is *part of the read* when the scripted
/// purchase/restore path succeeds — a purchase that "succeeds" always surfaces
/// the verified fact in `currentTransactions`, exactly as StoreKit does.
private struct FakeSource: EntitlementSource {
    let current: [TransactionFact]
    let grantOnPurchase: Bool
    let grantOnRestore: Bool
    /// What the App Store answers when asked for the product. `nil` is the
    /// unconfigured / unapproved / offline case, which the paywall has to
    /// render as an honest "not available" rather than a made-up price.
    let storeProduct: StoreProduct?

    init(current: [TransactionFact], grantOnPurchase: Bool = false, grantOnRestore: Bool = false,
         storeProduct: StoreProduct? = StoreProduct(displayPrice: "£34.99",
                                                    displayName: "Platterhead DJ")) {
        self.current = current
        self.grantOnPurchase = grantOnPurchase
        self.grantOnRestore = grantOnRestore
        self.storeProduct = storeProduct
    }

    func loadProduct() async -> StoreProduct? { storeProduct }

    func currentTransactions() async throws -> [TransactionFact] {
        if grantOnPurchase || grantOnRestore {
            if current.contains(where: { $0.productID == FoundersGrant.productID && $0.isVerified }) {
                return current
            }
            return current + [grant]
        }
        return current
    }

    func transactionUpdates() -> AsyncStream<TransactionFact> { AsyncStream { _ in } }
    func purchase() async -> Bool { grantOnPurchase }
    func restore() async {}

    private var grant: TransactionFact {
        TransactionFact(productID: FoundersGrant.productID,
                        isVerified: true,
                        isRevoked: false,
                        isFamilyShared: false)
    }
}
