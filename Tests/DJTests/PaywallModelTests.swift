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

    // §41.16: the one-time price is pinned to Resources/Tonearm.storekit's
    // single product ($39.99).
    func testDisplayPriceIsPinned() {
        XCTAssertEqual(PaywallModel.displayPrice, "$39.99")
        XCTAssertEqual(PaywallModel(store: makeStore(isPro: false)).displayPrice, "$39.99")
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

    init(current: [TransactionFact], grantOnPurchase: Bool = false, grantOnRestore: Bool = false) {
        self.current = current
        self.grantOnPurchase = grantOnPurchase
        self.grantOnRestore = grantOnRestore
    }

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
