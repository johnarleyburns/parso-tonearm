import Foundation

public enum WatchTransferOrigin: String, Equatable, Codable {
    case single
    case album
    case playlist
}

public enum WatchTransferState: String, Equatable, Codable {
    case queued
    case sending
    case sent
    case failed
}

public struct WatchTransferItem: Equatable, Codable {
    public var trackKey: String
    public var state: WatchTransferState
    public var originKind: WatchTransferOrigin
    public var originId: Int64?
    public var bytes: Int64?
    public var errorText: String?
    public var queuedAt: Date
    public var updatedAt: Date

    public init(trackKey: String, state: WatchTransferState = .queued,
                originKind: WatchTransferOrigin = .single,
                originId: Int64? = nil, bytes: Int64? = nil,
                errorText: String? = nil, queuedAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.trackKey = trackKey
        self.state = state
        self.originKind = originKind
        self.originId = originId
        self.bytes = bytes
        self.errorText = errorText
        self.queuedAt = queuedAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Transfer Planner

public struct WatchTransferEnqueue: Equatable {
    public var key: String
    public var origin: WatchTransferOrigin
    public var originId: Int64?

    public init(key: String, origin: WatchTransferOrigin = .single, originId: Int64? = nil) {
        self.key = key
        self.origin = origin
        self.originId = originId
    }
}

public enum WatchTransferPlanner {
    public struct Plan: Equatable {
        public var toEnqueue: [WatchTransferEnqueue]
        public var toRetry: [String]
        public var toCancel: [String]

        public init(toEnqueue: [WatchTransferEnqueue] = [],
                    toRetry: [String] = [],
                    toCancel: [String] = []) {
            self.toEnqueue = toEnqueue
            self.toRetry = toRetry
            self.toCancel = toCancel
        }
    }

    /// Compute a diff plan given desired keys, watch manifest, and current transfer state.
    public static func plan(desiredKeys: Set<String>,
                            manifestOnWatch: Set<String>,
                            currentItems: [WatchTransferItem],
                            isTransferable: (String) -> Bool = { _ in true }) -> Plan {
        var toEnqueue: [WatchTransferEnqueue] = []
        var toRetry: [String] = []
        var toCancel: [String] = []

        let currentKeys = Set(currentItems.map(\.trackKey))
        let retired = currentItems.filter { $0.state == .failed && $0.errorText != nil }
        let activeStates: Set<WatchTransferState> = [.queued, .sending]

        for key in desiredKeys {
            // Skip if already on watch and not in a retry state
            if manifestOnWatch.contains(key) && !retired.contains(where: { $0.trackKey == key }) {
                // still need to cancel any stale in-flight
                continue
            }
            // Skip if not transferable (no local asset, needsReimport, etc.)
            guard isTransferable(key) else { continue }
            // Skip if already queued or sending
            if currentItems.contains(where: { $0.trackKey == key && activeStates.contains($0.state) }) {
                continue
            }
            // Failed items → retry only if there was an error
            if let failedItem = currentItems.first(where: { $0.trackKey == key && $0.state == .failed }) {
                if failedItem.errorText != nil {
                    toRetry.append(key)
                }
                continue
            }
            // Already sent but not in manifest? Re-enqueue (unlikely, but safe).
            if currentItems.contains(where: { $0.trackKey == key && $0.state == .sent }) {
                continue
            }
            // Not in queue at all → enqueue
            toEnqueue.append(WatchTransferEnqueue(key: key, origin: .single, originId: nil))
        }

        // Cancel items that are in active states but no longer desired
        for item in currentItems where activeStates.contains(item.state) && !desiredKeys.contains(item.trackKey) {
            toCancel.append(item.trackKey)
        }

        // Deduplicate: if key appears in both toEnqueue and toRetry, prefer retry
        let retrySet = Set(toRetry)
        toEnqueue = toEnqueue.filter { !retrySet.contains($0.key) }

        return Plan(toEnqueue: toEnqueue, toRetry: toRetry, toCancel: toCancel)
    }
}

// MARK: - Transfer Queue

public struct WatchTransferQueue: Equatable {
    public enum QueueState: Equatable {
        case idle
        case running
        case paused
    }

    public private(set) var state: QueueState
    public private(set) var items: [WatchTransferItem]
    public let maxInFlight: Int

    public init(items: [WatchTransferItem] = [], maxInFlight: Int = 2) {
        self.state = .idle
        self.items = items
        self.maxInFlight = maxInFlight
    }

    public var inFlightCount: Int {
        items.filter { $0.state == .sending }.count
    }

    public var inFlightKeys: [String] {
        items.filter { $0.state == .sending }.map(\.trackKey)
    }

    // MARK: - Mutations

    @discardableResult
    public mutating func enqueue(key: String, originKind: WatchTransferOrigin = .single,
                                  originId: Int64? = nil) -> Bool {
        guard !items.contains(where: { $0.trackKey == key }) else { return false }
        let item = WatchTransferItem(trackKey: key, state: .queued,
                                      originKind: originKind, originId: originId)
        items.append(item)
        return true
    }

    public mutating func start() {
        state = .running
    }

    public mutating func pause() {
        if state == .running { state = .paused }
    }

    public mutating func resume() {
        if state == .paused { state = .running }
    }

    public mutating func markSending(key: String) -> Bool {
        guard state == .running else { return false }
        guard inFlightCount < maxInFlight else { return false }
        guard let idx = items.firstIndex(where: { $0.trackKey == key && $0.state == .queued }) else { return false }
        items[idx].state = .sending
        items[idx].updatedAt = Date()
        return true
    }

    @discardableResult
    public mutating func markSent(key: String, bytes: Int64) -> Bool {
        guard let idx = items.firstIndex(where: { $0.trackKey == key && $0.state == .sending }) else { return false }
        items[idx].state = .sent
        items[idx].bytes = bytes
        items[idx].updatedAt = Date()
        items[idx].errorText = nil
        return true
    }

    @discardableResult
    public mutating func markFailed(key: String, error: String) -> Bool {
        guard let idx = items.firstIndex(where: {
            $0.trackKey == key && ($0.state == .sending || $0.state == .queued)
        }) else { return false }
        items[idx].state = .failed
        items[idx].errorText = error
        items[idx].updatedAt = Date()
        return true
    }

    @discardableResult
    public mutating func retry(key: String) -> Bool {
        guard let idx = items.firstIndex(where: { $0.trackKey == key && $0.state == .failed }) else { return false }
        items[idx].state = .queued
        items[idx].errorText = nil
        items[idx].updatedAt = Date()
        return true
    }

    @discardableResult
    public mutating func cancel(key: String) -> Bool {
        guard let idx = items.firstIndex(where: { $0.trackKey == key }) else { return false }
        // Only cancel non-sent items
        guard items[idx].state != .sent else { return false }
        items.remove(at: idx)
        return true
    }

    public mutating func cancelAllSending() {
        items.removeAll { $0.state == .sending }
    }

    public mutating func cancelAllActive() {
        items.removeAll { $0.state != .sent }
        state = .idle
    }

    /// Next items ready to be picked up by the adapter.
    public func nextCandidates() -> [String] {
        guard state == .running else { return [] }
        let available = max(0, maxInFlight - inFlightCount)
        return items
            .filter { $0.state == .queued }
            .prefix(available)
            .map(\.trackKey)
    }

    /// Progress of currently queued+sending items.
    public var activeCount: Int {
        items.filter { $0.state == .queued || $0.state == .sending }.count
    }

    /// Track keys in queued state.
    public var queuedKeys: [String] {
        items.filter { $0.state == .queued }.map(\.trackKey)
    }

    /// Track keys in failed state.
    public var failedKeys: [String] {
        items.filter { $0.state == .failed }.map(\.trackKey)
    }

    /// Track keys in sent state.
    public var sentKeys: [String] {
        items.filter { $0.state == .sent }.map(\.trackKey)
    }
}
