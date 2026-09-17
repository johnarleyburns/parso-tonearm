#if !os(watchOS)
import Foundation
import GRDB
import TonearmCore

/// Persisted global scheduling gates/preferences (`discovery_setting`) and the
/// singleton `discovery_runtime` telemetry row (plan §4/§6/§11 C05: "status
/// persistence (`discovery_runtime`/`discovery_setting` per the plan)").
///
/// This is deliberately tiny: pause and the charging-only preference are the
/// two values the scheduler policy needs, and the runtime row is telemetry the
/// status UI reads — never the authoritative queue (that is
/// `discovery_index_job`).
public actor DiscoverySettingsStore {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    // MARK: - discovery_setting

    public func bool(forKey key: String, default fallback: Bool = false) throws -> Bool {
        try writer.read { db in
            guard let row = try DiscoverySetting.fetchOne(db, key: key) else { return fallback }
            return row.value == "1" || row.value.lowercased() == "true"
        }
    }

    public func setBool(_ value: Bool, forKey key: String) throws {
        try writer.write { db in
            var setting = DiscoverySetting(key: key, value: value ? "1" : "0")
            try setting.save(db)
        }
    }

    public func isPaused() throws -> Bool { try bool(forKey: DiscoverySetting.Key.paused) }

    public func setPaused(_ paused: Bool) throws {
        try setBool(paused, forKey: DiscoverySetting.Key.paused)
    }

    public func isChargingOnly() throws -> Bool {
        try bool(forKey: DiscoverySetting.Key.chargingOnly)
    }

    public func setChargingOnly(_ on: Bool) throws {
        try setBool(on, forKey: DiscoverySetting.Key.chargingOnly)
    }

    /// Defaults to `true` at the owner's explicit request — Wi-Fi-only
    /// (above) is the actual data-cost guard for this single-owner app, so
    /// there's no separate value in also defaulting this master switch off.
    public func isRemoteIndexingEnabled() throws -> Bool {
        try bool(forKey: DiscoverySetting.Key.remoteIndexingEnabled, default: true)
    }

    public func setRemoteIndexingEnabled(_ on: Bool) throws {
        try setBool(on, forKey: DiscoverySetting.Key.remoteIndexingEnabled)
    }

    /// Defaults to `true` — remote sampling only runs on Wi-Fi unless the
    /// user explicitly opts into cellular, never the other way around.
    public func isRemoteIndexingWiFiOnly() throws -> Bool {
        try bool(forKey: DiscoverySetting.Key.remoteIndexingWiFiOnly, default: true)
    }

    public func setRemoteIndexingWiFiOnly(_ on: Bool) throws {
        try setBool(on, forKey: DiscoverySetting.Key.remoteIndexingWiFiOnly)
    }

    // MARK: - discovery_runtime (singleton telemetry)

    public func runtime() throws -> DiscoveryRuntime {
        try writer.read { db in
            try DiscoveryRuntime.fetchOne(db, key: 1) ?? DiscoveryRuntime(id: 1)
        }
    }

    /// Merge non-nil fields into the singleton runtime row.
    public func updateRuntime(
        lastRunAt: Date? = nil,
        lastStartAt: Date? = nil,
        lastStopAt: Date? = nil,
        lastStopReason: String? = nil,
        lastBackgroundSubmissionResult: String? = nil,
        lastBackgroundSubmissionAt: Date? = nil,
        lastSuccessfulWorkAt: Date? = nil,
        lastError: String?? = nil,
        coverageSnapshot: String? = nil,
        nextScheduledAt: Date? = nil
    ) throws {
        try writer.write { db in
            var row = try DiscoveryRuntime.fetchOne(db, key: 1) ?? DiscoveryRuntime(id: 1)
            if let lastRunAt { row.lastRunAt = lastRunAt }
            if let lastStartAt { row.lastStartAt = lastStartAt }
            if let lastStopAt { row.lastStopAt = lastStopAt }
            if let lastStopReason { row.lastStopReason = lastStopReason }
            if let lastBackgroundSubmissionResult {
                row.lastBackgroundSubmissionResult = lastBackgroundSubmissionResult
            }
            if let lastBackgroundSubmissionAt {
                row.lastBackgroundSubmissionAt = lastBackgroundSubmissionAt
            }
            if let lastSuccessfulWorkAt { row.lastSuccessfulWorkAt = lastSuccessfulWorkAt }
            // `lastError` is doubly-optional so a caller can explicitly clear
            // it (pass `nil`) or leave it untouched (pass `.some(nil)` — the
            // default). A concrete string sets it.
            if case let .some(value) = lastError { row.lastError = value }
            if let coverageSnapshot { row.coverageSnapshot = coverageSnapshot }
            if let nextScheduledAt { row.nextScheduledAt = nextScheduledAt }
            try row.save(db)
        }
    }
}
#endif
