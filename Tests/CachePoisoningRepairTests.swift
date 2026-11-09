import XCTest

/// `AppState`/`SettingsView` live under `Sources/App/`/`Sources/Features/`, both excluded from
/// the `TonearmCore` SwiftPM target in `Package.swift` — `swift test` cannot import or construct
/// either. Source-inspection is the established pattern for pinning this level of behavior (see
/// `FavoriteAndHistoryGuardOrderingTests` in `Tests/FavoriteAndHistoryTransientTrackTests.swift`).
/// `AudioFileSniffer`'s own sniffing logic is exercised directly (no AppState needed) in
/// `Tests/AudioFileSnifferTests.swift`.
///
/// Real report this covers: an expired Dropbox temp link / revoked token response got cached and
/// durably adopted before `AppState.cacheCompletedDownload`'s HTTP-status check existed — a
/// poisoned entry that fails every later play and was never re-fetched, because "already
/// downloaded" only ever asked whether *something* was cached, not whether it was actually
/// audio. `repairPoisonedCloudDownloads` is the manual, one-shot repair for installs that
/// already have one of these sitting in their cache.
final class CachePoisoningRepairTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func repairFunctionBody() throws -> Substring {
        let repairSource = try source("Sources/App/AppState+CacheRepair.swift")
        let function = try XCTUnwrap(repairSource.range(of: "func repairPoisonedCloudDownloads() async -> CacheRepairResult {"))
        let body = repairSource[function.upperBound...]
        let closingBrace = try XCTUnwrap(body.range(of: "\n    }\n"))
        return body[..<closingBrace.lowerBound]
    }

    func testOnlyDurableAndCompleteEntriesAreEverSniffed() throws {
        let body = try repairFunctionBody()
        let guardLine = try XCTUnwrap(body.range(
            of: "guard let meta = await AudioCache.shared.meta(for: cacheKey), meta.isDurable, meta.complete else { continue }"))
        let sniff = try XCTUnwrap(body.range(of: "AudioFileSniffer.looksLikeAudio(prefix:"))
        XCTAssertLessThan(guardLine.lowerBound, sniff.lowerBound,
            "an in-progress, non-durable stream must never reach the sniffer")
    }

    func testAFailedSniffEvictsTheEntryRatherThanJustUnpinningIt() throws {
        let body = try repairFunctionBody()
        let sniffGuard = try XCTUnwrap(body.range(of: "guard !AudioFileSniffer.looksLikeAudio(prefix: prefix) else { continue }"))
        let removal = try XCTUnwrap(body.range(of: "await AudioCache.shared.remove(keys: [cacheKey])"))
        XCTAssertLessThan(sniffGuard.lowerBound, removal.lowerBound)
        XCTAssertFalse(body.contains("setDurable(false"),
            "a poisoned entry must be deleted (remove(keys:)), not merely unpinned (setDurable(false,...) is a single-tier no-op — see AppState+Downloads.swift's own real report)")
    }

    func testResultIsPublishedForSettingsToShow() throws {
        let repairSource = try source("Sources/App/AppState+CacheRepair.swift")
        XCTAssertTrue(repairSource.contains("lastCacheRepairResult = result"),
            "the run's result must be published, per CLAUDE.md's no-silent-background-work rule")
        let appStateSource = try source("Sources/App/AppState.swift")
        XCTAssertTrue(appStateSource.contains("@Published var lastCacheRepairResult: CacheRepairResult?"))
    }

    func testSettingsExposesAVisibleManualTrigger() throws {
        let settingsSource = try source("Sources/Features/Settings/SettingsView+AccountSections.swift")
        XCTAssertTrue(settingsSource.contains("appState.repairPoisonedCloudDownloads()"),
            "the repair must be reachable from a real Settings control, not just exist as dead code")
        XCTAssertTrue(settingsSource.contains("isRepairingCloudDownloads"),
            "the UI must show that the scan is running, not just its eventual result")
    }
}
