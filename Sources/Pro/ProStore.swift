import Foundation
import StoreKit

/// The StoreKit 2 purchase/restore/observe surface for Tonearm Pro. This file and
/// `ProPaywallView` are the ONLY places `import StoreKit` is permitted; a CI grep
/// guard (T3.2) enforces the boundary. All verification funnels through here into
/// the evidence-gated `ProEntitlement`.
@MainActor
final class ProStore: ObservableObject {
    static let shared = ProStore()

    @Published private(set) var isPro: Bool = ProEntitlement.isActive
    @Published private(set) var product: Product?
    @Published private(set) var purchasing = false

    private var updatesTask: Task<Void, Never>?

    private init() {}

    /// Begins observing transaction updates and refreshes current entitlements.
    /// Call once at launch.
    func start() {
        updatesTask?.cancel()
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(verification: update)
            }
        }
        Task { await refreshEntitlements() }
        Task { await loadProduct() }
    }

    func loadProduct() async {
        product = try? await Product.products(for: [ProEntitlement.productID]).first
    }

    /// Re-checks `Transaction.currentEntitlements` and syncs the cached flag.
    func refreshEntitlements() async {
        var found = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == ProEntitlement.productID,
               transaction.revocationDate == nil {
                let entitlement = ProEntitlement.verified(
                    transactionID: transaction.originalID,
                    purchaseDate: transaction.originalPurchaseDate)
                ProEntitlement.persist(entitlement)
                found = true
            }
        }
        if !found { ProEntitlement.clear() }
        isPro = ProEntitlement.isActive
    }

    /// Initiates a purchase of Tonearm Pro. Returns true on verified success.
    @discardableResult
    func purchase() async -> Bool {
        var resolved = product
        if resolved == nil {
            resolved = try? await Product.products(for: [ProEntitlement.productID]).first
        }
        guard let product = resolved else { return false }
        purchasing = true
        defer { purchasing = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                return await handle(verification: verification, finish: true)
            case .userCancelled, .pending:
                return false
            @unknown default:
                return false
            }
        } catch {
            return false
        }
    }

    /// Restores prior purchases (App Store account sync), then refreshes.
    func restore() async {
        try? await AppStore.sync()
        await refreshEntitlements()
    }

    // MARK: - Verification

    @discardableResult
    private func handle(verification: VerificationResult<Transaction>, finish: Bool = true) async -> Bool {
        guard case .verified(let transaction) = verification,
              transaction.productID == ProEntitlement.productID else {
            return false
        }
        if transaction.revocationDate != nil {
            ProEntitlement.clear()
            isPro = false
            if finish { await transaction.finish() }
            return false
        }
        let entitlement = ProEntitlement.verified(
            transactionID: transaction.originalID,
            purchaseDate: transaction.originalPurchaseDate)
        ProEntitlement.persist(entitlement)
        isPro = true
        if finish { await transaction.finish() }
        return true
    }

    /// Formatted one-time price for display, falling back to the mockup price.
    var displayPrice: String {
        product?.displayPrice ?? "$19.99"
    }
}
