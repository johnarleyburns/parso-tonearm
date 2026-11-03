import Foundation

/// Named owner of memory in the live-mix pipeline. Every heavy allocation is made under one.
public enum ResourceKind: String, Sendable, Equatable, CaseIterable {
    case liveDecode, blendPreparation, queuePreview, audition, resample, tempoRender
    case deckA, deckB, deckC, outgoingTail

    /// Work for a future transition; shed first under pressure. Audible playback is never "future".
    public var isFuturePreparation: Bool {
        switch self {
        case .deckA, .outgoingTail: return false
        default: return true
        }
    }
}

public enum ResourceDenialReason: String, Error, Sendable, Equatable {
    case absoluteCap, insufficientHeadroom, memoryPressure, availabilityUnknown, invalidRequest
}

public enum ResourceReservationState: String, Sendable, Equatable { case pending, resident, cancelling, released }

/// Typed, UI-ready view of one reservation.
public struct ResourceReservationInfo: Sendable, Equatable {
    public let id: UInt64
    public let kind: ResourceKind
    public let bytes: Int64
    public let state: ResourceReservationState
}

/// Typed state for later UI; pending and resident bytes are accounted separately.
public struct ResourceSnapshot: Sendable, Equatable {
    public var pendingBytes: Int64
    public var residentBytes: Int64
    public var reservations: [ResourceReservationInfo]
    public var lastDenial: ResourceDenialReason?
    public var totalBytes: Int64 { pendingBytes + residentBytes }
}

public struct ResourceCoordinatorConfig: Sendable, Equatable {
    /// Measured absolute ceiling on reserved bytes across all kinds; never raised to admit more media.
    public var absoluteCapBytes: Int64 = TransitionAdmissionConfig.standard.absoluteCapBytes
    public var safetyReserveBytes: Int64 = TransitionAdmissionConfig.standard.safetyReserveBytes
    public var requiredHeadroomBytes: Int64 = TransitionAdmissionConfig.standard.requiredHeadroomBytes
    /// Optional per-kind absolute caps.
    public var kindCapBytes: [ResourceKind: Int64] = [:]
    public init() {}
}

/// The one authority for heavy-work memory. A reservation is released only by `release()`, which
/// the worker calls after it has really exited and its buffers are releasable; `cancel()` only asks.
public final class ResourceCoordinator: @unchecked Sendable {
    public static let shared = ResourceCoordinator()

    /// Handle proving a live reservation. Decoders/planners must hold one before allocating.
    public final class Reservation: @unchecked Sendable {
        public let id: UInt64
        public let kind: ResourceKind
        public let bytes: Int64
        fileprivate let owner: ResourceCoordinator
        public init(id: UInt64, kind: ResourceKind, bytes: Int64, owner: ResourceCoordinator) {
            self.id = id; self.kind = kind; self.bytes = bytes; self.owner = owner
        }
        public var state: ResourceReservationState { owner.state(of: id) }
        public var isLive: Bool { state != .released }
        public var isCancellationRequested: Bool { owner.isCancelRequested(id) }
        /// Buffers now exist: moves the bytes from pending to resident.
        public func markResident() { owner.markResident(id) }
        /// Requests cancellation. Does NOT free the budget.
        public func cancel() { owner.requestCancel(id) }
        /// Call only once the worker has exited. Idempotent.
        public func release() { owner.release(id) }
        /// Instrumentation hook: call at the top of every allocating entry point.
        /// Rechecks fresh memory immediately before allocation.
        public func authorizeAllocation() -> Bool { owner.authorizeAllocation(id) }
    }

    private struct Entry {
        var kind: ResourceKind
        var bytes: Int64
        var state: ResourceReservationState
        var cancelRequested = false
    }

    private let lock = NSLock()
    private var entries: [UInt64: Entry] = [:]
    private var nextID: UInt64 = 1
    private var lastDenial: ResourceDenialReason?
    private let config: ResourceCoordinatorConfig
    /// Read fresh on every decision; never cached here.
    private let availableMemory: @Sendable () -> Int64?
    private let pressureActive: @Sendable () -> Bool

    public init(config: ResourceCoordinatorConfig = .init(),
                availableMemory: @escaping @Sendable () -> Int64? = { TransitionSystemState.current().availableBytes },
                pressureActive: @escaping @Sendable () -> Bool = { TransitionPressure.shared.isActive }) {
        self.config = config
        self.availableMemory = availableMemory
        self.pressureActive = pressureActive
    }

    public func reserve(_ kind: ResourceKind, bytes: Int64) -> Result<Reservation, ResourceDenialReason> {
        lock.lock(); defer { lock.unlock() }
        if let denial = check(kind: kind, bytes: bytes, excluding: nil) {
            lastDenial = denial
            return .failure(denial)
        }
        let id = nextID; nextID += 1
        entries[id] = Entry(kind: kind, bytes: bytes, state: .pending)
        return .success(Reservation(id: id, kind: kind, bytes: bytes, owner: self))
    }

    /// Runs `work` under a reservation. The reservation is released only after `work` returns, so a
    /// cancelled but uninterruptible worker keeps its bytes until it has truly finished.
    public func run<T: Sendable>(_ kind: ResourceKind, bytes: Int64,
                                 _ work: @Sendable (Reservation) async throws -> T) async throws -> T {
        switch reserve(kind, bytes: bytes) {
        case .failure(let reason): throw ResourceDenied(reason: reason)
        case .success(let r):
            defer { r.release() }
            return try await work(r)
        }
    }

    public func snapshot() -> ResourceSnapshot {
        lock.lock(); defer { lock.unlock() }
        var pending: Int64 = 0, resident: Int64 = 0
        var infos: [ResourceReservationInfo] = []
        for (id, e) in entries {
            if e.state == .resident { resident += e.bytes } else { pending += e.bytes }
            infos.append(.init(id: id, kind: e.kind, bytes: e.bytes, state: e.state))
        }
        return ResourceSnapshot(pendingBytes: pending, residentBytes: resident,
                                reservations: infos.sorted { $0.id < $1.id }, lastDenial: lastDenial)
    }

    // MARK: - Internals (lock held where noted)

    /// Caller holds the lock. Reads available memory fresh.
    private func check(kind: ResourceKind, bytes: Int64, excluding: UInt64?) -> ResourceDenialReason? {
        guard bytes > 0 else { return .invalidRequest }
        if kind.isFuturePreparation, pressureActive() { return .memoryPressure }
        var pending: Int64 = 0, resident: Int64 = 0, ofKind: Int64 = 0
        for (id, e) in entries where id != excluding {
            if e.state == .resident { resident += e.bytes } else { pending += e.bytes }
            if e.kind == kind { ofKind += e.bytes }
        }
        if pending + resident + bytes > config.absoluteCapBytes { return .absoluteCap }
        if let cap = config.kindCapBytes[kind], ofKind + bytes > cap { return .absoluteCap }
        guard let available = availableMemory() else { return .availabilityUnknown }
        // Resident buffers are already missing from `available`; only unmaterialised bytes still will be.
        if pending + bytes + config.safetyReserveBytes + config.requiredHeadroomBytes > available {
            return .insufficientHeadroom
        }
        return nil
    }

    fileprivate func state(of id: UInt64) -> ResourceReservationState {
        lock.lock(); defer { lock.unlock() }
        return entries[id]?.state ?? .released
    }
    fileprivate func isCancelRequested(_ id: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries[id]?.cancelRequested ?? false
    }
    fileprivate func markResident(_ id: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if entries[id]?.state == .pending { entries[id]?.state = .resident }
    }
    fileprivate func requestCancel(_ id: UInt64) {
        lock.lock(); defer { lock.unlock() }
        entries[id]?.cancelRequested = true
    }
    fileprivate func release(_ id: UInt64) {
        lock.lock(); defer { lock.unlock() }
        entries[id] = nil
    }
    fileprivate func authorizeAllocation(_ id: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[id], !e.cancelRequested else { return false }
        if e.state == .resident { return true }
        // Fresh recheck with this reservation's own bytes counted once.
        if let denial = check(kind: e.kind, bytes: e.bytes, excluding: id) {
            lastDenial = denial
            return false
        }
        return true
    }
}

public struct ResourceDenied: Error, Sendable, Equatable { public let reason: ResourceDenialReason }
