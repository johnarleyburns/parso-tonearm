import XCTest

/// `AppState` lives under `Sources/App/`, excluded from the `TonearmCore` SwiftPM target in
/// `Package.swift` — `swift test` cannot import or construct it. Source-inspection is the
/// established pattern for pinning this level of behavior (see
/// `FavoriteAndHistoryGuardOrderingTests` in `Tests/FavoriteAndHistoryTransientTrackTests.swift`).
/// The underlying mechanism this relies on — that `setDurable(false, for:)` alone cannot remove a
/// single-tier entry, and that `remove(keys:)`/`completeCacheExists` are the real primitives —
/// is exercised directly (no AppState needed) in `Tests/StreamingCacheTests.swift`.
///
/// Real reports this covers: a Dropbox/Google Drive track that genuinely couldn't be fetched (an
/// expired temp link, a revoked token) got its error response body written to disk and marked
/// `complete`/durable anyway — a poisoned, permanently "downloaded" entry that silently fails
/// every later play and is never re-fetched (`download(rows:)`/`makeOffline(source:)` never
/// checked the HTTP status). And a track mid-stream/mid-prefetch (a genuinely partial blob
/// already sitting at the same cache path `CachingResourceLoader` writes to) got adopted as a
/// complete download purely because *some* file existed there, not because it actually was
/// complete.
final class AppStateDownloadHardeningTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func cacheCompletedDownloadBody() throws -> Substring {
        let downloadsSource = try source("Sources/App/AppState+Downloads.swift")
        let function = try XCTUnwrap(downloadsSource.range(
            of: "private func cacheCompletedDownload(cacheKey: String, remoteURL: URL, asset: Asset, source: Source?) async {"))
        let body = downloadsSource[function.upperBound...]
        let closingBrace = try XCTUnwrap(body.range(of: "\n    }\n"))
        return body[..<closingBrace.lowerBound]
    }

    func testDownloadSessionIsInjectable() throws {
        let appStateSource = try source("Sources/App/AppState.swift")
        XCTAssertTrue(appStateSource.contains("var downloadSession: URLSession = .shared"),
            "download(rows:)/makeOffline(source:) must fetch through an injectable session, not the hardcoded shared one, to be testable at all")
    }

    func testCacheCompletedDownloadTrustsCompleteCacheExistsBeforeFetching() throws {
        let body = try cacheCompletedDownloadBody()
        let completeCheck = try XCTUnwrap(body.range(of: "if AudioCache.completeCacheExists(for: remoteURL) {"))
        let setDurable = try XCTUnwrap(body.range(of: "await AudioCache.shared.setDurable(true, for: cacheKey)"))
        let fetch = try XCTUnwrap(body.range(of: "downloadSession.data(for: request)"))
        XCTAssertLessThan(completeCheck.lowerBound, setDurable.lowerBound)
        XCTAssertLessThan(setDurable.lowerBound, fetch.lowerBound,
            "an entry AudioCache already knows is complete must be trusted (and pinned durable) before any network fetch is attempted")
        XCTAssertFalse(body.contains("FileManager.default.fileExists(atPath: destURL.path)"),
            "the 'already downloaded, skip the fetch' decision must not be based on bare file existence any more")
    }

    func testCacheCompletedDownloadChecksTheResponseStatusBeforeAdopting() throws {
        let body = try cacheCompletedDownloadBody()
        let statusCheck = try XCTUnwrap(body.range(of: "(200 ..< 300).contains(http.statusCode)"))
        let adopt = try XCTUnwrap(body.range(of: "await AudioCache.shared.adoptCompleteFile(byteCount: Int64(data.count), for: cacheKey, durable: true)"))
        XCTAssertLessThan(statusCheck.lowerBound, adopt.lowerBound,
            "a fetch must only be written to disk and adopted as complete once its HTTP status is actually 2xx")
    }

    func testMakeOfflineAndDownloadBothRouteThroughTheSharedHardenedHelper() throws {
        let downloadsSource = try source("Sources/App/AppState+Downloads.swift")
        XCTAssertTrue(downloadsSource.contains("func makeOffline(source: Source) async -> Bool"))
        XCTAssertTrue(downloadsSource.contains("func download(rows: [TrackRow]) async -> Int"))
        let occurrences = downloadsSource.components(
            separatedBy: "await cacheCompletedDownload(cacheKey: cacheKey, remoteURL: remoteURL, asset: asset, source:").count - 1
        XCTAssertEqual(occurrences, 2, "both makeOffline(source:) and download(rows:) must call the same hardened helper")
    }
}
