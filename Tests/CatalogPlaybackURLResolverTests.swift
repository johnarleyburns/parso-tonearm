#if !os(watchOS)
import XCTest
@testable import TonearmCore

/// In-memory catalog standing in for the library's `blend_catalog_track` table.
final class FakeCatalog: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [String: BlendCatalogTrack] = [:]
    func add(jamendoID: String, cached: URL?) {
        var row = BlendCatalogTrack(catalogKey: BlendCatalogTrack.jamendoKey(trackID: jamendoID),
                                    packTag: BlendCatalogTrack.jamendoPackTag, state: .unindexed,
                                    durationSeconds: nil, bpm: nil, beatPeriod: nil, beatPhase: nil,
                                    rmsDB: nil, updatedAt: Date())
        row.sourceKind = .jamendo
        row.providerTrackID = jamendoID
        row.cachedURL = cached?.absoluteString
        lock.withLock { rows[row.catalogKey] = row }
    }
    func row(_ key: String) -> BlendCatalogTrack? { lock.withLock { rows[key] } }
    func setCached(_ key: String, _ url: URL) { lock.withLock { rows[key]?.cachedURL = url.absoluteString } }
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    private var lookups = 0
    func refreshed(_ id: String) { lock.withLock { ids.append(id) } }
    func looked() { lock.withLock { lookups += 1 } }
    var refreshIDs: [String] { lock.withLock { ids } }
    var lookupCount: Int { lock.withLock { lookups } }
}

final class CatalogPlaybackURLResolverTests: XCTestCase {
    private let stale = URL(string: "https://example.test/stale.mp3")!
    private let fresh = URL(string: "https://example.test/fresh.mp3")!

    static func row(kind: SourceKind, nodeID: String?, url: String, sourceID: Int64? = 1) -> TrackRow {
        let source = Source(id: sourceID, kind: kind, iaIdentifier: nil, originalURL: nil, title: "S", addedAt: Date(),
                            lastResolvedAt: nil, followUpdates: false, licenseText: nil, memberCapHit: false)
        let track = Track(id: 7, albumId: nil, sourceId: 1, title: "T", trackNo: nil, discNo: nil, durationSec: 100,
                          codec: nil, sampleRate: nil, bitDepthOrBitrate: nil, sortKey: "t")
        var asset = Asset(id: 7, trackId: 7, kind: .remote, bookmark: nil, relPath: nil, remoteURL: url,
                          altRemoteURL: nil, sizeBytes: nil, unsupportedReason: nil)
        asset.remoteNodeID = nodeID
        return TrackRow(track: track, album: nil, source: source, asset: asset)
    }

    private func resolver(_ store: FakeCatalog, _ calls: Calls) -> CatalogPlaybackURLResolver {
        let fresh = fresh
        return CatalogPlaybackURLResolver(
            lookup: { calls.looked(); return store.row($0) },
            resolver: JamendoLocatorResolver(maxTransientAttempts: 1, backoff: { _ in 0 }, sleep: { _ in },
                                             refresh: { calls.refreshed($0); return (fresh, nil) }),
            persist: { key, url, _ in store.setCached(key, url) })
    }

    func testOrdinaryJamendoRowRefreshesFromProviderIdentityAndPersistsCache() async throws {
        let store = FakeCatalog()
        let key = BlendCatalogTrack.jamendoKey(trackID: "99123")
        store.add(jamendoID: "99123", cached: stale)
        let calls = Calls()
        let row = Self.row(kind: .jamendoGenre, nodeID: "99123", url: stale.absoluteString)

        let resolved = try await resolver(store, calls).resolve(row: row)

        XCTAssertEqual(resolved?.url, fresh)
        XCTAssertEqual(calls.refreshIDs, ["99123"])
        XCTAssertEqual(store.row(key)?.cachedURL, fresh.absoluteString)
    }

    func testOrdinaryNonJamendoRowBypassesCatalogResolver() async throws {
        let store = FakeCatalog()
        let calls = Calls()
        let row = Self.row(kind: .iaItem, nodeID: "99123", url: stale.absoluteString)
        let resolved = try await resolver(store, calls).resolve(row: row)
        XCTAssertNil(resolved)
        XCTAssertEqual(calls.lookupCount, 0)
        XCTAssertTrue(calls.refreshIDs.isEmpty)
    }

    func testMissingCatalogIdentityFailsTruthfullyRatherThanUsingRawAssetURL() async throws {
        let store = FakeCatalog()
        let calls = Calls()
        let row = Self.row(kind: .jamendoGenre, nodeID: "555", url: stale.absoluteString)
        do {
            _ = try await resolver(store, calls).resolve(row: row)
            XCTFail("must not fall back to Asset.remoteURL")
        } catch {
            XCTAssertEqual(error as? JamendoResolveError, .permanent)
        }
        XCTAssertTrue(calls.refreshIDs.isEmpty)
    }

    func testTransientJamendoBrowseRowRefreshesByNodeIDWithoutCatalogLookupOrPersistence() async throws {
        let store = FakeCatalog()
        let calls = Calls()
        let row = Self.row(kind: .jamendoGenre, nodeID: "99123", url: stale.absoluteString, sourceID: nil)
        let result = try await resolver(store, calls).resolve(row: row)
        XCTAssertEqual(result?.url, fresh)
        XCTAssertEqual(calls.refreshIDs, ["99123"])
        XCTAssertEqual(calls.lookupCount, 0)
        XCTAssertNil(store.row(BlendCatalogTrack.jamendoKey(trackID: "99123")))
    }

    func testPersistedJamendoRowWithoutCatalogIdentityFailsInsteadOfUsingTransientBrowsePath() async throws {
        let calls = Calls()
        let row = Self.row(kind: .jamendoGenre, nodeID: "99123", url: stale.absoluteString, sourceID: 1)
        do {
            _ = try await resolver(FakeCatalog(), calls).resolve(row: row)
            XCTFail("persisted row must not use the transient path")
        } catch {
            XCTAssertEqual(error as? JamendoResolveError, .permanent)
        }
        XCTAssertTrue(calls.refreshIDs.isEmpty)
    }

    func testWhitespaceAndNonNumericJamendoNodeIDsAreRejected() async throws {
        for bad in [nil, "", "   ", "abc", "12x", "1 2"] as [String?] {
            let calls = Calls()
            let row = Self.row(kind: .jamendoGenre, nodeID: bad, url: stale.absoluteString)
            do {
                _ = try await resolver(FakeCatalog(), calls).resolve(row: row)
                XCTFail("\(String(describing: bad)) must be rejected")
            } catch {
                XCTAssertEqual(error as? JamendoResolveError, .permanent)
            }
            XCTAssertTrue(calls.refreshIDs.isEmpty)
        }
    }

    func testNonJamendoRemoteWithoutNodeIDRetainsExistingPlaybackPath() async throws {
        let calls = Calls()
        let row = Self.row(kind: .iaItem, nodeID: nil, url: stale.absoluteString)
        let resolved = try await resolver(FakeCatalog(), calls).resolve(row: row)
        XCTAssertNil(resolved)
        XCTAssertEqual(calls.lookupCount, 0)
    }
}
#endif
