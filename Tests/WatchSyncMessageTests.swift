import XCTest
@testable import TonearmCore

final class WatchSyncMessageTests: XCTestCase {

    // MARK: - Encode/Decode round-trip

    func testEnvelopeRoundTrip() throws {
        let payload = WatchTrackDTO(key: "t123", title: "Test Track", sortKey: "T001")
        let data = try WatchSyncEnvelope.encode(kind: .catalog, catalogVersion: 1, payload: payload)
        let envelope = try XCTUnwrap(WatchSyncEnvelope.decode(data))

        XCTAssertEqual(envelope.protocolVersion, WatchSyncEnvelope.currentProtocolVersion)
        XCTAssertEqual(envelope.kind, .catalog)
        XCTAssertEqual(envelope.catalogVersion, 1)

        let decoded: WatchTrackDTO? = envelope.decodePayload(WatchTrackDTO.self)
        XCTAssertEqual(decoded?.key, "t123")
        XCTAssertEqual(decoded?.title, "Test Track")
    }

    func testEncodeCatalogSnapshot() throws {
        let snapshot = WatchCatalogSnapshot(
            version: 42,
            playlists: [WatchPlaylistDTO(key: "p1", title: "Rock", trackKeys: ["t1", "t2"])],
            albums: [WatchAlbumDTO(key: "a1", title: "Greatest Hits", artist: "Band")],
            artists: [WatchArtistDTO(key: "ar1", name: "Band")],
            tracks: [WatchTrackDTO(key: "t1", title: "Song 1", albumKey: "a1", sortKey: "001")])

        let data = try WatchSyncEnvelope.encode(kind: .catalog, catalogVersion: 42, payload: snapshot)
        let envelope = try XCTUnwrap(WatchSyncEnvelope.decode(data))
        let decoded: WatchCatalogSnapshot? = envelope.decodePayload(WatchCatalogSnapshot.self)

        XCTAssertEqual(decoded?.version, 42)
        XCTAssertEqual(decoded?.playlists.count, 1)
        XCTAssertEqual(decoded?.tracks.count, 1)
    }

    func testEncodeManifestReport() throws {
        let report = WatchManifestReport(
            entries: [WatchSyncManifestEntry(trackKey: "t1", bytes: 1024, pinned: true)],
            freeBytes: 500_000_000,
            catalogVersion: 3)
        let data = try WatchSyncEnvelope.encode(kind: .manifestReport, catalogVersion: 3, payload: report)
        let envelope = try XCTUnwrap(WatchSyncEnvelope.decode(data))
        let decoded: WatchManifestReport? = envelope.decodePayload(WatchManifestReport.self)

        XCTAssertEqual(decoded?.entries.count, 1)
        XCTAssertEqual(decoded?.freeBytes, 500_000_000)
        XCTAssertEqual(decoded?.entries.first?.pinned, true)
    }

    func testEncodeAudioMetadata() throws {
        let meta = WatchAudioMetadata(trackKey: "t1", bytes: 4096, pinned: true, catalogVersion: 5)
        let data = try WatchSyncEnvelope.encode(kind: .audio, catalogVersion: 5, payload: meta)
        let envelope = try XCTUnwrap(WatchSyncEnvelope.decode(data))
        let decoded: WatchAudioMetadata? = envelope.decodePayload(WatchAudioMetadata.self)

        XCTAssertEqual(decoded?.trackKey, "t1")
        XCTAssertEqual(decoded?.bytes, 4096)
        XCTAssertTrue(decoded?.pinned ?? false)
    }

    func testEncodeDeleteTracks() throws {
        let del = WatchDeleteTracks(trackKeys: ["t1", "t2", "t3"])
        let data = try WatchSyncEnvelope.encode(kind: .deleteTracks, catalogVersion: 1, payload: del)
        let envelope = try XCTUnwrap(WatchSyncEnvelope.decode(data))
        let decoded: WatchDeleteTracks? = envelope.decodePayload(WatchDeleteTracks.self)

        XCTAssertEqual(decoded?.trackKeys, ["t1", "t2", "t3"])
    }

    func testEncodeFetchRequest() throws {
        let req = WatchFetchRequest(trackKey: "t42")
        let data = try WatchSyncEnvelope.encode(kind: .fetchRequest, catalogVersion: 1, payload: req)
        let envelope = try XCTUnwrap(WatchSyncEnvelope.decode(data))
        let decoded: WatchFetchRequest? = envelope.decodePayload(WatchFetchRequest.self)

        XCTAssertEqual(decoded?.trackKey, "t42")
    }

    // MARK: - Unknown kind tolerance

    func testDecodeInvalidPayloadReturnsNil() {
        let envelope = WatchSyncEnvelope(
            protocolVersion: 1, catalogVersion: 1, kind: .catalog,
            payload: Data([0xFF, 0x00, 0xAA]))
        let decoded: WatchCatalogSnapshot? = envelope.decodePayload(WatchCatalogSnapshot.self)
        XCTAssertNil(decoded, "corrupt payload should return nil, not crash")
    }

    // MARK: - Protocol version gating

    func testProtocolVersionIsPositive() {
        XCTAssertGreaterThan(WatchSyncEnvelope.currentProtocolVersion, 0)
    }
}
