import Foundation

/// §12 Phase 10 — privacy-safe structured diagnostics.
///
/// Every operationally interesting moment on the watch is recorded as one of these: a coarse
/// `category`, a `stateCode` drawn from a fixed vocabulary, a `timestamp`, and a handful of
/// *numeric* measurements. The only free-form string a call site may attach is `correlationID` —
/// an opaque request/session identifier that is **hashed per export** and never emitted in the
/// clear (see `WatchDiagnosticsExporter`).
///
/// What must never reach an event: track/album/playlist titles, URLs, file paths, credentials,
/// tokens, or search text. The type has nowhere to put them — there is no free `message` field —
/// and `WatchDiagnosticsExporterTests` asserts the ban against the encoded JSON.
public enum WatchDiagnosticCategory: String, Codable, Sendable, CaseIterable {
    case activation
    case request
    case transferState
    case installResult
    case manifestConvergence
    case playbackTarget
    case routeEvent
    case storeRecovery
    case disconnectDuration
}

public struct WatchDiagnosticEvent: Sendable, Equatable {
    public let category: WatchDiagnosticCategory
    /// A short, fixed-vocabulary code — e.g. `"activated"`, `"timeout"`, `"converged"`, `"iPhone"`.
    /// Call sites pass compile-time string literals or enum `rawValue`s, never interpolated data.
    public let stateCode: String
    public let timestamp: Date
    /// Opaque request/session id, hashed at export. `nil` when the event isn't tied to one.
    public let correlationID: String?
    /// Optional latency/duration measurement, milliseconds.
    public let durationMillis: Int?
    /// Optional byte count (transfer size, store footprint).
    public let byteCount: Int64?
    /// Optional plain count (events coalesced, tracks in a desired set, retry number).
    public let count: Int?

    public init(category: WatchDiagnosticCategory,
                stateCode: String,
                timestamp: Date,
                correlationID: String? = nil,
                durationMillis: Int? = nil,
                byteCount: Int64? = nil,
                count: Int? = nil) {
        self.category = category
        self.stateCode = stateCode
        self.timestamp = timestamp
        self.correlationID = correlationID
        self.durationMillis = durationMillis
        self.byteCount = byteCount
        self.count = count
    }
}
