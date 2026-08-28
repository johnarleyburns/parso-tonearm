import Foundation

/// A fixed-capacity, in-memory ring of the most recent diagnostic events. Bounded memory is a
/// Phase 10 definition-of-done item, so this never grows: recording past `capacity` drops the
/// oldest event. Pure value type — the shared sink call sites touch is `WatchDiagnosticsRecorder`.
public struct WatchDiagnosticsLog: Sendable {
    public private(set) var events: [WatchDiagnosticEvent]
    public let capacity: Int

    public init(capacity: Int = 512) {
        precondition(capacity > 0, "diagnostics ring capacity must be positive")
        self.capacity = capacity
        self.events = []
        self.events.reserveCapacity(capacity)
    }

    public mutating func record(_ event: WatchDiagnosticEvent) {
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
    }

    /// Events in recording order, oldest first.
    public func snapshot() -> [WatchDiagnosticEvent] { events }
}

/// The shared sink call sites write to. An `actor` so any isolation domain on the watch (the
/// connectivity actor, main-actor UI, the file installer) can record without an isolation dance.
/// The clock is injectable so tests are deterministic.
public actor WatchDiagnosticsRecorder {
    private var log: WatchDiagnosticsLog
    private let clock: @Sendable () -> Date

    public init(capacity: Int = 512, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.log = WatchDiagnosticsLog(capacity: capacity)
        self.clock = clock
    }

    public func record(_ category: WatchDiagnosticCategory,
                       _ stateCode: String,
                       correlationID: String? = nil,
                       durationMillis: Int? = nil,
                       byteCount: Int64? = nil,
                       count: Int? = nil) {
        log.record(WatchDiagnosticEvent(category: category,
                                        stateCode: stateCode,
                                        timestamp: clock(),
                                        correlationID: correlationID,
                                        durationMillis: durationMillis,
                                        byteCount: byteCount,
                                        count: count))
    }

    public func events() -> [WatchDiagnosticEvent] { log.snapshot() }

    public func removeAll() {
        log = WatchDiagnosticsLog(capacity: log.capacity)
    }

    /// Build the redacted, per-export-hashed payload (see `WatchDiagnosticsExporter`). A fresh
    /// random salt is used unless one is supplied (tests supply a fixed salt).
    public func export(appVersion: String,
                       generatedAt: Date? = nil,
                       salt: Data? = nil) -> WatchDiagnosticsExport {
        WatchDiagnosticsExporter.export(events: log.snapshot(),
                                        appVersion: appVersion,
                                        generatedAt: generatedAt ?? clock(),
                                        salt: salt ?? WatchDiagnosticsExporter.randomSalt())
    }
}
