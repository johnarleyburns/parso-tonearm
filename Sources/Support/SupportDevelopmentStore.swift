import Foundation
import StoreKit

/// Result of asking the App Store for the contribution product. Speaks in the store's own
/// vocabulary so feature UI and tests never touch StoreKit types.
public enum SupportProductLookup: Equatable, Sendable {
    /// The App Store returned a product with this ID and localized price.
    case found(productID: String, displayPrice: String)
    /// The lookup succeeded but the App Store has no such product for this build/storefront.
    case productNotFound
    /// StoreKit/network failure; `diagnostic` keeps the underlying error context.
    case failed(diagnostic: String)
}

/// Outcome of a purchase attempt.
public enum SupportPurchaseOutcome: Equatable, Sendable {
    /// A verified transaction for the contribution product, already finished.
    case success(productID: String)
    case cancelled
    case pending
    case unverified
    case productNotFound
    case failed(diagnostic: String)
}

public enum SupportLoadState: Equatable, Sendable {
    case notLoaded
    case ready
    case unavailable
    case failed(diagnostic: String)
}

/// Injection seam for tests. StoreKit's `Product`/`Transaction` have no public initializer
/// outside Apple's simulator-only `StoreKitTest` framework.
public protocol SupportDevelopmentPurchasing: Sendable {
    func loadProduct() async -> SupportProductLookup
    func purchase() async -> SupportPurchaseOutcome
}

/// The real StoreKit-backed implementation. Kept in this same file so the StoreKit import
/// boundary guard (`scripts/check-ci-guards.sh`) still only ever sees `import StoreKit` here.
public struct LiveSupportDevelopmentPurchasing: SupportDevelopmentPurchasing {
    public init() {}

    static func diagnostic(_ error: Error) -> String {
        let ns = error as NSError
        return "\(error.localizedDescription) (\(ns.domain) \(ns.code))"
    }

    public func loadProduct() async -> SupportProductLookup {
        do {
            let products = try await Product.products(for: [SupportDevelopmentStore.productID])
            guard let product = products.first(where: { $0.id == SupportDevelopmentStore.productID }) else {
                return .productNotFound
            }
            return .found(productID: product.id, displayPrice: product.displayPrice)
        } catch {
            return .failed(diagnostic: Self.diagnostic(error))
        }
    }

    public func purchase() async -> SupportPurchaseOutcome {
        let product: Product
        do {
            let products = try await Product.products(for: [SupportDevelopmentStore.productID])
            guard let found = products.first(where: { $0.id == SupportDevelopmentStore.productID }) else {
                return .productNotFound
            }
            product = found
        } catch {
            return .failed(diagnostic: Self.diagnostic(error))
        }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else { return .unverified }
                guard transaction.productID == SupportDevelopmentStore.productID else {
                    // Not our product — finish it so it does not linger, but it earns nothing.
                    await transaction.finish()
                    return .failed(diagnostic: "Unexpected product \(transaction.productID)")
                }
                // Consumables must be finished for StoreKit to consider them delivered.
                await transaction.finish()
                return .success(productID: transaction.productID)
            case .userCancelled:
                return .cancelled
            case .pending:
                return .pending
            @unknown default:
                return .failed(diagnostic: "Unknown purchase result")
            }
        } catch {
            return .failed(diagnostic: Self.diagnostic(error))
        }
    }
}

/// Business decision (2026-09): Tonearm has no gated Pro features (see
/// `current_status.md`). The only purchase left is this one, purely optional,
/// one-time StoreKit **consumable** — "Contribute to Development". A
/// successful purchase does not unlock anything; it only flips the permanent
/// `isSupporter` flag that the home view's badge reads.
///
/// This file lives in `Sources/Support/` because it is the one place the
/// StoreKit import boundary (`scripts/check-ci-guards.sh`'s "StoreKit import
/// boundary" guard) permits `import StoreKit` — there is no longer a Pro
/// entitlement/paywall to carve a second exception for.
@MainActor
public final class SupportDevelopmentStore: ObservableObject {
    public static let shared = SupportDevelopmentStore()

    /// The one-time consumable. Consumables never appear in
    /// `Transaction.currentEntitlements` — StoreKit forgets them once the
    /// transaction is finished — so unlike a non-consumable entitlement there
    /// is nothing to re-derive from at launch. The persisted flag below is the
    /// only record that the purchase happened, and it is never reset: a
    /// refund does not "revoke" it, because it never unlocked anything to
    /// revoke (business decision above).
    /// `nonisolated` — a plain constant string, but `LiveSupportDevelopmentPurchasing`
    /// (deliberately not `@MainActor`, since it must satisfy a plain `Sendable` async protocol)
    /// reads it from outside this class's actor isolation.
    public nonisolated static let productID = "guru.parso.tonearm.support.dev"

    private static let supporterDefaultsKey = "supporter.isSupporter"

    /// Whether this Apple Account has ever completed the contribution. Read
    /// once at init from `UserDefaults`, offline-forever — and only ever set,
    /// never cleared.
    @Published public private(set) var isSupporter: Bool

    @Published public private(set) var purchasing = false
    @Published public private(set) var didAttemptProductLoad = false
    @Published public private(set) var loadState: SupportLoadState = .notLoaded
    @Published public private(set) var lastPurchaseOutcome: SupportPurchaseOutcome?
    /// What the App Store says this product costs, once asked, or nil while unanswered/
    /// unavailable. Never a hardcoded price — see `displayPrice`'s own doc.
    @Published private var loadedDisplayPrice: String?

    private let defaults: UserDefaults
    private let purchasing_: SupportDevelopmentPurchasing
    private var updatesTask: Task<Void, Never>?

    public init(defaults: UserDefaults = .standard,
                purchasing: SupportDevelopmentPurchasing = LiveSupportDevelopmentPurchasing()) {
        self.defaults = defaults
        self.purchasing_ = purchasing
        isSupporter = defaults.bool(forKey: Self.supporterDefaultsKey)
    }

    /// Begins observing `Transaction.updates` (a consumable purchased on
    /// another device under the same Apple Account can still arrive here) and
    /// loads the product. Call once at launch.
    public func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
        Task { [weak self] in await self?.loadProduct() }
    }

    /// Ask the App Store what this product is and costs, right now. Safe to
    /// call repeatedly — the settings row calls it on appear.
    public func loadProduct() async {
        let lookup = await purchasing_.loadProduct()
        switch lookup {
        case .found(let id, let price) where id == Self.productID:
            loadedDisplayPrice = price
            loadState = .ready
        case .found:
            // Any other product ID is never purchasable here.
            loadedDisplayPrice = nil
            loadState = .unavailable
        case .productNotFound:
            loadedDisplayPrice = nil
            loadState = .unavailable
        case .failed(let diagnostic):
            loadedDisplayPrice = nil
            loadState = .failed(diagnostic: diagnostic)
        }
        didAttemptProductLoad = true
    }

    /// StoreKit's own localised price, or an honest placeholder until it
    /// answers — never a hardcoded price.
    public var displayPrice: String { loadedDisplayPrice ?? "—" }

    /// Whether the App Store is actually offering the product right now.
    public var isPurchaseAvailable: Bool { loadedDisplayPrice != nil }

    /// A specific, user-facing reason the contribution can't be offered, distinguishing a
    /// missing product from a StoreKit/network failure. `nil` while loading or when ready.
    public var unavailableReason: String? { Self.unavailableReason(for: loadState) }

    nonisolated static func unavailableReason(for state: SupportLoadState) -> String? {
        switch state {
        case .notLoaded, .ready:
            return nil
        case .unavailable:
            return String(localized: "The contribution isn't available from the App Store right now.")
        case .failed:
            return String(localized: "The App Store couldn't load the contribution. Tap to try again.")
        }
    }

    /// Diagnostic text of the last StoreKit failure (lookup or purchase), for diagnosis.
    public var lastDiagnostic: String? {
        if case .failed(let d) = loadState { return d }
        if case .failed(let d) = lastPurchaseOutcome { return d }
        return nil
    }

    /// Initiates the one-time, optional purchase. Returns whether it was verified. Never gates
    /// anything on the result. Ignored while a purchase is already in flight, or when the
    /// product is not the one this build offers.
    @discardableResult
    public func purchase() async -> Bool {
        guard !purchasing else { return false }
        purchasing = true
        defer { purchasing = false }
        let outcome = await purchasing_.purchase()
        lastPurchaseOutcome = outcome
        if case .success(let id) = outcome, id == Self.productID {
            markSupporter()
            return true
        }
        return false
    }

    /// User-facing message for the last non-success purchase outcome, if any.
    public var purchaseErrorMessage: String? {
        switch lastPurchaseOutcome {
        case .none, .success, .cancelled:
            return nil
        case .pending:
            return String(localized: "Your contribution is pending approval.")
        case .unverified:
            return String(localized: "The App Store couldn't verify the purchase. Nothing was unlocked.")
        case .productNotFound:
            return String(localized: "The contribution isn't available from the App Store right now.")
        case .failed:
            return String(localized: "The contribution did not complete. Please try again.")
        }
    }

    // MARK: - Verification

    @discardableResult
    private func handle(_ verification: VerificationResult<Transaction>) async -> Bool {
        guard case .verified(let transaction) = verification else { return false }
        guard transaction.productID == Self.productID else {
            // Not our product — finish it anyway so it does not linger as an
            // unfinished transaction forever, but this call did not earn it.
            await transaction.finish()
            return false
        }
        markSupporter()
        // Consumables must be finished for StoreKit to consider them
        // delivered; unlike the Pro non-consumable, there is no entitlement
        // for a re-launch to re-derive, so finishing is the only step here.
        await transaction.finish()
        return true
    }

    /// Sets the persisted flag. Idempotent, and — per the business decision —
    /// there is no code path that ever clears it.
    private func markSupporter() {
        guard !isSupporter else { return }
        isSupporter = true
        defaults.set(true, forKey: Self.supporterDefaultsKey)
    }
}
