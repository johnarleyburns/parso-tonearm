import XCTest
@testable import TonearmCore

/// Real bug this answers: `AppState.makeOffline(source:)`/`download(rows:)`
/// used to fetch straight from `Asset.remoteURL`/`transientRemoteHeaders` —
/// fine for a just-resolved live row, but `transientRemoteHeaders` is never
/// persisted at all, and for several providers the persisted `remoteURL`
/// string itself goes stale (see `RemoteAssetRefetch`'s doc and
/// docs/plans/remote-sparse-indexing.md's "Phase 0" investigation for the
/// full per-provider breakdown this was traced from).
/// A plain mutable box, `@unchecked Sendable` — `resolveNode` is declared
/// `@Sendable` (it can genuinely cross an actor boundary in production, e.g.
/// called from `AppState`), so a test closure capturing a local `var`
/// directly cannot satisfy Swift 6's checker even though these tests only
/// ever call it once, synchronously awaited, with no real concurrency.
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

final class RemoteAssetRefetchTests: XCTestCase {
    private func asset(
        remoteURL: String? = "https://example.test/stale.mp3",
        remoteNodeID: String? = nil,
        remoteNodePath: String? = nil,
        transientHeaders: [String: String] = [:]
    ) -> Asset {
        var a = Asset(
            id: 1, trackId: 1, kind: .remote, bookmark: nil, relPath: nil,
            remoteURL: remoteURL, altRemoteURL: nil, sizeBytes: nil, unsupportedReason: nil,
            remoteNodeID: remoteNodeID, remoteNodePath: remoteNodePath)
        a.transientRemoteHeaders = transientHeaders
        return a
    }

    /// The primary fixed case: a node reference exists, re-resolution
    /// succeeds, and the FRESH url/headers are used — not the stale
    /// persisted ones.
    func testUsesFreshlyResolvedURLAndHeadersWhenANodeReferenceExists() async {
        let a = asset(
            remoteURL: "https://example.test/stale-signed-link?expired=1",
            remoteNodeID: "42", remoteNodePath: "artist/album/42",
            transientHeaders: [:]) // empty, as any DB-hydrated row's would be

        let seenNode = Box<RemoteNode?>(nil)
        let request = await RemoteAssetRefetch.request(for: a) { node in
            seenNode.value = node
            return ResolvedAsset(
                url: URL(string: "https://example.test/fresh-signed-link?token=abc")!,
                headers: ["Authorization": "Bearer fresh-token"])
        }

        XCTAssertEqual(seenNode.value?.id, "42")
        XCTAssertEqual(seenNode.value?.path, "artist/album/42")
        XCTAssertEqual(request?.url?.absoluteString, "https://example.test/fresh-signed-link?token=abc")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer fresh-token")
    }

    /// Re-resolution failing (offline, revoked credential) falls back to the
    /// legacy remoteURL + transient-headers path rather than failing
    /// outright — strictly no worse than pre-fix behavior, and still
    /// correct for a provider (Subsonic) whose persisted URL is normally
    /// self-authenticating.
    func testFallsBackToPersistedURLWhenReResolutionFails() async {
        enum Failure: Error { case offline }
        let a = asset(
            remoteURL: "https://example.test/still-good.mp3",
            remoteNodeID: "42", remoteNodePath: "artist/album/42",
            transientHeaders: ["X-Test": "1"])

        let request = await RemoteAssetRefetch.request(for: a) { _ in throw Failure.offline }

        XCTAssertEqual(request?.url?.absoluteString, "https://example.test/still-good.mp3")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "X-Test"), "1")
    }

    /// An asset persisted before this fix existed (no node reference at
    /// all) — same legacy fallback, and `resolveNode` must never be called.
    func testFallsBackDirectlyWhenNoNodeReferenceIsPersisted() async {
        let a = asset(remoteURL: "https://example.test/legacy.mp3", remoteNodeID: nil, remoteNodePath: nil)

        let resolveNodeCalled = Box(false)
        let request = await RemoteAssetRefetch.request(for: a) { _ in
            resolveNodeCalled.value = true
            return ResolvedAsset(url: URL(string: "https://example.test/should-not-be-used")!)
        }

        XCTAssertFalse(resolveNodeCalled.value)
        XCTAssertEqual(request?.url?.absoluteString, "https://example.test/legacy.mp3")
    }

    /// Neither a node reference nor a usable persisted URL — genuinely
    /// nothing to fetch.
    func testNilWhenNeitherANodeReferenceNorARemoteURLExists() async {
        let a = asset(remoteURL: nil, remoteNodeID: nil, remoteNodePath: nil)
        let request = await RemoteAssetRefetch.request(for: a) { _ in
            ResolvedAsset(url: URL(string: "https://example.test/unused")!)
        }
        XCTAssertNil(request)
    }
}
