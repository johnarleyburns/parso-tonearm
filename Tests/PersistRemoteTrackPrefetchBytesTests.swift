import XCTest

/// `AppState`/`DiscoveryRuntimeController`/`SourceDetailView+Remote` all live under
/// `Sources/App/` and `Sources/Features/`, both excluded from the `TonearmCore` SwiftPM target
/// in `Package.swift` — `swift test` cannot import or construct any of them. Source-inspection
/// is the established pattern for pinning this level of behavior (see
/// `FavoriteAndHistoryGuardOrderingTests` in `Tests/FavoriteAndHistoryTransientTrackTests.swift`).
///
/// Real report: a direct browse-and-play tap on a cloud-drive track went dead for the entire
/// download, because `playRemote`/`DiscoveryRuntimeController.onPlay` awaited
/// `persistRemoteTrack` — which pinned the full file to disk — before `player.play` ever ran.
final class PersistRemoteTrackPrefetchBytesTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testPersistRemoteTrackHasAPrefetchBytesParameterDefaultingTrue() throws {
        let appStateDownloads = try source("Sources/App/AppState+Downloads.swift")
        XCTAssertTrue(appStateDownloads.contains(
            "func persistRemoteTrack(_ row: TrackRow, prefetchBytes: Bool = true) async -> TrackRow?"),
            "every existing caller (favorites, edit metadata, custom artwork, watch prep) must keep waiting for the download by default")
        XCTAssertTrue(appStateDownloads.contains("private func performPersistRemoteTrack(_ row: TrackRow, prefetchBytes: Bool) async -> TrackRow?"))
    }

    func testPerformPersistRemoteTrackOnlyAwaitsTheDownloadWhenPrefetchBytesIsTrue() throws {
        let appStateDownloads = try source("Sources/App/AppState+Downloads.swift")
        let function = try XCTUnwrap(appStateDownloads.range(
            of: "private func performPersistRemoteTrack(_ row: TrackRow, prefetchBytes: Bool) async -> TrackRow? {"))
        let body = appStateDownloads[function.upperBound...]
        let closingBrace = try XCTUnwrap(body.range(of: "\n    }\n"))
        let functionBody = body[..<closingBrace.lowerBound]
        let ifPrefetch = try XCTUnwrap(functionBody.range(of: "if prefetchBytes {"))
        let awaitedDownload = try XCTUnwrap(functionBody.range(of: "_ = await download(rows: [row])"))
        let backgroundDownload = try XCTUnwrap(functionBody.range(of: "Task { @MainActor [weak self] in _ = await self?.download(rows: [row]) }"))
        XCTAssertLessThan(ifPrefetch.lowerBound, awaitedDownload.lowerBound,
            "the blocking download call must be inside the prefetchBytes branch")
        XCTAssertLessThan(awaitedDownload.lowerBound, backgroundDownload.lowerBound,
            "the awaited (blocking) branch must come before the non-blocking background one")
    }

    func testPlayRemoteDoesNotWaitForTheDownloadBeforeStartingPlayback() throws {
        let sourceDetail = try source("Sources/Features/Sources/SourceDetailView+Remote.swift")
        XCTAssertTrue(sourceDetail.contains("appState.persistRemoteTrack(rows[startIndex], prefetchBytes: false)"),
            "playRemote must not block the tap that starts playback on the full download")
    }

    func testMoodSearchOnPlayDoesNotWaitForTheDownloadBeforeStartingPlayback() throws {
        let discoveryRuntime = try source("Sources/App/DiscoveryRuntimeController.swift")
        XCTAssertTrue(discoveryRuntime.contains("appState.persistRemoteTrack(row, prefetchBytes: false)"),
            "onPlay must not block starting playback on the full download, same as playRemote")
    }

    /// Every OTHER caller must keep its existing default (await the full download) — this isn't
    /// a bug, favorites/edit-metadata/custom-artwork/watch-prep all still need the bytes.
    func testOtherPersistRemoteTrackCallersStillDefaultToWaitingForTheDownload() throws {
        for path in [
            "Sources/App/AppState+FavoritesPlaylists.swift",
            "Sources/App/AppState+EditMetadata.swift",
            "Sources/App/AppState+CustomArtwork.swift",
            "Sources/App/AppState+Watch.swift",
        ] {
            let callerSource = try source(path)
            XCTAssertTrue(callerSource.contains("persistRemoteTrack("),
                "\(path) is expected to call persistRemoteTrack")
            XCTAssertFalse(callerSource.contains("prefetchBytes: false"),
                "\(path) must keep the default (waiting for the download) — it's not a playback hot path")
        }
    }
}
