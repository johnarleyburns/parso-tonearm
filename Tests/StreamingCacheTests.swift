import XCTest
import ParsoAudioStreaming
@testable import TonearmCore

/// Integration coverage for Tonearm on the shared `ParsoAudioStreaming` cache
/// (parso-audio-engine Phase 2). Runs under `swift test` — the pre-commit hook —
/// so the old manual streaming smoke steps run on every commit. Store mechanics
/// (LRU eviction, durable tier, derived artifacts) are owned by
/// `SparseCacheStoreTests` in parso-audio-engine; here we assert Tonearm's
/// wiring: its key identity, provider auth headers, the Opus→CAF derived
/// artifact, and pinned-download eviction protection.
final class StreamingCacheTests: XCTestCase {

    // MARK: - URLProtocol range stub

    final class RangeStub: URLProtocol {
        nonisolated(unsafe) static var blob = Data()
        nonisolated(unsafe) static var offline = false
        nonisolated(unsafe) static var requestCount = 0
        nonisolated(unsafe) static var lastHeaders: [String: String] = [:]

        static func reset(blob: Data) {
            self.blob = blob; offline = false; requestCount = 0; lastHeaders = [:]
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            Self.requestCount += 1
            Self.lastHeaders = request.allHTTPHeaderFields ?? [:]
            if Self.offline {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            let total = Self.blob.count
            var status = 200
            var body = Self.blob
            var headers = ["Content-Type": "audio/mpeg"]
            if let spec = request.value(forHTTPHeaderField: "Range")?.split(separator: "=").last {
                let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
                let lower = Int(parts.first ?? "") ?? 0
                let upper = min((parts.count > 1 ? Int(parts[1]) : nil) ?? (total - 1), total - 1)
                if lower <= upper {
                    body = Self.blob.subdata(in: lower..<(upper + 1))
                    status = 206
                    headers["Content-Range"] = "bytes \(lower)-\(upper)/\(total)"
                }
            }
            headers["Content-Length"] = String(body.count)
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private func stubSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [RangeStub.self]
        return URLSession(configuration: cfg)
    }

    private func makeStore(limit: Int64 = SparseCacheStore.defaultLimit) -> SparseCacheStore {
        SparseCacheStore(evictableRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent("tonearm-cache-\(UUID().uuidString)", isDirectory: true),
            durableRoot: nil, limitBytes: limit)
    }

    private func loader(_ store: SparseCacheStore, url: URL,
                        headers: [String: String] = [:]) throws -> CachingResourceLoader {
        let loader = CachingResourceLoader(originalURL: url, store: store,
            config: AudioCache.loaderConfig(headers: headers), session: stubSession())
        // Isolate HTTP/cache behavior from background-QoS filesystem admission.
        // An empty blob is NOT cached audio: range coverage is still zero and
        // every test must receive/write its bytes through the real warm path.
        // Under host IO contention Foundation's background createFile can block
        // in rename before the URLProtocol stub ever receives a request.
        let blob = store.layout.blobURL(for: loader.cacheKey)
        try FileManager.default.createDirectory(at: blob.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: blob)
        return loader
    }

    private func poll(_ c: @Sendable () async -> Bool) async {
        // The package suite also exercises Core ML and AVFoundation. Allow the
        // streaming task a full minute to receive its first range under that
        // load while retaining a bounded failure.
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if await c() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("condition not met in time")
    }

    // MARK: - Key identity

    func testCacheURLPreservesPath() {
        let remote = URL(string: "https://archive.org/download/foo/track.mp3")!
        let cached = RemoteAudioURL.cacheURL(for: remote, scheme: AudioCache.scheme)
        XCTAssertEqual(cached.scheme, "tonearm-cache")
        XCTAssertEqual(cached.path, remote.path)
    }

    func testCacheKeyIsStableAndKeepsTheTrailingSeparator() {
        // Tonearm's historical key: <64 hex>-<ext>, always with the "-" even when
        // there is no extension.
        let mp3 = AudioCache.key(for: URL(string: "https://archive.org/download/item/track.mp3")!)
        XCTAssertEqual(mp3, "995d3f45ace3a63922472923d0a45497240725186f0aea72ca31d99e9a2e9818-mp3")
        let noExt = AudioCache.key(for: URL(string: "https://archive.org/download/item/track")!)
        XCTAssertTrue(noExt.hasSuffix("-"))
    }

    // MARK: - Serve / replay offline (old manual smoke)

    func testStreamedTrackReplaysFromCacheWithNetworkGone() async throws {
        RangeStub.reset(blob: Data((0..<8192).map { UInt8($0 & 0xff) }))
        let store = makeStore()
        let url = URL(string: "https://archive.org/download/item/track.flac")!
        let l = try loader(store, url: url)

        l.warm(upTo: 8192)
        await poll { await store.rangeMap(for: l.cacheKey).contiguousBytes(from: 0) >= 8192 }
        l.shutdown()

        RangeStub.offline = true
        let after = RangeStub.requestCount
        let cached = await store.cachedContiguousBytes(for: l.cacheKey, from: 0)
        XCTAssertEqual(cached, 8192)
        XCTAssertEqual(RangeStub.requestCount, after)
    }

    func testProviderAuthHeadersRideEveryRequest() async throws {
        RangeStub.reset(blob: Data(repeating: 0xEE, count: 4096))
        let store = makeStore()
        let l = try loader(store, url: URL(string: "https://jellyfin.example/audio/1/stream.flac")!,
                       headers: ["Authorization": "MediaBrowser Token=\"abc123\""])
        l.warm(upTo: 4096)
        await poll { await store.rangeMap(for: l.cacheKey).contiguousBytes(from: 0) >= 4096 }
        l.shutdown()

        XCTAssertGreaterThan(RangeStub.requestCount, 0)
        XCTAssertEqual(RangeStub.lastHeaders["Authorization"], "MediaBrowser Token=\"abc123\"")
    }

    // MARK: - Opus → CAF derived artifact

    func testOpusCAFDerivedArtifactCountsTowardTheCacheTotal() async throws {
        let store = makeStore()
        let opusURL = URL(string: "https://archive.org/download/item/track.opus")!
        let key = AudioCache.key(for: opusURL)

        await store.setContentLength(1000, for: key)
        await store.recordWrite(range: 0..<1000, for: key)
        let cafURL = store.layout.derivedURL(for: key, name: AudioCache.cafArtifactName)
        try FileManager.default.createDirectory(at: cafURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 1, count: 400).write(to: cafURL)
        await store.recordDerivedBytes(400, name: AudioCache.cafArtifactName, for: key)

        let stored = await store.totalCachedBytes()
        XCTAssertEqual(stored, 1400)   // blob + CAF sibling
        // The CAF path is stable and lands in the key's derived directory.
        XCTAssertEqual(cafURL.lastPathComponent, "opus.caf")
        XCTAssertEqual(cafURL.deletingLastPathComponent().lastPathComponent, key)
        XCTAssertEqual(AudioCache.cafURL(forRemoteOpus: opusURL).lastPathComponent, "opus.caf")
    }

    // MARK: - Pinned-download eviction protection

    func testPinnedDownloadSurvivesAnOverBudgetEviction() async {
        let store = makeStore(limit: 10_000)
        await store.adoptCompleteFile(byteCount: 500, for: "pinned-flac", durable: true)

        await store.setContentLength(2000, for: "stream-flac")
        await store.recordWrite(range: 0..<2000, for: "stream-flac")
        await store.setProtectedKeys([])   // player is not holding stream-flac

        await store.setLimit(1000)   // streaming budget exceeded by stream-flac

        let hasPinned = await store.contains("pinned-flac")
        let hasStream = await store.contains("stream-flac")
        XCTAssertTrue(hasPinned)
        XCTAssertFalse(hasStream)
    }

    func testPlayingKeyIsProtectedFromEviction() async {
        let store = makeStore(limit: 1000)
        await store.setContentLength(2000, for: "now-playing")
        await store.setProtectedKeys(["now-playing"])
        await store.recordWrite(range: 0..<2000, for: "now-playing")   // over budget, but protected

        let stillThere = await store.contains("now-playing")
        XCTAssertTrue(stillThere)
    }

    // MARK: - Remove from Phone must actually delete, not just unpin

    /// Real report: tapping "Remove from Phone" (library rows and Jump Back In cards alike,
    /// both routed through the same `trackContextMenu`) never actually frees the track — the
    /// badge keeps showing it as downloaded no matter how many times it's tapped. `AudioCache`
    /// is configured single-tier (`AudioCache.shared` passes the SAME root as both
    /// `evictableRoot` and `durableRoot` — exactly what `makeStore()` above replicates), and in
    /// that mode `setDurable(false, for:)` is documented ("nothing to move — just flip the
    /// flag") to leave the blob and `meta.complete` completely untouched. Pins why
    /// `AppState.removeDownloadFromPhone` calling only `setDurable(false, for:)` can never work.
    func testSetDurableFalseAloneDoesNotRemoveACompleteEntryInSingleTierMode() async {
        let store = makeStore()
        await store.adoptCompleteFile(byteCount: 500, for: "track-key", durable: true)
        let before = await store.contains("track-key")
        XCTAssertTrue(before)

        await store.setDurable(false, for: "track-key")

        let meta = await store.meta(for: "track-key")
        XCTAssertEqual(meta?.complete, true, "single-tier setDurable(false) must not clear completeness")
        let after = await store.contains("track-key")
        XCTAssertTrue(after, "single-tier setDurable(false) must not remove the entry")
    }

    /// The actual fix: `remove(keys:)` is the one API that deletes the entry outright, which is
    /// what `AppState.removeDownloadFromPhone` must call instead.
    func testRemoveKeysActuallyDeletesACompleteDurableEntryInSingleTierMode() async {
        let store = makeStore()
        await store.adoptCompleteFile(byteCount: 500, for: "track-key", durable: true)
        let before = await store.contains("track-key")
        XCTAssertTrue(before)

        await store.remove(keys: ["track-key"])

        let after = await store.contains("track-key")
        XCTAssertFalse(after)
    }

    /// Source-inspection pin (established pattern: see
    /// `FavoriteAndHistoryGuardOrderingTests` in `Tests/FavoriteAndHistoryTransientTrackTests.swift`
    /// for exercising an `AppState` call site that needs a live singleton/provider isn't
    /// practical) — asserts the real call site actually calls the deleting API, not the
    /// single-tier-inert `setDurable(false, for:)`.
    func testRemoveDownloadFromPhoneCallsRemoveNotJustSetDurableFalse() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/App/AppState+Downloads.swift"),
            encoding: .utf8)
        let function = try XCTUnwrap(source.range(of: "func removeDownloadFromPhone(rows: [TrackRow]) async {"))
        let body = source[function.upperBound...]
        let closingBrace = try XCTUnwrap(body.range(of: "\n    }\n"))
        let functionBody = body[..<closingBrace.lowerBound]
        XCTAssertTrue(functionBody.contains("AudioCache.shared.remove(keys:"),
            "removeDownloadFromPhone must call remove(keys:) to actually delete the cached entry")
        XCTAssertFalse(functionBody.contains("AudioCache.shared.setDurable(false"),
            "setDurable(false, for:) is a no-op in Tonearm's single-tier cache and must not be used to remove a download")
    }
}
