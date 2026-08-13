import Combine
import Foundation
import StoreKit

/// A normalized, non-identifying fact about a StoreKit transaction. It carries
/// no user identifier, no receipt, and no device ID (T.2 rule 5, FR-STORE-7,
/// §45.5) — only what the grant decision needs.
public struct TransactionFact: Equatable, Sendable {
    public let productID: String
    /// `true` when StoreKit's `VerificationResult` was `.verified`.
    public let isVerified: Bool
    /// `true` when the transaction has a revocation date (a refund).
    public let isRevoked: Bool
    /// `true` when the transaction came through Family Sharing.
    public let isFamilyShared: Bool

    public init(productID: String, isVerified: Bool, isRevoked: Bool, isFamilyShared: Bool) {
        self.productID = productID
        self.isVerified = isVerified
        self.isRevoked = isRevoked
        self.isFamilyShared = isFamilyShared
    }
}

/// The StoreKit boundary (T.2 rule 1), abstracted so the entitlement logic is
/// unit-testable without a live StoreKit configuration. The production
/// implementation reads `Transaction.currentEntitlements`, observes
/// `Transaction.updates`, and runs the purchase/restore flow; tests inject a
/// fake. `purchase()`/`restore()` default to no-ops so the read-only fakes in
/// other test suites do not need to grow.
protocol EntitlementSource: Sendable {
    func currentTransactions() async throws -> [TransactionFact]
    func transactionUpdates() -> AsyncStream<TransactionFact>
    /// Initiates the one-time purchase. Returns `true` only on a verified
    /// success; the fact then appears in `currentTransactions` (AT-STORE-2).
    func purchase() async -> Bool
    /// App Store account sync — the restore flow (FR-STORE-3).
    func restore() async
}

extension EntitlementSource {
    func purchase() async -> Bool { false }
    func restore() async {}
}

/// StoreKit 2-backed source. Verification is `Transaction.currentEntitlements`
/// with StoreKit's automatic `VerificationResult` checking — no receipt
/// parsing, no server validation, no third-party SDK (T.2 rule 1).
struct StoreKitEntitlementSource: EntitlementSource {
    func currentTransactions() async throws -> [TransactionFact] {
        var facts: [TransactionFact] = []
        for await result in Transaction.currentEntitlements {
            facts.append(TransactionFact(result))
        }
        return facts
    }

    func transactionUpdates() -> AsyncStream<TransactionFact> {
        AsyncStream { continuation in
            let task = Task {
                for await result in Transaction.updates {
                    continuation.yield(TransactionFact(result))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The one-time purchase of `guru.parso.tonearm.pro` (FR-STORE-1). On
    /// success the transaction appears in `currentEntitlements`, which
    /// `EntitlementStore.purchase()` re-reads — the flip needs no relaunch
    /// (AT-STORE-2).
    func purchase() async -> Bool {
        guard let product = try? await Product.products(for: [FoundersGrant.productID]).first else {
            return false
        }
        do {
            switch try await product.purchase() {
            case .success:
                return true
            case .userCancelled, .pending:
                return false
            @unknown default:
                return false
            }
        } catch {
            return false
        }
    }

    /// App Store account sync so a purchase on another device (or an earlier
    /// install) restores without an account or a support ticket (FR-STORE-3).
    func restore() async {
        try? await AppStore.sync()
    }
}

private extension TransactionFact {
    init(_ result: VerificationResult<Transaction>) {
        switch result {
        case .verified(let transaction):
            self.init(productID: transaction.productID,
                      isVerified: true,
                      isRevoked: transaction.revocationDate != nil,
                      isFamilyShared: transaction.ownershipType == .familyShared)
        case .unverified(let transaction, _):
            self.init(productID: transaction.productID,
                      isVerified: false,
                      isRevoked: transaction.revocationDate != nil,
                      isFamilyShared: transaction.ownershipType == .familyShared)
        }
    }
}

/// The offline-forever cache (T.2 rules 2, 3, 5). A boolean, a source enum,
/// and a timestamp — nothing that could identify a purchaser. Read at launch
/// *before* any StoreKit call; a failed StoreKit call never revokes it.
struct EntitlementCache: Codable, Equatable, Sendable {
    var isPro: Bool
    var source: EntitlementStore.Source
    var timestamp: Date
}

/// Small file in Application Support, written atomically so a torn write never
/// destroys the last-known-good entitlement (mirrors `PlaybackStateFileStore`).
struct EntitlementCacheStore: Sendable {
    private static let directory = "Tonearm"
    private static let filename = "entitlement-cache.json"

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? EntitlementCacheStore.defaultFileURL()
    }

    private static func defaultFileURL() -> URL {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory,
                                   in: .userDomainMask,
                                   appropriateFor: nil,
                                   create: true)) ?? fm.temporaryDirectory
        return support.appendingPathComponent(directory).appendingPathComponent(filename)
    }

    func load() -> EntitlementCache? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(EntitlementCache.self, from: data)
    }

    func save(_ cache: EntitlementCache) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = fileURL.appendingPathExtension("tmp")
        try? data.write(to: tmp)
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.moveItem(at: tmp, to: fileURL)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// The entitlement store (Appendix T.2, FR-STORE-1..7). Verifies
/// `Transaction.currentEntitlements`, caches the result offline forever,
/// observes `Transaction.updates` for the app's lifetime (started before the
/// first view appears), and runs the purchase/restore flow. The gate is
/// checked at intent boundaries (T.3), never inside the engine.
@MainActor
public final class EntitlementStore: ObservableObject {
    public static let shared = EntitlementStore()

    @Published public private(set) var isPro: Bool
    @Published public private(set) var source: Source

    public enum Source: String, Codable, Sendable {
        case none
        case purchased        // bought guru.parso.tonearm.pro
        case foundersGrant    // legacy cache row; the retired product no longer exists (M4 decision 1)
        case familyShared     // Family Sharing from another member's purchase
        case builtFromSource  // GPL build; see T.6
    }

    private let entitlementSource: any EntitlementSource
    private let cacheStore: EntitlementCacheStore
    private var updatesTask: Task<Void, Never>?

    public convenience init() {
        self.init(entitlementSource: StoreKitEntitlementSource(),
                  cacheStore: EntitlementCacheStore())
    }

    /// Test seam: inject a source and a cache file. Reads the cached value
    /// before any StoreKit call, exactly as launch does.
    init(entitlementSource: any EntitlementSource, cacheStore: EntitlementCacheStore) {
        self.entitlementSource = entitlementSource
        self.cacheStore = cacheStore
        // T.2 rule 2: the cached value wins offline — read it first, before
        // any StoreKit call.
        let cached = cacheStore.load()
        self.isPro = cached?.isPro ?? false
        self.source = cached?.source ?? .none
    }

    /// Begins observing `Transaction.updates` and refreshes current
    /// entitlements. Call once at launch, before the first view appears
    /// (T.2 rule 4) — a Family Sharing grant or an Ask-to-Buy approval arriving
    /// mid-session flips `isPro` immediately (AT-STORE-2).
    public func start() {
        guard updatesTask == nil else { return }
        let updates = entitlementSource.transactionUpdates()
        updatesTask = Task { [weak self] in
            for await fact in updates {
                await self?.handle(fact)
            }
        }
        Task { [weak self] in await self?.refresh() }
    }

    /// Re-checks `Transaction.currentEntitlements` and re-derives the grant.
    /// A failed StoreKit call never revokes — the cached value stands
    /// (T.2 rule 3).
    public func refresh() async {
        do {
            let facts = try await entitlementSource.currentTransactions()
            apply(facts)
        } catch {
            // T.2 rule 3: verification errors never revoke the cache.
        }
    }

    /// Initiates the one-time purchase of `guru.parso.tonearm.pro`
    /// (FR-STORE-1). A verified success re-derives the grant from
    /// `currentEntitlements`, so `isPro` flips immediately — **no relaunch**
    /// (AT-STORE-2). Returns whether the purchase was verified.
    @discardableResult
    public func purchase() async -> Bool {
        let ok = await entitlementSource.purchase()
        if ok { await refresh() }
        return ok
    }

    /// Restores prior purchases via the App Store account, then re-derives the
    /// grant (FR-STORE-3). The paywall's Restore button calls this.
    public func restore() async {
        await entitlementSource.restore()
        await refresh()
    }

    // MARK: - Decision

    private func handle(_ fact: TransactionFact) async {
        if fact.isVerified && fact.isRevoked {
            // Explicit, verified revocation (a refund). Re-derive from the
            // surviving entitlements plus the revocation: a surviving
            // retired-product grant still grants; a sole revoked purchase
            // clears (T.2 rule 3, T.4 row 4).
            var facts = (try? await entitlementSource.currentTransactions()) ?? []
            facts.append(fact)
            apply(facts)
        } else {
            // A grant (or pending approval) arrived mid-session: re-scan so the
            // full entitlement set decides (AT-STORE-2).
            await refresh()
        }
    }

    func apply(_ facts: [TransactionFact]) {
        let ownership = FoundersGrant.ownership(from: facts)
        let outcome = FoundersGrant.outcome(for: ownership)
        switch outcome {
        case .none:
            // T.2 rule 3: only an explicit, verified revocation clears the
            // cache. An empty or unverified scan stands — it may just be
            // airplane mode or a StoreKit refresh delay.
            if facts.contains(where: { $0.isVerified && $0.isRevoked }) {
                setState(.none)
            }
        case .purchased:
            setState(.purchased)
        case .familyShared:
            setState(.familyShared)
        }
    }

    private func setState(_ newSource: Source) {
        let newIsPro = newSource != .none
        guard newIsPro != isPro || newSource != source else { return }
        isPro = newIsPro
        source = newSource
        if newIsPro {
            cacheStore.save(EntitlementCache(isPro: true, source: newSource, timestamp: Date()))
        } else {
            cacheStore.clear()
        }
    }
}
