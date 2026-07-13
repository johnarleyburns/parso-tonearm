import Foundation

/// Evidence-gated entitlement: an instance can only be constructed from a
/// StoreKit-verified transaction (D8). There are no scattered "isPro" booleans;
/// possessing a `ProEntitlement` *is* the proof of purchase.
///
/// The verified result is mirrored into UserDefaults so the app keeps Pro while
/// offline (airplane mode). `ProStore` refreshes it from `Transaction`.
struct ProEntitlement: Equatable {
    /// The verified original transaction id. Set only by verified construction.
    let transactionID: UInt64
    let purchaseDate: Date

    /// Private init — the only constructor is the verification factory below, so
    /// an entitlement cannot be forged from arbitrary state.
    private init(transactionID: UInt64, purchaseDate: Date) {
        self.transactionID = transactionID
        self.purchaseDate = purchaseDate
    }

    static let productID = "guru.parso.tonearm.pro"

    // MARK: - Persistence keys

    private static let activeKey = "pro.entitlement.active"
    private static let txIDKey = "pro.entitlement.txid"
    private static let dateKey = "pro.entitlement.date"

    // MARK: - Verified construction

    /// Builds an entitlement from a StoreKit-verified transaction's fields. This
    /// is intentionally the *only* way (besides the persisted cache) to obtain an
    /// instance; `ProStore` calls it after checking `VerificationResult`.
    static func verified(transactionID: UInt64, purchaseDate: Date) -> ProEntitlement {
        ProEntitlement(transactionID: transactionID, purchaseDate: purchaseDate)
    }

    // MARK: - Cached read (offline-friendly)

    /// Whether the persisted verification cache marks Pro active. Reading this is
    /// how gates stay unlocked across launches and in airplane mode.
    static var isActive: Bool {
        UserDefaults.standard.bool(forKey: activeKey)
    }

    /// The cached entitlement, if active.
    static var current: ProEntitlement? {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: activeKey) else { return nil }
        let txID = UInt64(defaults.string(forKey: txIDKey) ?? "") ?? 0
        let date = defaults.object(forKey: dateKey) as? Date ?? Date(timeIntervalSince1970: 0)
        return ProEntitlement(transactionID: txID, purchaseDate: date)
    }

    /// Persists a verified entitlement so gates unlock across launches / offline.
    static func persist(_ entitlement: ProEntitlement) {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: activeKey)
        defaults.set(String(entitlement.transactionID), forKey: txIDKey)
        defaults.set(entitlement.purchaseDate, forKey: dateKey)
    }

    /// Clears the cached entitlement (revocation / refund / test teardown).
    static func clear() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: activeKey)
        defaults.removeObject(forKey: txIDKey)
        defaults.removeObject(forKey: dateKey)
    }
}
