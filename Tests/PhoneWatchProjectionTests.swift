import Foundation
import Testing
@testable import TonearmCore
@testable import TonearmWatchCore
@testable import TonearmWatchProtocol

/// Phase 4: the phone's real GRDB-backed request handler, its pure projections, and the playback
/// bridge seam. The integration case at the bottom drives the real watch coordinator across the fake
/// duplex link — the definition of done: a fake-transport watch searches the complete fixture
/// library and plays a playlist through a spy phone player.
@Suite struct PhoneWatchProjectionTests {
    private let libraryID = WatchPairedLibraryID("library-phase4")

    @Test func testResolvedPlaylistCommandKeepsPlaylistQueueSource() {
        let playlist = Playlist(id: 42, title: "Evening Jazz", kind: .manual,
                                folderBookmark: nil, watch: false)
        let ref = WatchCollectionRef(kind: .playlist, id: "prow:42")

        let source = PhoneWatchPlaybackSource.queueSource(for: ref, playlist: playlist)

        guard case .playlist(let actual) = source else {
            Issue.record("a resolved watch playlist must remain a playlist queue")
            return
        }
        #expect(actual == playlist)
    }

    @Test func testUnresolvedOrNonPlaylistCommandUsesSafeLibraryQueueSource() {
        let ref = WatchCollectionRef(kind: .playlist, id: "prow:42")
        let album = WatchCollectionRef(kind: .album, id: "arow:7")

        guard case .library = PhoneWatchPlaybackSource.queueSource(for: ref, playlist: nil) else {
            Issue.record("an unresolved playlist must fall back safely to library playback")
            return
        }
        guard case .library = PhoneWatchPlaybackSource.queueSource(for: album, playlist: nil) else {
            Issue.record("non-playlist playback must use the library source")
            return
        }
    }

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
        let sourceID = try #require(source.id)
        let artist = try await store.insertArtist(
            Artist(id: nil, name: "Miles Davis", sortName: "Davis, Miles"))
        let artistID = try #require(artist.id)
        let album = try await store.insertAlbum(
            Album(id: nil, sourceId: sourceID, title: "Kind of Blue", artist: "Miles Davis",
                  artistId: artistID, albumArtist: "Miles Davis", genre: "Jazz", year: 1959,
                  artworkId: "art-1"))
        let albumID = try #require(album.id)

        var trackIDs: [WatchTrackID] = []
        var trackRowIDs: [Int64] = []
        let titles = ["So What", "Freddie Freeloader", "Blue in Green"]
        for (i, title) in titles.enumerated() {
            let track = try await store.insertTrack(
                Track(id: nil, albumId: albumID, sourceId: sourceID, title: title, trackNo: i + 1,
                      discNo: 1, durationSec: 300 + Double(i), codec: "FLAC", sampleRate: 44_100,
                      bitDepthOrBitrate: "16-bit", sortKey: String(format: "%04d", i + 1),
                      genre: "Jazz", composer: nil, artistId: artistID))
            let tid = try #require(track.id)
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
            _ = try #require(track.id)
        }

        let playlist = try await store.insertPlaylist(
            Playlist(id: nil, title: "Evening Jazz", kind: .manual, folderBookmark: nil, watch: false))
        let playlistID = try #require(playlist.id)
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

    @Test func testSelectedDownloadMetadataDoesNotMirrorFullPhoneCatalog() async throws {
        let fixture = try await makeFixture(extraTracks: 40)
        let selected = try #require(fixture.trackIDs.first)
        let pages = try await makeHandler(fixture).catalogPages(revision: 9,
            trackIDs: [selected.rawValue], playlistIDs: [fixture.playlistRef.id])
        #expect(pages.flatMap(\.tracks).map(\.trackID) == [selected])
        #expect(pages.allSatisfy { $0.downloadSelectionOnly == true })
        #expect(pages.flatMap(\.playlists).count == 1)
        #expect(pages.flatMap(\.playlists).first?.trackIDs == [selected])
        let empty = try await makeHandler(fixture).catalogPages(revision: 10, trackIDs: [], playlistIDs: [])
        #expect(empty.flatMap(\.tracks).isEmpty)
        #expect(empty.flatMap(\.playlists).isEmpty)
        let ordered = [fixture.trackIDs[1], fixture.trackIDs[0]]
        let playlist = WatchLibraryPlaylist(playlistID: fixture.playlistRef.id, title: "Explicit selection", trackIDs: ordered)
        let selectedPages = try await makeHandler(fixture).catalogPages(revision: 11,
            trackIDs: Set(ordered.map(\.rawValue)), playlistIDs: [fixture.playlistRef.id], selectedPlaylists: [playlist])
        #expect(selectedPages.flatMap(\.playlists) == [playlist], "Transfer the explicitly selected playlist name and order")
    }

    @Test func testConnectedSearchSpansTracksAlbumsAndPlaylists() async throws {
        let fixture = try await makeFixture()
        let handler = makeHandler(fixture)

        let response = try await handler.handleSearch(
            WatchSearchRequest(query: "blue", scope: .all, generation: 1))

        let kinds = Set(response.rows.map(\.kind))
        #expect(kinds.contains(.track))   // "Blue in Green"
        #expect(kinds.contains(.album))   // "Kind of Blue"
        #expect(response.rows.contains { $0.kind == .track && $0.title == "Blue in Green" })
        #expect(response.rows.contains { $0.kind == .album && $0.title == "Kind of Blue" })
    }

    @Test func testSearchTrackRowsMatchLibraryStoreRankingOrder() async throws {
        let fixture = try await makeFixture()
        let handler = makeHandler(fixture)

        let expected = try await fixture.store.search("jazz").map { PhoneWatchID.track($0.track).rawValue }
        let response = try await handler.handleSearch(
            WatchSearchRequest(query: "jazz", scope: .tracks, generation: 7))

        #expect(response.rows.map(\.id) == expected)
        #expect(!expected.isEmpty)
    }

    @Test func testSearchPagingIsForwardOnlyAndNonOverlapping() async throws {
        let fixture = try await makeFixture()
        let handler = makeHandler(fixture)

        let first = try await handler.handleSearch(
            WatchSearchRequest(query: "jazz", scope: .tracks, generation: 1, limit: 2))
        #expect(first.rows.count == 2)
        let token = try #require(first.nextPageToken)

        let second = try await handler.handleSearch(
            WatchSearchRequest(query: "jazz", scope: .tracks, pageToken: token, generation: 2, limit: 2))

        #expect(Set(first.rows.map(\.id)).isDisjoint(with: second.rows.map(\.id)))
        #expect(second.nextPageToken == nil)
    }

    @Test func testCorruptPageTokenRewindsToFirstPageRatherThanThrowing() async throws {
        let fixture = try await makeFixture()
        let handler = makeHandler(fixture)

        let response = try await handler.handleSearch(
            WatchSearchRequest(query: "jazz", scope: .tracks, pageToken: "not-base64!!",
                               generation: 1, limit: 2))
        #expect(response.rows.count == 2)
    }

    @Test func testShortQueryReturnsEmptyWithoutHittingTheStore() async throws {
        let fixture = try await makeFixture()
        let handler = makeHandler(fixture)

        let response = try await handler.handleSearch(
            WatchSearchRequest(query: "a", scope: .all, generation: 1))
        #expect(response.rows.isEmpty)
    }

    // MARK: - Browse

    @Test func testBrowseAlbumsIsTitleSortedWithTrackCounts() async throws {
        let fixture = try await makeFixture()
        let handler = makeHandler(fixture)

        let response = try await handler.handleBrowse(
            WatchBrowseRequest(category: .albums, generation: 1))

        #expect(response.rows.map(\.title) == ["Kind of Blue"])
        #expect(response.rows.first?.trackCount == 3)
    }

    @Test func testBrowseRecentReflectsPlayHistory() async throws {
        let fixture = try await makeFixture()
        let handler = makeHandler(fixture)
        let rows = try await fixture.store.allTrackRows()
        try await fixture.store.recordPlay(trackId: try #require(rows[1].track.id))

        let response = try await handler.handleBrowse(
            WatchBrowseRequest(category: .recent, generation: 1))

        #expect(response.rows.first?.title == rows[1].track.title)
    }

    // MARK: - Collection detail

    @Test func testCollectionDetailReturnsOrderedTracksAndHonestTotalCount() async throws {
        let fixture = try await makeFixture()
        let handler = makeHandler(fixture)

        let response = try await handler.handleCollection(
            WatchCollectionRequest(collection: fixture.playlistRef, limit: 2))

        #expect(response.title == "Evening Jazz")
        #expect(response.totalCount == 3)
        #expect(response.tracks.map(\.title) == ["So What", "Freddie Freeloader"])
        #expect(response.isPlayable)
        #expect(response.tracks.first?.genre == "Jazz")
        #expect(response.nextPageToken != nil)
    }

    @Test func testCollectionDetailUsesTransferTimeDerivativeBindings() async throws {
        let fixture = try await makeFixture()
        let cover = String(repeating: "c", count: 64)
        let custom = String(repeating: "d", count: 64)
        let handler = PhoneWatchRequestHandler(
            store: fixture.store, player: SpyPlaybackBridge(), libraryID: libraryID,
            revisionStore: WatchInMemoryRevisionStore(revision: 3),
            artworkBindingProvider: { trackID in
                #expect(!trackID.isEmpty)
                return (coverArtworkID: cover, customArtworkID: custom)
            })

        let response = try await handler.handleCollection(
            WatchCollectionRequest(collection: fixture.playlistRef, limit: 1))

        let track = try #require(response.tracks.first)
        #expect(track.coverArtworkID == cover)
        #expect(track.customArtworkID == custom)
        // The catalog's IA artwork identifier is retained only as a legacy source field; it is
        // not used as either watch-installed derivative binding.
        #expect(track.artworkID == "art-1")
        let pages = try await handler.catalogPages(revision: 4,
            trackIDs: [track.trackID.rawValue], playlistIDs: [])
        let pushed = try #require(pages.first?.tracks.first)
        #expect(pushed.coverArtworkID == cover)
        #expect(pushed.customArtworkID == custom)
        #expect(pushed.genre == "Jazz")
        #expect(pushed.artworkID == nil)
        let decoded = try JSONDecoder().decode(WatchTrackSummary.self, from: JSONEncoder().encode(pushed))
        #expect(decoded == pushed)
    }

    @Test func testEmptyPlaylistIsVisiblyNonPlayable() async throws {
        let fixture = try await makeFixture()
        let handler = makeHandler(fixture)

        let response = try await handler.handleCollection(
            WatchCollectionRequest(collection: fixture.emptyPlaylistRef))
        #expect(response.totalCount == 0)
        #expect(!response.isPlayable)

        let reply = await handler.handlePlayCommand(.playCollection(fixture.emptyPlaylistRef))
        #expect(!reply.accepted)
        #expect(reply.fault?.code == .contentNotFound)
    }

    @Test func testUnknownCollectionSurfacesContentNotFound() async throws {
        let fixture = try await makeFixture()
        let handler = makeHandler(fixture)

        do {
            _ = try await handler.handleCollection(
                WatchCollectionRequest(collection: WatchCollectionRef(kind: .album, id: "arow:99999")))
            Issue.record("expected a fault")
        } catch let fault as WatchProtocolFault {
            #expect(fault.code == .contentNotFound)
        }
    }

    // MARK: - Playback

    @Test func testPlayCollectionDrivesBridgeAndReturnsAuthoritativeSnapshot() async throws {
        let fixture = try await makeFixture()
        let bridge = SpyPlaybackBridge()
        let handler = makeHandler(fixture, bridge: bridge)

        let reply = await handler.handlePlayCommand(.playCollection(fixture.playlistRef))

        #expect(reply.accepted)
        let snapshot = try #require(reply.snapshot)
        #expect(snapshot.currentItem?.title == "So What")
        #expect(snapshot.queueCount == 3)
        #expect(snapshot.collectionTitle == "Evening Jazz")
        let directives = await bridge.directives
        #expect(directives == ["play(3@0)"])
    }

    @Test func testPlayTrackStartsCollectionAtTheTappedRow() async throws {
        let fixture = try await makeFixture()
        let bridge = SpyPlaybackBridge()
        let handler = makeHandler(fixture, bridge: bridge)

        let reply = await handler.handlePlayCommand(
            .playTrack(fixture.trackIDs[2], in: fixture.playlistRef))

        #expect(reply.accepted)
        #expect(reply.snapshot?.currentItem?.title == "Blue in Green")
        #expect(reply.snapshot?.queueIndex == 2)
    }

    @Test func testDeletedTrackBetweenRequestAndPlayIsRejected() async throws {
        let fixture = try await makeFixture()
        let bridge = SpyPlaybackBridge()
        let handler = makeHandler(fixture, bridge: bridge)

        _ = try await handler.handleSearch(
            WatchSearchRequest(query: "so what", scope: .tracks, generation: 1))
        let rows = try await fixture.store.allTrackRows()
        try await fixture.store.deleteTrack(id: try #require(rows.first { $0.track.title == "So What" }?.track.id))

        let reply = await handler.handlePlayCommand(.playTrack(fixture.trackIDs[0]))
        #expect(!reply.accepted)
        #expect(reply.fault?.code == .contentNotFound)
        let directives = await bridge.directives
        #expect(directives.isEmpty)
    }

    @Test func testEveryTransportCommandForwardsToTheBridge() async throws {
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
            (WatchPlayCommand(action: .setRepeat, repeatMode: .all), "repeat(all)"),
            (.setVolume(1.7), "setVolume(1.0)")
        ]
        for (command, _) in cases {
            let reply = await handler.handlePlayCommand(command)
            #expect(reply.accepted, "\(command.action) should be accepted")
        }
        let directives = await bridge.directives
        #expect(Array(directives.dropFirst()) == cases.map(\.1))
    }

    @Test func testRequestSnapshotIsReadOnly() async throws {
        let fixture = try await makeFixture()
        let bridge = SpyPlaybackBridge()
        let handler = makeHandler(fixture, bridge: bridge)
        _ = await handler.handlePlayCommand(.playCollection(fixture.playlistRef))
        let directivesBefore = await bridge.directives

        let reply = await handler.handlePlayCommand(WatchPlayCommand(action: .requestSnapshot))

        #expect(reply.accepted)
        #expect(reply.snapshot?.currentItem != nil, "requestSnapshot must return the live snapshot")
        let directivesAfter = await bridge.directives
        #expect(directivesAfter == directivesBefore, "requestSnapshot must not touch the player")
    }

    @Test func testSetVolumeIsClampedAndReportedInTheReplySnapshot() async throws {
        let fixture = try await makeFixture()
        let bridge = SpyPlaybackBridge()
        let handler = makeHandler(fixture, bridge: bridge)
        _ = await handler.handlePlayCommand(.playCollection(fixture.playlistRef))

        let reply = await handler.handlePlayCommand(.setVolume(0.35))
        #expect(reply.accepted)
        #expect(abs((reply.snapshot?.volume ?? -1) - 0.35) <= 0.0001)

        let missing = await handler.handlePlayCommand(WatchPlayCommand(action: .setVolume))
        #expect(!missing.accepted, "setVolume without a level must be rejected, not ignored")
    }

    @Test func testSnapshotCarriesArtworkColourAndClampsVolume() {
        let queue = [WatchTrackSummary(trackID: WatchTrackID("t0"), title: "T0")]
        let snapshot = WatchPlaybackSnapshotBuilder.build(.init(
            revision: 1, source: .localLibrary, isPlaying: true, queue: queue, index: 0,
            elapsedSeconds: 0, volume: -3, artworkColorHex: "#C9792F"))
        #expect(snapshot.volume == 0)
        #expect(snapshot.artworkColorHex == "#C9792F")
    }

    @Test func testOlderSnapshotWithoutRedesignFieldsStillDecodes() throws {
        let legacy = WatchPhonePlaybackSnapshot(revision: 3)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any] ?? [:]
        json.removeValue(forKey: "volume")
        json.removeValue(forKey: "artworkColorHex")
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(WatchPhonePlaybackSnapshot.self, from: data)
        #expect(decoded.volume == nil)
        #expect(decoded.artworkColorHex == nil)
    }

    @Test func testTransportCommandMissingItsArgumentIsRejected() async throws {
        let fixture = try await makeFixture()
        let handler = makeHandler(fixture)

        let reply = await handler.handlePlayCommand(WatchPlayCommand(action: .seek))
        #expect(!reply.accepted)
    }

    // MARK: - Snapshot builder

    @Test func testSnapshotWindowIsClampedAroundTheCurrentIndex() {
        let queue = (0..<60).map {
            WatchTrackSummary(trackID: WatchTrackID("t\($0)"), title: "T\($0)")
        }
        let mid = WatchPlaybackSnapshotBuilder.build(.init(
            revision: 1, source: .localLibrary, isPlaying: true, queue: queue, index: 30,
            elapsedSeconds: 5))
        #expect(mid.queueWindow.count == WatchPhonePlaybackSnapshot.queueWindowLimit)
        #expect(mid.queueCount == 60)
        #expect(mid.queueWindow.contains { $0.trackID == WatchTrackID("t30") })
        #expect(mid.queueWindowStartIndex >= 20)

        let end = WatchPlaybackSnapshotBuilder.build(.init(
            revision: 1, source: .localLibrary, isPlaying: false, queue: queue, index: 59,
            elapsedSeconds: 0))
        #expect(end.queueWindow.count == WatchPhonePlaybackSnapshot.queueWindowLimit)
        #expect(end.queueWindow.last?.trackID == WatchTrackID("t59"))

        let empty = WatchPlaybackSnapshotBuilder.build(.init(
            revision: 9, source: .localLibrary, isPlaying: true, queue: [], index: 0,
            elapsedSeconds: 3))
        #expect(empty.source == .none)
        #expect(!empty.isPlaying)
    }

    // MARK: - Payload budget

    @Test func testFullSearchPageStaysWithinTheImmediateChannelBudget() async throws {
        let fixture = try await makeFixture(extraTracks: 40)
        let handler = makeHandler(fixture)

        let response = try await handler.handleSearch(
            WatchSearchRequest(query: "jazz", scope: .all, generation: 1))
        let data = try WatchProtocolEnvelope.encode(
            kind: .searchResponse, payload: response, pairedLibraryID: libraryID)

        #expect(response.rows.count <= WatchSearchRequest.maximumPageSize)
        #expect(data.count < 24_000, "a search page must fit an immediate WCSession message")
    }

    // MARK: - Integration across the fake link

    @Test func testWatchSearchesAndPlaysAcrossTheFakeDuplexLink() async throws {
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
            Issue.record("expected results")
            return
        }
        #expect(search.rows.contains { $0.title == "Blue in Green" })

        guard case .results(let browse) = await watch.browse(.playlists) else {
            Issue.record("expected playlist results")
            return
        }
        let playlistRow = try #require(browse.rows.first { $0.title == "Evening Jazz" })
        let ref = try #require(playlistRow.collectionRef)

        let detail = try await watch.collection(ref).get()
        #expect(detail.totalCount == 3)

        let reply = await watch.send(.playCollection(ref))
        #expect(reply.accepted)
        #expect(reply.snapshot?.currentItem?.title == "So What")
        let directives = await bridge.directives
        #expect(directives == ["play(3@0)"])
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
    private var volume: Double = 1

    func snapshot(revision: Int64) async -> WatchPhonePlaybackSnapshot {
        WatchPlaybackSnapshotBuilder.build(.init(
            revision: revision, source: queue.isEmpty ? .none : .localLibrary, isPlaying: playing,
            queue: queue, index: index, elapsedSeconds: 0, collection: collection,
            collectionTitle: collectionTitle, shuffleEnabled: shuffle, repeatMode: repeatMode,
            volume: volume))
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
    func setVolume(_ level: Double) async { directives.append("setVolume(\(level))"); volume = level }
}
