import AVFoundation
import XCTest
@testable import TonearmCore

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _starts = 0, _stops = 0
    var starts: Int { lock.withLock { _starts } }
    var stops: Int { lock.withLock { _stops } }
    func start() { lock.withLock { _starts += 1 } }
    func stop() { lock.withLock { _stops += 1 } }
}

@MainActor
final class LocalAssetResolverTests: XCTestCase {
    private let fileURL = URL(fileURLWithPath: "/tmp/tonearm-test-local.m4a")

    private func asset(bookmark: Data? = Data([1]), relPath: String? = nil, kind: AssetKind = .localRef) -> Asset {
        Asset(id: 1, trackId: 1, kind: kind, bookmark: bookmark, relPath: relPath, remoteURL: nil,
              altRemoteURL: nil, sizeBytes: nil, unsupportedReason: nil)
    }

    private func resolver(_ c: Counter, resolves: Bool = true, grants: Bool = true, exists: Bool = true,
                          stale: Bool = false) -> LocalAssetResolver {
        let url = fileURL
        return LocalAssetResolver(
            resolveBookmark: { _ in resolves ? (url, stale) : nil },
            startAccess: { _ in if grants { c.start() }; return grants },
            stopAccess: { _ in c.stop() },
            fileExists: { _ in exists },
            managedBase: { URL(fileURLWithPath: "/tmp/tonearm-managed") })
    }

    func testBookmarkLeaseAcquiresOnceAndReleasesOnce() throws {
        let c = Counter()
        var resolved: ResolvedLocalAsset? = try resolver(c).resolve(asset())
        XCTAssertEqual(c.starts, 1)
        XCTAssertEqual(c.stops, 0)
        resolved?.lease?.release()
        resolved?.lease?.release()
        resolved = nil
        XCTAssertEqual(c.stops, 1)
    }

    func testLeaseReleasedWhenDisposed() throws {
        let c = Counter()
        var resolved: ResolvedLocalAsset? = try resolver(c).resolve(asset())
        XCTAssertNotNil(resolved)
        resolved = nil
        XCTAssertEqual(c.stops, 1)
    }

    func testDeniedAccessThrowsAndNeverStops() {
        let c = Counter()
        XCTAssertThrowsError(try resolver(c, grants: false).resolve(asset())) {
            XCTAssertEqual($0 as? LocalMediaFailure, .accessDenied)
        }
        XCTAssertEqual(c.stops, 0)
    }

    func testUnresolvableBookmarkIsRecoverableFailure() {
        let c = Counter()
        XCTAssertThrowsError(try resolver(c, resolves: false).resolve(asset())) {
            XCTAssertEqual($0 as? LocalMediaFailure, .bookmarkUnresolvable)
        }
        XCTAssertEqual(c.starts, 0)
    }

    func testMissingFileReleasesScope() {
        let c = Counter()
        XCTAssertThrowsError(try resolver(c, exists: false).resolve(asset())) {
            XCTAssertEqual($0 as? LocalMediaFailure, .fileMissing)
        }
        XCTAssertEqual(c.starts, 1)
        XCTAssertEqual(c.stops, 1)
    }

    func testStaleBookmarkIsRecorded() throws {
        let c = Counter()
        XCTAssertTrue(try resolver(c, stale: true).resolve(asset()).bookmarkWasStale)
    }

    func testRelPathNeedsNoLease() throws {
        let c = Counter()
        let resolved = try resolver(c).resolve(asset(bookmark: nil, relPath: "a.m4a", kind: .managedCopy))
        XCTAssertEqual(resolved.backing, .relPath)
        XCTAssertNil(resolved.lease)
        XCTAssertEqual(c.starts, 0)
    }

    // MARK: Player ownership

    func testReplacingAndClearingReleaseCurrentAndPreloadedLeases() {
        let c = Counter()
        let player = AudioPlayer.shared
        let saved = player.localResolver
        defer { player.localResolver = saved }
        player.localResolver = resolver(c)

        player.preloadedNextItem = player.buildItem(for: asset())?.item
        player.replaceItem(player.buildItem(for: asset())!.item, autoplay: false)
        XCTAssertEqual(c.starts, 2)
        XCTAssertEqual(c.stops, 0)

        // Invalidated preload releases its own lease, and only its own.
        player.dropPreloadedNext()
        XCTAssertEqual(c.stops, 1)

        // Clearing the queue releases the active item's lease.
        player.clearQueuePlayback()
        XCTAssertEqual(c.stops, 2)
    }

    private func drain() { RunLoop.current.run(until: Date().addingTimeInterval(1)) }

    func testLocalFailureSetsMessageAndDoesNotBuildItem() {
        let c = Counter()
        let player = AudioPlayer.shared
        let saved = player.localResolver
        defer { player.localResolver = saved; player.lastLocalFailure = nil }
        player.localResolver = resolver(c, grants: false)
        XCTAssertNil(player.buildItem(for: asset()))
        XCTAssertEqual(player.lastLocalFailure, .accessDenied)
        player.failLocalPlayback(.accessDenied)
        XCTAssertEqual(player.networkSkipMessage, LocalMediaFailure.accessDenied.userMessage)
        XCTAssertFalse(player.isPlaying)
    }

    func testRemoteItemDoesNotUseLocalResolver() {
        let c = Counter()
        let player = AudioPlayer.shared
        let saved = player.localResolver
        defer { player.localResolver = saved }
        player.localResolver = resolver(c)
        let remote = Asset(id: 2, trackId: 2, kind: .remote, bookmark: nil, relPath: nil,
                           remoteURL: "https://example.invalid/a.mp3", altRemoteURL: nil,
                           sizeBytes: nil, unsupportedReason: nil)
        let built = player.buildItem(for: remote)
        XCTAssertNotNil(built)
        XCTAssertFalse(built!.item is LocalPlayerItem)
        XCTAssertEqual(c.starts, 0)
    }

    func testInvalidFixtureReportsFailedStatus() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("bad.m4a")
        try Data("not audio".utf8).write(to: url)
        let item = LocalPlayerItem(url: url, lease: nil, backing: .relPath)
        let player = AVPlayer(playerItem: item)
        for _ in 0..<100 where item.status == .unknown { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(item.status, .failed)
        _ = player
    }
}
