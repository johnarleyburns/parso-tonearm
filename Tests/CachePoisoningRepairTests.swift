import XCTest
import ParsoAudioStreaming
@testable import TonearmCore

/// Real report: an expired Dropbox temp link / revoked token response got cached and durably
/// adopted before `AppState.cacheCompletedDownload`'s HTTP-status check existed — a poisoned
/// entry that fails every later play and was never re-fetched, because the "already downloaded"
/// check only ever asked whether *something* was there. `repairPoisonedCloudDownloads` is the
/// manual, one-shot repair for installs that already have one of these sitting in their cache.
@MainActor
final class CachePoisoningRepairTests: XCTestCase {
    private func makeRemoteAsset(store: LibraryStore, url: String) async throws -> (Source, Asset) {
        let source = try await store.insertSource(Source(
            id: nil, kind: .dropbox, iaIdentifier: nil, originalURL: nil, title: "Dropbox",
            addedAt: Date(), lastResolvedAt: nil, followUpdates: false,
            licenseText: nil, memberCapHit: false))
        let track = try await store.insertTrack(Track(
            id: nil, albumId: nil, sourceId: source.id!, title: "Track", trackNo: 1,
            discNo: nil, durationSec: nil, codec: nil, sampleRate: nil,
            bitDepthOrBitrate: nil, sortKey: "a"))
        let asset = try await store.insertAsset(Asset(
            id: nil, trackId: track.id!, kind: .remote, bookmark: nil, relPath: nil,
            remoteURL: url, altRemoteURL: nil, sizeBytes: nil, unsupportedReason: nil))
        return (source, asset)
    }

    /// Plants a durable, "complete" cache entry whose blob is actually `body` — exactly the
    /// state a poisoned (or a genuinely valid) prior download left behind.
    private func plantCacheEntry(cacheKey: String, body: Data) async {
        let fileURL = AudioCache.fileURL(for: cacheKey)
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? body.write(to: fileURL, options: .atomic)
        await AudioCache.shared.adoptCompleteFile(byteCount: Int64(body.count), for: cacheKey, durable: true)
    }

    func testRemovesAPoisonedErrorBodyAdoptedAsAnAudioDownload() async throws {
        let appState = AppState(store: try LibraryStore(inMemory: true))
        let url = "https://stub.test/\(UUID().uuidString)/expired.mp3"
        _ = try await makeRemoteAsset(store: appState.store, url: url)
        let remoteURL = URL(string: url)!
        let cacheKey = AudioCache.key(for: remoteURL)
        await plantCacheEntry(cacheKey: cacheKey, body: Data(#"{"error":"expired_access_token"}"#.utf8))
        XCTAssertTrue(AudioCache.completeCacheExists(for: remoteURL))

        let result = await appState.repairPoisonedCloudDownloads()

        XCTAssertEqual(result.checked, 1)
        XCTAssertEqual(result.repaired, 1)
        XCTAssertFalse(AudioCache.completeCacheExists(for: remoteURL),
            "a poisoned entry must be evicted so the next play re-fetches fresh")
        XCTAssertEqual(appState.lastCacheRepairResult, result,
            "the result must be published for Settings to show, per CLAUDE.md's no-silent-work rule")
    }

    func testLeavesAGenuineAudioDownloadAlone() async throws {
        let appState = AppState(store: try LibraryStore(inMemory: true))
        let url = "https://stub.test/\(UUID().uuidString)/real.flac"
        _ = try await makeRemoteAsset(store: appState.store, url: url)
        let remoteURL = URL(string: url)!
        let cacheKey = AudioCache.key(for: remoteURL)
        await plantCacheEntry(cacheKey: cacheKey, body: Data("fLaC".utf8) + Data(repeating: 0, count: 32))
        XCTAssertTrue(AudioCache.completeCacheExists(for: remoteURL))

        let result = await appState.repairPoisonedCloudDownloads()

        XCTAssertEqual(result.checked, 1)
        XCTAssertEqual(result.repaired, 0)
        XCTAssertTrue(AudioCache.completeCacheExists(for: remoteURL),
            "a genuinely valid cached download must survive the repair pass")
    }

    func testSkipsEntriesThatAreNotDurablyComplete() async throws {
        let appState = AppState(store: try LibraryStore(inMemory: true))
        let url = "https://stub.test/\(UUID().uuidString)/still-streaming.mp3"
        _ = try await makeRemoteAsset(store: appState.store, url: url)
        let remoteURL = URL(string: url)!
        let cacheKey = AudioCache.key(for: remoteURL)
        // A normal in-progress stream: cached bytes exist but it's neither durable nor complete.
        await AudioCache.shared.setContentLength(1_000, for: cacheKey)
        await AudioCache.shared.recordWrite(range: 0..<10, for: cacheKey)

        let result = await appState.repairPoisonedCloudDownloads()

        XCTAssertEqual(result.checked, 0, "an in-progress, non-durable stream must never be touched")
        XCTAssertEqual(result.repaired, 0)
    }
}
