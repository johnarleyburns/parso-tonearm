import GRDB
import Foundation
import Testing

@testable import TonearmCore
@testable import TonearmDiscovery

/// `discovery_setting` / `discovery_runtime` persistence (plan §4/§11 C05:
/// "status persistence (`discovery_runtime`/`discovery_setting`)").
@Suite struct DiscoverySettingsStoreTests {
    private func makeWriter() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        try Schema.migrator().migrate(queue)
        return queue
    }

    @Test func testPauseRoundTripsAndDefaultsFalse() async throws {
        let store = DiscoverySettingsStore(writer: try makeWriter())
        let paused0 = try await store.isPaused()
        #expect(!paused0)

        try await store.setPaused(true)
        let paused1 = try await store.isPaused()
        #expect(paused1)

        try await store.setPaused(false)
        let paused2 = try await store.isPaused()
        #expect(!paused2)
    }

    @Test func testChargingOnlyRoundTrips() async throws {
        let store = DiscoverySettingsStore(writer: try makeWriter())
        let before = try await store.isChargingOnly()
        #expect(!before)
        try await store.setChargingOnly(true)
        let after = try await store.isChargingOnly()
        #expect(after)
    }

    @Test func testRuntimeMergesNonNilFieldsOnly() async throws {
        let store = DiscoverySettingsStore(writer: try makeWriter())
        let start = Date(timeIntervalSince1970: 5_000)
        try await store.updateRuntime(lastStartAt: start, lastStopReason: "launch")
        var row = try await store.runtime()
        #expect(row.lastStartAt == start)
        #expect(row.lastStopReason == "launch")
        #expect(row.lastBackgroundSubmissionAt == nil)

        let submit = Date(timeIntervalSince1970: 6_000)
        try await store.updateRuntime(
            lastBackgroundSubmissionResult: "submitted", lastBackgroundSubmissionAt: submit)
        row = try await store.runtime()
        // Prior fields preserved.
        #expect(row.lastStartAt == start)
        #expect(row.lastStopReason == "launch")
        #expect(row.lastBackgroundSubmissionResult == "submitted")
        #expect(row.lastBackgroundSubmissionAt == submit)
    }

    /// The migration v20 fields the plan's C05 status surface calls for:
    /// last error (settable and clearable), coverage snapshot, next scheduled.
    @Test func testRuntimeV20FieldsRoundTripAndErrorIsClearable() async throws {
        let store = DiscoverySettingsStore(writer: try makeWriter())
        let scheduled = Date(timeIntervalSince1970: 9_000)

        try await store.updateRuntime(
            lastError: .some("embedFailed"),
            coverageSnapshot: "12 / 40",
            nextScheduledAt: scheduled)
        var row = try await store.runtime()
        #expect(row.lastError == "embedFailed")
        #expect(row.coverageSnapshot == "12 / 40")
        #expect(row.nextScheduledAt == scheduled)

        // An update that doesn't mention lastError leaves it untouched.
        try await store.updateRuntime(coverageSnapshot: "20 / 40")
        row = try await store.runtime()
        #expect(row.lastError == "embedFailed")
        #expect(row.coverageSnapshot == "20 / 40")

        // A successful run clears it (explicit `.some(nil)`).
        try await store.updateRuntime(lastError: .some(nil))
        row = try await store.runtime()
        #expect(row.lastError == nil)
    }
}
