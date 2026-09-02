import XCTest
@testable import TonearmCore
@testable import TonearmWatchCore
@testable import TonearmWatchProtocol

/// Phase 4: the phone's real GRDB-backed request handler, its pure projections, and the playback
/// bridge seam. The integration case at the bottom drives the real watch coordinator across the fake
/// duplex link — the definition of done: a fake-transport watch searches the complete fixture
/// library and plays a playlist through a spy phone player.
final class PhoneWatchProjectionTests: XCTestCase {
    private let libraryID = WatchPairedLibraryID("library-phase4")

    // MARK: - Fixture

    private struct Fixture {
        let store: LibraryStore
        let playlistRef: WatchCollectionRef
        let albumRef: WatchCollectionRef
        let emptyPlaylistRef: WatchCollectionRef
        let trackIDs: [WatchTrackID]
    }

    private func makeFixture(extraTracks: Int = 0) async throws -> Fixture {
        let store = try LibraryStore(inMemory: true)
        let source = try await store.insertSource(
            Source(id: nil, kind: .local, iaIdentifier: nil, originalURL: nil, title: "Fixture",
                   addedAt: Date(), lastResolvedAt: nil, followUpdates: false, licenseText: nil,
                   memberCapHit: false))
        let sourceID = try XCTUnwrap(source.id)
        let artist = try await store.insertArtist(
            Artist(id: nil, name: "Miles Davis", sortName: "Davis, Miles"))
        let artistID = try XCTUnwrap(artist.id)
        let album = try await store.insertAlbum(
            Album(id: nil, sourceId: sourceID, title: "Kind of Blue", artist: "Miles Davis",
                  artistId: artistID, albumArtist: "Miles Davis", genre: "Jazz", year: 1959,
                  artworkId: "art-1"))
        let albumID = try XCTUnwrap(album.id)

        var trackIDs: [WatchTrackID] = []
        var trackRowIDs: [Int64] = []
        let titles = ["So What", "Freddie Freeloader", "Blue in Green"]
        for (i, title) in titles.enumerated() {
            let track = try await store.insertTrack(
                Track(id: nil, albumId: albumID, sourceId: sourceID, title: title, trackNo: i + 1,
                      discNo: 1, durationSec: 300 + Double(i), codec: "FLAC", sampleRate: 44_100,
                      bitDepthOrBitrate: "16-bit", sortKey: String(format: "%04d", i + 1),
                      genre: "Jazz", composer: nil, artistId: artistID))
            let tid = try XCTUnwrap(track.id)
            trackIDs.append(PhoneWatchID.track(track))
            trackRowIDs.append(tid)
            _ = try await store.insertAsset(
                Asset(id: nil, trackId: tid, kind: .localRef, bookmark: nil, relPath: nil,
                      remoteURL: "file:///Music/\(title).flac", altRemoteURL: nil, sizeBytes: 1_024,
                      unsupportedReason: nil))
        }
        for n in 0..<extraTracks {
            let track = try await store.insertTrack(
                Track(id: nil, albumId: albumID, sourceId: sourceID, title: "Filler \(n)",
                      trackNo: 100 + n, discNo: 2, durationSec: 60, codec: "FLAC", sampleRate: 44_100,
                      bitDepthOrBitrate: "16-bit", sortKey: String(format: "%04d", 100 + n),
                      genre: "Jazz", composer: nil, artistId: artistID))
            _ = try XCTUnwrap(track.id)
        }

        let playlist = try await store.insertPlaylist(
            Playlist(id: nil, title: "Evening Jazz", kind: .manual, folderBookmark: nil, watch: false))
        let playlistID = try XCTUnwrap(playlist.id)
        for tid in trackRowIDs {
            try await store.addToPlaylist(playlistId: playlistID, trackId: tid)
        }

        let empty = try await store.insertPlaylist(
            Playlist(id: nil, title: "Nothing Yet", kind: .manual, folderBookmark: nil, watch: false))

        return Fixture(
            store: store,
            playlistRef: WatchCollectionRef(kind: .playlist, id: PhoneWatchID.playlist(playlist)),
            albumRef: WatchCollectionRef(kind: .album, id: PhoneWatchID.album(album)),
            emptyPlaylistRef: WatchCollectionRef(kind: .playlist, id: PhoneWatchID.playlist(empty)),
            trackIDs: trackIDs)
    }

    private func makeHandler(_ fixture: Fixture, bridge: SpyPlaybackBridge = SpyPlaybackBridge(),
                             downloaded: Set<WatchTrackID> = []) -> PhoneWatchRequestHandler {
        PhoneWatchRequestHandler(
            store: fixture.store, player: bridge, libraryID: libraryID,
            revisionStore: WatchInMemoryRevisionStore(revision: 3),
            downloadedProvider: { downloaded })
    }

    // MARK: - Search

    func testConnectedSearchSpansTracksAlbumsAndPlaylists() async throws {
        let fixture = try await makeFixture()
        let handler = makeHandler(fixture)

        let response = try await handler.handleSearch(
            WatchSearchRequest(query: "blue", scope: .all, generation: 1))

        let kinds = Set(response.rows.map(\.kind))
        XCTAssertTrue(kinds.contains(.track))   // "Blue in Green"
        XCTAssertTrue(kinds.contains(.album))   // "Kind of Blue"
        XCTAssertTrue(response.rows.contains { $0.kind == .track && $0.title == "Blue in Green" })
        XCTAssertTrue(response.rows.contains { $0.kind == .album && $0.title == "Kind of Blue" })
    }

    func testSearchTrackRowsMatchLibraryStoreRankingOrder() async throws {
        let fixture = try await makeFixture()
        let handler = makeHandler(fixture)

        let expected = try await fixture.store.search("jazz").map { PhoneWatchID.track($0.track).rawValue }
        let response = try await handler.handleSearch(
            WatchSearchRequest(query: "jazz", scope: .tracks, generation: 7))

        XCTAssertEqual(response.rows.map(\.id), expected)
        XCTAssertFalse(expected.isEmpty)
    }

    func testSearchPagingIsForwardOnlyAndNonOverlapping() async throws {
        let fixture = try await makeFixture()
        let handler = makeHandler(fixture)

        let first = try await handler.handleSearch(
            WatchSearchRequest(query: "jazz", scope: .tracks, generation: 1, limit: 2))
        XCTAssertEqual(first.rows.count, 2)
        let token = try XCTUnwrap(first.nextPageToken)

        let second = try await handler.handleSearch(
            WatchSearchRequest(query: "jazz", scope: .tracks, pageToken: token, generation: 2, limit: 2))

        XCTAssertTrue(Set(first.rows.map(\.id)).isDisjoint(with: second.rows.map(\.id)))
        XCTAssertNil(second.nextPageToken)
    }

    func testCorruptPageTokenRewindsToFirstPageRatherThanThrowing() async throws {
        let fixture = try await makeFixture()
        let handler = makeHandler(fixture)

        let response = try await handler.handleSearch(
            WatchSearchRequest(query: "jazz", scope: .tracks, pageToken: "not-base64!!",
                               generation: 1, limit: 2))
        XCTAssertEqual(response.rows.count, 2)
    }

    func testShortQueryReturnsEmptyWithoutHittingTheStore() async throws {
        let fixture = try await makeFixture()
        let handler = makeHandler(fixture)

        let response = try await handler.handleSearch(
            WatchSearchRequest(query: "a", scope: .all, generation: 1))
        XCTAssertTrue(response.rows.isEmpty)
    }

    // MARK: - Browse

    func testBrowseAlbumsIsTitleSortedWithTrackCounts() async throws {
        let fixture = try await makeFixture()
        let handler = makeHandler(fixture)

        let response = try await handler.handleBrowse(
            WatchBrowseRequest(category: .albums, generation: 1))

        XCTAssertEqual(response.rows.map(\.title), ["Kind of Blue"])
        XCTAssertEqual(response.rows.first?.trackCount, 3)
    }

    func testBrowseRecentReflectsPlayHistory() async throws {
        let fixture = try await makeFixture()
        let handler = makeHandler(fixture)
        let rows = try await fixture.store.allTrackRows()
        try await fixture.store.recordPlay(trackId: try XCTUnwrap(rows[1].track.id))

        let response = try await handler.handleBrowse(
            WatchBrowseRequest(category: .recent, generation: 1))

        XCTAssertEqual(response.rows.first?.title, rows[1].track.title)
    }

    // MARK: - Collection detail

    func testCollectionDetailReturnsOrderedTracksAndHonestTotalCount() async throws {
        let fixture = try await makeFixture()
        let handler = makeHandler(fixture)

        let response = try await handler.handleCollection(
            WatchCollectionRequest(collection: fixture.playlistRef, limit: 2))

        XCTAssertEqual(response.title, "Evening Jazz")
        XCTAssertEqual(response.totalCount, 3)
        XCTAssertEqual(response.tracks.map(\.title), ["So What", "Freddie Freeloader"])
        XCTAssertTrue(response.isPlayable)
        XCTAssertNotNil(response.nextPageToken)
    }

    func testCollectionDetailUsesTransferTimeDerivativeBindings() async throws {
        let fixture = try await makeFixture()
        let cover = String(repeating: "c", count: 64)
        let custom = String(repeating: "d", count: 64)
        let handler = PhoneWatchRequestHandler(
            store: fixture.store, player: SpyPlaybackBridge(), libraryID: libraryID,
            revisionStore: WatchInMemoryRevisionStore(revision: 3),
            artworkBindingProvider: { trackID in
                XCTAssertFalse(trackID.isEmpty)
                return (coverArtworkID: cover, customArtworkID: custom)
            })

        let response = try await handler.handleCollection(
            WatchCollectionRequest(collection: fixture.playlistRef, limit: 1))

        let track = try XCTUnwrap(response.tracks.first)
        XCTAssertEqual(track.coverArtworkID, cover)
        XCTAssertEqual(track.customArtworkID, custom)
        // The catalog's IA artwork identifier is retained only as a legacy source field; it is
        // not used as either watch-installed derivative binding.
        XCTAssertEqual(track.artworkID, "art-1")
    }

    func testEmptyPlaylistIsVisiblyNonPlayable() async throws {
        let fixture = try await makeFixture()
        let handler = makeHandler(fixture)

        let response = try await handler.handleCollection(
            WatchCollectionRequest(collection: fixture.emptyPlaylistRef))
        XCTAssertEqual(response.totalCount, 0)
        XCTAssertFalse(response.isPlayable)

        let reply = await handler.handlePlayCommand(.playCollection(fixture.emptyPlaylistRef))
        XCTAssertFalse(reply.accepted)
        XCTAssertEqual(reply.fault?.code, .contentNotFound)
    }

    func testUnknownCollectionSurfacesContentNotFound() async throws {
        let fixture = try await makeFixture()
        let handler = makeHandler(fixture)

        do {
            _ = try await handler.handleCollection(
                WatchCollectionRequest(collection: WatchCollectionRef(kind: .album, id: "arow:99999")))
            XCTFail("expected a fault")
        } catch let fault as WatchProtocolFault {
            XCTAssertEqual(fault.code, .contentNotFound)
        }
    }

    // MARK: - Playback

    func testPlayCollectionDrivesBridgeAndReturnsAuthoritativeSnapshot() async throws {
        let fixture = try await makeFixture()
        let bridge = SpyPlaybackBridge()
        let handler = makeHandler(fixture, bridge: bridge)

        let reply = await handler.handlePlayCommand(.playCollection(fixture.playlistRef))

        XCTAssertTrue(reply.accepted)
        let snapshot = try XCTUnwrap(reply.snapshot)
        XCTAssertEqual(snapshot.currentItem?.title, "So What")
        XCTAssertEqual(snapshot.queueCount, 3)
        XCTAssertEqual(snapshot.collectionTitle, "Evening Jazz")
        let directives = await bridge.directives
        XCTAssertEqual(directives, ["play(3@0)"])
    }

    func testPlayTrackStartsCollectionAtTheTappedRow() async throws {
        let fixture = try await makeFixture()
        let bridge = SpyPlaybackBridge()
        let handler = makeHandler(fixture, bridge: bridge)

        let reply = await handler.handlePlayCommand(
            .playTrack(fixture.trackIDs[2], in: fixture.playlistRef))

        XCTAssertTrue(reply.accepted)
        XCTAssertEqual(reply.snapshot?.currentItem?.title, "Blue in Green")
        XCTAssertEqual(reply.snapshot?.queueIndex, 2)
    }

    func testDeletedTrackBetweenRequestAndPlayIsRejected() async throws {
        let fixture = try await makeFixture()
        let bridge = SpyPlaybackBridge()
        let handler = makeHandler(fixture, bridge: bridge)

        _ = try await handler.handleSearch(
            WatchSearchRequest(query: "so what", scope: .tracks, generation: 1))
        let rows = try await fixture.store.allTrackRows()
        try await fixture.store.deleteTrack(id: try XCTUnwrap(rows.first { $0.track.title == "So What" }?.track.id))

        let reply = await handler.handlePlayCommand(.playTrack(fixture.trackIDs[0]))
        XCTAssertFalse(reply.accepted)
        XCTAssertEqual(reply.fault?.code, .contentNotFound)
        let directives = await bridge.directives
        XCTAssertTrue(directives.isEmpty)
    }

    func testEveryTransportCommandForwardsToTheBridge() async throws {
        let fixture = try await makeFixture()
        let bridge = SpyPlaybackBridge()
        let handler = makeHandler(fixture, bridge: bridge)
        _ = await handler.handlePlayCommand(.playCollection(fixture.playlistRef))

        let cases: [(WatchPlayCommand, String)] = [
            (WatchPlayCommand(action: .pause), "setPlaying(false)"),
            (WatchPlayCommand(action: .play), "setPlaying(true)"),
            (WatchPlayCommand(action: .togglePlayPause), "toggle"),
            (WatchPlayCommand(action: .next), "advance(1)"),
            (WatchPlayCommand(action: .previous), "advance(-1)"),
            (WatchPlayCommand(action: .jumpToIndex, startIndex: 2), "jump(2)"),
            (WatchPlayCommand(action: .seek, seekSeconds: 42), "seek(42.0)"),
            (WatchPlayCommand(action: .setShuffle, shuffleEnabled: true), "shuffle(true)"),
            (WatchPlayCommand(action: .setRepeat, repeatMode: .all), "repeat(all)")
        ]
        for (command, _) in cases {
            let reply = await handler.handlePlayCommand(command)
            XCTAssertTrue(reply.accepted, "\(command.action) should be accepted")
        }
        let directives = await bridge.directives
        XCTAssertEqual(Array(directives.dropFirst()), cases.map(\.1))
    }

    func testRequestSnapshotIsReadOnly() async throws {
        let fixture = try await makeFixture()
        let bridge = SpyPlaybackBridge()
        let handler = makeHandler(fixture, bridge: bridge)
        _ = await handler.handlePlayCommand(.playCollection(fixture.playlistRef))
        let directivesBefore = await bridge.directives

        let reply = await handler.handlePlayCommand(WatchPlayCommand(action: .requestSnapshot))

        XCTAssertTrue(reply.accepted)
        XCTAssertNotNil(reply.snapshot?.currentItem, "requestSnapshot must return the live snapshot")
        let directivesAfter = await bridge.directives
        XCTAssertEqual(directivesAfter, directivesBefore, "requestSnapshot must not touch the player")
    }

    func testTransportCommandMissingItsArgumentIsRejected() async throws {
        let fixture = try await makeFixture()
        let handler = makeHandler(fixture)

        let reply = await handler.handlePlayCommand(WatchPlayCommand(action: .seek))
        XCTAssertFalse(reply.accepted)
    }

    // MARK: - Snapshot builder

    func testSnapshotWindowIsClampedAroundTheCurrentIndex() {
        let queue = (0..<60).map {
            WatchTrackSummary(trackID: WatchTrackID("t\($0)"), title: "T\($0)")
        }
        let mid = WatchPlaybackSnapshotBuilder.build(.init(
            revision: 1, source: .localLibrary, isPlaying: true, queue: queue, index: 30,
            elapsedSeconds: 5))
        XCTAssertEqual(mid.queueWindow.count, WatchPhonePlaybackSnapshot.queueWindowLimit)
        XCTAssertEqual(mid.queueCount, 60)
        XCTAssertTrue(mid.queueWindow.contains { $0.trackID == WatchTrackID("t30") })
        XCTAssertGreaterThanOrEqual(mid.queueWindowStartIndex, 20)

        let end = WatchPlaybackSnapshotBuilder.build(.init(
            revision: 1, source: .localLibrary, isPlaying: false, queue: queue, index: 59,
            elapsedSeconds: 0))
        XCTAssertEqual(end.queueWindow.count, WatchPhonePlaybackSnapshot.queueWindowLimit)
        XCTAssertEqual(end.queueWindow.last?.trackID, WatchTrackID("t59"))

        let empty = WatchPlaybackSnapshotBuilder.build(.init(
            revision: 9, source: .localLibrary, isPlaying: true, queue: [], index: 0,
            elapsedSeconds: 3))
        XCTAssertEqual(empty.source, .none)
        XCTAssertFalse(empty.isPlaying)
    }

    // MARK: - Payload budget

    func testFullSearchPageStaysWithinTheImmediateChannelBudget() async throws {
        let fixture = try await makeFixture(extraTracks: 40)
        let handler = makeHandler(fixture)

        let response = try await handler.handleSearch(
            WatchSearchRequest(query: "jazz", scope: .all, generation: 1))
        let data = try WatchProtocolEnvelope.encode(
            kind: .searchResponse, payload: response, pairedLibraryID: libraryID)

        XCTAssertLessThanOrEqual(response.rows.count, WatchSearchRequest.maximumPageSize)
        XCTAssertLessThan(data.count, 24_000, "a search page must fit an immediate WCSession message")
    }

    // MARK: - Integration across the fake link

    func testWatchSearchesAndPlaysAcrossTheFakeDuplexLink() async throws {
        let fixture = try await makeFixture()
        let bridge = SpyPlaybackBridge()
        let handler = makeHandler(fixture, bridge: bridge)

        let link = WatchFakeDuplexLink()
        let phone = PhoneWatchProtocolCoordinator(
            transport: link.transport(for: .phone), handler: handler, libraryID: libraryID,
            revisionStore: WatchInMemoryRevisionStore(revision: 3), gracePeriod: 0.05)
        let watch = WatchConnectivityCoordinator(
            transport: link.transport(for: .watch),
            stateStore: WatchInMemorySyncStateStore(pairedLibraryID: libraryID),
            configuration: .init(immediateDeadline: .milliseconds(200), gracePeriod: 0.05))
        await link.attach(phone, as: .phone)
        await link.attach(watch, as: .watch)
        await phone.activate(reachable: true)
        await watch.activate(reachable: true)

        guard case .results(let search) = await watch.search("blue", scope: .all) else {
            return XCTFail("expected results")
        }
        XCTAssertTrue(search.rows.contains { $0.title == "Blue in Green" })

        guard case .results(let browse) = await watch.browse(.playlists) else {
            return XCTFail("expected playlist results")
        }
        let playlistRow = try XCTUnwrap(browse.rows.first { $0.title == "Evening Jazz" })
        let ref = try XCTUnwrap(playlistRow.collectionRef)

        let detail = try await watch.collection(ref).get()
        XCTAssertEqual(detail.totalCount, 3)

        let reply = await watch.send(.playCollection(ref))
        XCTAssertTrue(reply.accepted)
        XCTAssertEqual(reply.snapshot?.currentItem?.title, "So What")
        let directives = await bridge.directives
        XCTAssertEqual(directives, ["play(3@0)"])
    }

}

// MARK: - Spy bridge

/// A `PhoneWatchPlaybackBridge` that records the directives it is given and answers `snapshot` from
/// the state those directives left behind — the "spy phone player" the Phase 4 DoD calls for.
private actor SpyPlaybackBridge: PhoneWatchPlaybackBridge {
    private(set) var directives: [String] = []
    private var queue: [WatchTrackSummary] = []
    private var index = 0
    private var playing = false
    private var shuffle = false
    private var repeatMode: TonearmWatchProtocol.WatchRepeatMode = .off
    private var collection: WatchCollectionRef?
    private var collectionTitle: String?

    func snapshot(revision: Int64) async -> WatchPhonePlaybackSnapshot {
        WatchPlaybackSnapshotBuilder.build(.init(
            revision: revision, source: queue.isEmpty ? .none : .localLibrary, isPlaying: playing,
            queue: queue, index: index, elapsedSeconds: 0, collection: collection,
            collectionTitle: collectionTitle, shuffleEnabled: shuffle, repeatMode: repeatMode))
    }

    func play(_ tracks: [TrackRow], startIndex: Int,
              collection: WatchCollectionRef?, collectionTitle: String?) async {
        directives.append("play(\(tracks.count)@\(startIndex))")
        queue = tracks.map { PhoneWatchProjection.trackSummary(from: $0, downloadedOnWatch: []) }
        index = min(max(0, startIndex), max(0, tracks.count - 1))
        playing = true
        self.collection = collection
        self.collectionTitle = collectionTitle
    }

    func setPlaying(_ playing: Bool) async { directives.append("setPlaying(\(playing))"); self.playing = playing }
    func togglePlayPause() async { directives.append("toggle"); playing.toggle() }
    func advance(by offset: Int) async {
        directives.append("advance(\(offset))")
        index = max(0, min(max(0, queue.count - 1), index + (offset >= 0 ? 1 : -1)))
    }
    func jump(toIndex index: Int) async { directives.append("jump(\(index))"); self.index = index }
    func seek(toSeconds seconds: Double) async { directives.append("seek(\(seconds))") }
    func setShuffle(_ enabled: Bool) async { directives.append("shuffle(\(enabled))"); shuffle = enabled }
    func setRepeat(_ mode: TonearmWatchProtocol.WatchRepeatMode) async {
        directives.append("repeat(\(mode.rawValue))"); repeatMode = mode
    }
}
