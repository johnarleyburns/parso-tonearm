import Foundation
import Synchronization

/// §5.4 — "every event has a message ID stored in a bounded applied-message ledger".
///
/// Durable because WatchConnectivity redelivers: `transferUserInfo` survives relaunch on both
/// sides, so a `removeAssets` that was already applied can arrive again after the watch restarts,
/// and an in-memory set would let it through. Bounded because the ledger must not grow without
/// limit on a device with this little storage — the oldest entries age out once capacity is passed,
/// which is safe: a redelivery older than the last 512 applied events is not something WCSession
/// does.
public actor WatchAppliedMessageLedger {
    public enum Admission: Equatable, Sendable {
        /// First time this message has been seen; apply it.
        case apply
        /// Already applied. Acknowledge without reapplying (§5.4).
        case duplicate
    }

    public static let defaultCapacity = 512

    private let capacity: Int
    private let persistence: any WatchLedgerPersistence
    private var order: [UUID]
    private var seen: Set<UUID>

    public init(capacity: Int = WatchAppliedMessageLedger.defaultCapacity,
                persistence: any WatchLedgerPersistence = WatchInMemoryLedgerPersistence()) {
        self.capacity = max(1, capacity)
        self.persistence = persistence
        let loaded = persistence.load().suffix(max(1, capacity))
        order = loaded.map(\.messageID)
        seen = Set(order)
    }

    @discardableResult
    public func admit(_ messageID: UUID, at date: Date = Date()) -> Admission {
        guard !seen.contains(messageID) else { return .duplicate }
        seen.insert(messageID)
        order.append(messageID)
        var records = persistence.load()
        records.append(WatchLedgerRecord(messageID: messageID, appliedAt: date))
        if order.count > capacity {
            let evicted = order.removeFirst()
            seen.remove(evicted)
        }
        if records.count > capacity { records.removeFirst(records.count - capacity) }
        persistence.save(records)
        return .apply
    }

    public func contains(_ messageID: UUID) -> Bool { seen.contains(messageID) }
    public var count: Int { order.count }

    public func reset() {
        order.removeAll()
        seen.removeAll()
        persistence.save([])
    }
}

public struct WatchLedgerRecord: Codable, Equatable, Sendable {
    public var messageID: UUID
    public var appliedAt: Date

    public init(messageID: UUID, appliedAt: Date) {
        self.messageID = messageID
        self.appliedAt = appliedAt
    }
}

/// The ledger's storage seam. Synchronous by design: the ledger is already an actor, and a second
/// layer of `await` here would let two admissions of the same ID interleave.
public protocol WatchLedgerPersistence: Sendable {
    func load() -> [WatchLedgerRecord]
    func save(_ records: [WatchLedgerRecord])
}

/// Tests and previews. Deliberately not the default for shipping code — see `WatchFileLedgerPersistence`.
/// Uses `Mutex` rather than `@unchecked Sendable` over an `NSLock`, so the compiler still checks the
/// concurrency claim instead of taking our word for it.
public final class WatchInMemoryLedgerPersistence: WatchLedgerPersistence, Sendable {
    private let storage: Mutex<[WatchLedgerRecord]>

    public init(records: [WatchLedgerRecord] = []) { storage = Mutex(records) }

    public func load() -> [WatchLedgerRecord] { storage.withLock { $0 } }
    public func save(_ records: [WatchLedgerRecord]) { storage.withLock { $0 = records } }
}

/// A JSON file written atomically. Not SwiftData: the ledger has to be readable before the store is
/// open, because `storeRecovered` is itself an event whose delivery must not be applied twice.
public struct WatchFileLedgerPersistence: WatchLedgerPersistence {
    private let url: URL

    public init(url: URL) { self.url = url }

    public func load() -> [WatchLedgerRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([WatchLedgerRecord].self, from: data)) ?? []
    }

    public func save(_ records: [WatchLedgerRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// §5.4's revision rule, separated from the message ledger because they answer different questions:
/// the ledger asks "have I applied this *message*", the gate asks "is this *state* newer than what I
/// already have". A redelivered message is a duplicate; a resent-but-older snapshot is stale. Both
/// are acknowledged, neither is applied, and conflating them is how a retry ends up rolling state
/// backward (C-07).
public struct WatchRevisionGate: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        case apply
        /// Acknowledge without applying — the peer is behind, or repeating itself.
        case staleIgnored
    }

    private var applied: [String: Int64]

    public init(applied: [String: Int64] = [:]) { self.applied = applied }

    /// `scope` separates independently-revisioned streams — catalog, download roots, playback — so a
    /// high playback revision cannot suppress a legitimately lower download-root revision.
    public mutating func evaluate(scope: WatchRevisionScope, revision: Int64) -> Decision {
        let key = scope.rawValue
        guard let current = applied[key] else {
            applied[key] = revision
            return .apply
        }
        guard revision > current else { return .staleIgnored }
        applied[key] = revision
        return .apply
    }

    public func lastApplied(_ scope: WatchRevisionScope) -> Int64 { applied[scope.rawValue] ?? 0 }

    public mutating func reset(_ scope: WatchRevisionScope) { applied[scope.rawValue] = nil }
    public mutating func resetAll() { applied.removeAll() }
}

public enum WatchRevisionScope: String, Codable, Sendable, CaseIterable {
    case catalog, downloadRoots, playback, downloadStatus, manifest
}
