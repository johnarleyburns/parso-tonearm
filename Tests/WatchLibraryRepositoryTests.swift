import Foundation
import SwiftData
import Testing
@testable import TonearmWatchCore

@Suite struct WatchLibraryRepositoryTests {
    @Test func testGenreSurvivesRepositoryUpdatesAndOlderMissingGenre() async throws {
        let fixture = try Fixture()
        try await fixture.repository.upsertTrack(.init(trackID: "genre", title: "Song", genre: "Classical", phoneRevision: 1))
        var tracks = try await fixture.repository.tracks()
        #expect(tracks.first?.genre == "Classical")
        try await fixture.repository.upsertTrack(.init(trackID: "genre", title: "Song", genre: "Choral", phoneRevision: 2))
        tracks = try await fixture.repository.tracks()
        #expect(tracks.first?.genre == "Choral")
        try await fixture.repository.upsertTrack(.init(trackID: "legacy", title: "Legacy"))
        tracks = try await fixture.repository.tracks()
        #expect(tracks.first { $0.id == "legacy" }?.genre == nil)
    }
    @Test func testCRUDRelationshipsSharedMembershipAndPartialCollections() async throws {
        let fixture = try Fixture()
        try await fixture.repository.upsertTrack(.init(trackID: "one", title: "First", artist: "Artist", albumTitle: "Album"))
        try await fixture.repository.upsertTrack(.init(trackID: "two", title: "Second", artist: "Artist", albumTitle: "Album"))
        try await fixture.repository.upsertPlaylist(.init(playlistID: "a", title: "A", trackIDs: ["one", "two"]))
        try await fixture.repository.upsertPlaylist(.init(playlistID: "b", title: "B", trackIDs: ["one"]))
        let digest = try fixture.write("one.m4a", bytes: Data("ready".utf8))
        try await fixture.repository.markAsset(trackID: "one", relativeFilename: "one.m4a", installedBytes: digest.bytes,
                                               sha256: digest.sha256, state: .ready)

        let playlists = try await fixture.repository.playlists()
        #expect(playlists.first { $0.id == "a" }?.readyTrackIDs == ["one"])
        #expect(playlists.first { $0.id == "b" }?.readyTrackIDs == ["one"])
        #expect(playlists.first { $0.id == "a" }?.isPartial == true)
        #expect(playlists.first { $0.id == "b" }?.isPartial == false)
        let readyIDs = try await fixture.repository.tracks(readyOnly: true).map(\.id)
        #expect(readyIDs == ["one"])
    }

    @Test func testFullTrackMetadataRoundTripsThroughSnapshots() async throws {
        let fixture = try Fixture()
        try await fixture.repository.upsertTrack(.init(
            trackID: "full", title: "Full", artist: "Artist", albumTitle: "Album", durationSeconds: 214.5,
            trackNumber: 3, discNumber: 2, artworkID: "art-1", localThumbnailFilename: "art-1.jpg",
            codec: "aac", expectedBytes: 4_096, expectedSHA256: "deadbeef", phoneRevision: 7))
        let stored = try await fixture.repository.tracks()
        let track = try #require(stored.first)
        #expect(track.durationSeconds == 214.5)
        #expect(track.trackNumber == 3)
        #expect(track.discNumber == 2)
        #expect(track.artworkID == "art-1")
        #expect(track.codec == "aac")
        #expect(track.phoneRevision == 7)
        #expect(track.localFilename == nil)
        #expect(!track.isReady)
    }

    @Test func testArtworkProjectionUsesInstalledCustomBeforeCover() async throws {
        let fixture = try Fixture()
        try await fixture.repository.upsertTrack(.init(trackID: "art", title: "Art", artworkID: "legacy",
                                                        coverArtworkID: "cover", customArtworkID: "custom"))
        let context = ModelContext(fixture.container)
        context.insert(WatchArtworkAssetModel(artworkID: "cover", relativeFilename: "cover.jpg", bytes: 1,
                                              validationState: .ready))
        context.insert(WatchArtworkAssetModel(artworkID: "custom", relativeFilename: "custom.jpg", bytes: 1,
                                              validationState: .ready))
        try context.save()
        let tracks = try await fixture.repository.tracks()
        let track = try #require(tracks.first)
        #expect(track.artworkFilename == "custom.jpg")
    }

    @Test func testArtworkGCRemovesUnreferencedAssetsButKeepsSharedReferences() async throws {
        let fixture = try Fixture()
        let fileURL = fixture.artwork.appendingPathComponent("shared.jpg")
        try Data("shared-art".utf8).write(to: fileURL)
        let digest = try WatchFileDigest.measure(fileURL)
        try await fixture.repository.upsertTrack(.init(trackID: "one", title: "One", coverArtworkID: digest.sha256))
        try await fixture.repository.upsertTrack(.init(trackID: "two", title: "Two", coverArtworkID: digest.sha256))
        let context = ModelContext(fixture.container)
        context.insert(WatchArtworkAssetModel(artworkID: digest.sha256, relativeFilename: fileURL.lastPathComponent,
                                              bytes: digest.bytes, validationState: .ready))
        try context.save()

        try await fixture.repository.upsertTrack(.init(trackID: "one", title: "One", coverArtworkID: nil))
        #expect(FileManager.default.fileExists(atPath: fileURL.path), "shared art must survive")
        let sharedAsset = try await fixture.repository.artworkAsset(artworkID: digest.sha256)
        #expect(sharedAsset != nil)

        try await fixture.repository.removeTracks(["two"])
        #expect(!FileManager.default.fileExists(atPath: fileURL.path), "zero-reference art must be swept")
        let removedAsset = try await fixture.repository.artworkAsset(artworkID: digest.sha256)
        #expect(removedAsset == nil)
    }

    @Test func testArtworkReconciliationAdoptsHashValidOrphansAndInvalidatesCorruptRows() async throws {
        let fixture = try Fixture()
        let validURL = fixture.artwork.appendingPathComponent("orphan.jpg")
        try Data("valid-art".utf8).write(to: validURL)
        let validDigest = try WatchFileDigest.measure(validURL)
        let canonicalURL = fixture.artwork.appendingPathComponent("\(validDigest.sha256).jpg")
        try FileManager.default.moveItem(at: validURL, to: canonicalURL)
        try await fixture.repository.reconcileArtworkFiles()
        let adoptedManifest = try await fixture.repository.manifest()
        #expect(adoptedManifest.installedArtworkIDs == [validDigest.sha256])

        let missingID = String(repeating: "e", count: 64)
        let context = ModelContext(fixture.container)
        context.insert(WatchArtworkAssetModel(artworkID: missingID, relativeFilename: "\(missingID).png",
                                              bytes: 1, validationState: .ready))
        try context.save()
        try await fixture.repository.reconcileArtworkFiles()
        let missingAsset = try await fixture.repository.artworkAsset(artworkID: missingID)
        let reconciledManifest = try await fixture.repository.manifest()
        #expect(missingAsset?.validationState == .corrupt)
        #expect(reconciledManifest.installedArtworkIDs == [validDigest.sha256])
    }

    // §5.4: a late-arriving older revision is acknowledged, never applied over newer metadata.
    @Test func testStaleRevisionIsAcknowledgedButNotApplied() async throws {
        let fixture = try Fixture()
        let inserted = try await fixture.repository.upsertTrack(.init(trackID: "t", title: "New Title", phoneRevision: 5))
        let stale = try await fixture.repository.upsertTrack(.init(trackID: "t", title: "Old Title", phoneRevision: 2))
        let current = try await fixture.repository.upsertTrack(.init(trackID: "t", title: "Newer Title", phoneRevision: 9))
        #expect([inserted, stale, current] == [.inserted, .staleIgnored, .updated])
        let titles = try await fixture.repository.tracks().map(\.title)
        #expect(titles == ["Newer Title"])

        try await fixture.repository.upsertPlaylist(.init(playlistID: "p", title: "P", trackIDs: ["t"], phoneRevision: 4))
        let stalePlaylist = try await fixture.repository.upsertPlaylist(
            .init(playlistID: "p", title: "P", trackIDs: [], phoneRevision: 1), desiredOnWatch: true)
        #expect(stalePlaylist == .staleIgnored)
        // The stale membership edit is dropped, but the watch-local desire flag still lands.
        let members = try await fixture.repository.playlists().first?.trackIDs
        #expect(members == ["t"])
    }

    @Test func testNormalizedSearchRanksTitleBeforeArtistAndIgnoresDiacritics() async throws {
        let fixture = try Fixture()
        try await fixture.repository.upsertTrack(.init(trackID: "title", title: "Beyonce Halo", artist: "Someone"))
        try await fixture.repository.upsertTrack(.init(trackID: "artist", title: "Halo", artist: "Beyoncé"))
        try await fixture.repository.upsertTrack(.init(trackID: "album", title: "Other", artist: "Nobody", albumTitle: "Beyonce Live"))
        for id in ["title", "artist", "album"] {
            let digest = try fixture.write("\(id).m4a", bytes: Data(id.utf8))
            try await fixture.repository.markAsset(trackID: id, relativeFilename: "\(id).m4a",
                                                   installedBytes: digest.bytes, sha256: digest.sha256, state: .ready)
        }
        let result = try await fixture.repository.search("BEYONCÉ", readyOnly: true).map(\.id)
        #expect(result == ["title", "artist", "album"])
        // Every term must match somewhere, but not all in the same column: "Halo" by "Beyoncé"
        // satisfies both terms across title and artist, and ranks below the title-only match.
        let bothTerms = try await fixture.repository.search("beyonce halo").map(\.id)
        let unmatchedTerm = try await fixture.repository.search("beyonce nonsense").map(\.id)
        let blank = try await fixture.repository.search("   ").map(\.id)
        #expect(bothTerms == ["title", "artist"])
        #expect(unmatchedTerm == [])
        #expect(blank == [])
    }

    @Test func testSearchExcludesTracksWithoutReadyAudioUnlessAsked() async throws {
        let fixture = try Fixture()
        try await fixture.repository.upsertTrack(.init(trackID: "metadata-only", title: "Pending"))
        let readyOnly = try await fixture.repository.search("pending", readyOnly: true).map(\.id)
        let everything = try await fixture.repository.search("pending", readyOnly: false).map(\.id)
        #expect(readyOnly == [])
        #expect(everything == ["metadata-only"])
    }

    @Test func testManifestAndStorageCountOnlyReadyAssets() async throws {
        let fixture = try Fixture()
        for id in ["ready", "installing"] { try await fixture.repository.upsertTrack(.init(trackID: id, title: id)) }
        try await fixture.repository.markAsset(trackID: "ready", relativeFilename: "ready.m4a", installedBytes: 10, sha256: "a", state: .ready)
        try await fixture.repository.markAsset(trackID: "installing", relativeFilename: "part.tmp", installedBytes: 4, sha256: "b", state: .installing)
        _ = try fixture.write("orphan.m4a", bytes: Data(repeating: 1, count: 3))
        let manifest = try await fixture.repository.manifest(), storage = try await fixture.repository.storage()
        #expect(manifest.readyTrackIDs == ["ready"]); #expect(manifest.installedBytes == 10)
        #expect(storage.readyBytes == 10)
        #expect(storage.stagingBytes == 4)
        #expect(storage.orphanBytes == 3)
    }

    @Test func testManifestIDIsStableAcrossInsertionOrderAndChangesWithContent() async throws {
        let first = try Fixture(), second = try Fixture()
        for (repository, ids) in [(first.repository, ["a", "b"]), (second.repository, ["b", "a"])] {
            for id in ids {
                try await repository.upsertTrack(.init(trackID: id, title: id))
                try await repository.markAsset(trackID: id, relativeFilename: "\(id).m4a", installedBytes: 1, sha256: id, state: .ready)
            }
        }
        let a = try await first.repository.manifest(), b = try await second.repository.manifest()
        #expect(a.manifestID == b.manifestID)
        #expect(a.readyTrackIDs == ["a", "b"])
        try await second.repository.markAsset(trackID: "a", relativeFilename: "a.m4a", installedBytes: 2, sha256: "a", state: .ready)
        let changed = try await second.repository.manifest()
        #expect(a.manifestID != changed.manifestID)
    }

    // §2.5: reserve the greater of 500 MB or 10% of free capacity before accepting a batch.
    @Test func testStorageReserveIsTheGreaterOfFiveHundredMegabytesOrTenPercent() {
        let small = WatchStorageSnapshot(readyBytes: 0, stagingBytes: 0, orphanBytes: 0, freeBytes: 1_000_000_000)
        #expect(small.reserveBytes == 500_000_000)
        #expect(small.canAccept(bytes: 400_000_000))
        #expect(!small.canAccept(bytes: 600_000_000))

        let large = WatchStorageSnapshot(readyBytes: 0, stagingBytes: 0, orphanBytes: 0, freeBytes: 20_000_000_000)
        #expect(large.reserveBytes == 2_000_000_000)
        #expect(large.canAccept(bytes: 18_000_000_000))
        #expect(!large.canAccept(bytes: 18_000_000_001))
        #expect(!large.canAccept(bytes: -1))
    }

    @Test func testReconciliationMarksMissingAndCorruptAndRetainsOrphans() async throws {
        let fixture = try Fixture()
        for id in ["missing", "corrupt"] { try await fixture.repository.upsertTrack(.init(trackID: id, title: id)) }
        try await fixture.repository.markAsset(trackID: "missing", relativeFilename: "missing.m4a", installedBytes: 2, sha256: "x", state: .ready)
        _ = try fixture.write("corrupt.m4a", bytes: Data("bad".utf8))
        try await fixture.repository.markAsset(trackID: "corrupt", relativeFilename: "corrupt.m4a", installedBytes: 3, sha256: "wrong", state: .ready)
        _ = try fixture.write("preserved.m4a", bytes: Data("orphan".utf8))
        let result = try await fixture.repository.reconcileFiles()
        #expect(result.missingTrackIDs == ["missing"]); #expect(result.corruptTrackIDs == ["corrupt"])
        #expect(result.orphans.map(\.relativeFilename) == ["preserved.m4a"])
        let ready = try await fixture.repository.tracks(readyOnly: true)
        #expect(ready.isEmpty)
        // The file that failed validation is still on disk — reconciliation never deletes audio.
        #expect(FileManager.default.fileExists(atPath: fixture.audio.appendingPathComponent("corrupt.m4a").path))
    }

    @Test func testOrphanAdoptionAndPlaylistSearch() async throws {
        let fixture = try Fixture(), data = Data("recover-me".utf8)
        try await fixture.repository.upsertTrack(.init(trackID: "recover", title: "Recovered"))
        try await fixture.repository.upsertPlaylist(.init(playlistID: "night", title: "Nîght Drive", trackIDs: ["recover"]))
        _ = try fixture.write("orphan.m4a", bytes: data)
        let reconciliation = try await fixture.repository.reconcileFiles()
        let orphan = try #require(reconciliation.orphans.first)
        try await fixture.repository.adoptOrphan(orphan, forTrackID: "recover")
        let ready = try await fixture.repository.tracks(readyOnly: true)
        let playlists = try await fixture.repository.searchPlaylists("night")
        #expect(ready.map(\.id) == ["recover"]); #expect(playlists.map(\.id) == ["night"])
    }

    /// Regression (#157): after an upgrade rebuilt the store, every previously downloaded track
    /// showed as undownloaded. The surviving files must re-attach to *their own* tracks.
    @Test func testRebuiltStoreReadoptsDownloadsToTheirOwnTracks() async throws {
        let fixture = try Fixture()
        let a = try fixture.write("a.m4a", bytes: Data("track-a-audio".utf8))
        let b = try fixture.write("b.m4a", bytes: Data("track-b-audio-longer".utf8))
        try await fixture.repository.upsertTrack(.init(trackID: "A", title: "A"))
        try await fixture.repository.upsertTrack(.init(trackID: "B", title: "B"))
        try await fixture.repository.markAsset(trackID: "A", relativeFilename: "a.m4a", installedBytes: a.bytes, sha256: a.sha256, state: .ready)
        try await fixture.repository.markAsset(trackID: "B", relativeFilename: "b.m4a", installedBytes: b.bytes, sha256: b.sha256, state: .ready)

        // The store is lost; only the audio directory and journal remain. B's metadata arrives first.
        let rebuilt = WatchLibraryRepository(container: try WatchStoreBootstrap.inMemory(), audioDirectory: fixture.audio)
        try await rebuilt.upsertTrack(.init(trackID: "B", title: "B"))
        try await rebuilt.upsertTrack(.init(trackID: "A", title: "A"))
        let orphans = try await rebuilt.reconcileFiles().orphans
        #expect(orphans.count == 2)
        for orphan in orphans { await rebuilt.adoptJournaledOrphan(orphan) }
        let ready = try await rebuilt.tracks(readyOnly: true)
        #expect(Dictionary(uniqueKeysWithValues: ready.map { ($0.id, $0.localFilename) }) ==
                       ["A": "a.m4a", "B": "b.m4a"])
    }

    // A rebuilt store must not call an unrelated file "ready" just because a track is waiting for one.
    @Test func testOrphanAdoptionRejectsFilesThatContradictTrackMetadata() async throws {
        let fixture = try Fixture()
        let digest = try fixture.write("candidate.m4a", bytes: Data("actual-audio".utf8))
        try await fixture.repository.upsertTrack(.init(trackID: "expects", title: "Expects",
                                                       expectedBytes: digest.bytes, expectedSHA256: String(repeating: "0", count: 64)))
        try await fixture.repository.upsertTrack(.init(trackID: "wrong-size", title: "Wrong Size",
                                                       expectedBytes: digest.bytes + 1, expectedSHA256: digest.sha256))
        let reconciliation = try await fixture.repository.reconcileFiles()
        let orphan = try #require(reconciliation.orphans.first)

        await assertThrows(WatchLibraryError.invalidOrphan("expects")) {
            try await fixture.repository.adoptOrphan(orphan, forTrackID: "expects")
        }
        await assertThrows(WatchLibraryError.invalidOrphan("wrong-size")) {
            try await fixture.repository.adoptOrphan(orphan, forTrackID: "wrong-size")
        }
        await assertThrows(WatchLibraryError.unknownTrack("nobody")) {
            try await fixture.repository.adoptOrphan(orphan, forTrackID: "nobody")
        }
        let stillPending = try await fixture.repository.tracks(readyOnly: true)
        #expect(stillPending.isEmpty)
    }

    @Test func testPlaybackRestorePrunesNonReadyEntriesDeterministically() async throws {
        let fixture = try Fixture()
        for id in ["ready", "missing"] { try await fixture.repository.upsertTrack(.init(trackID: id, title: id)) }
        try await fixture.repository.markAsset(trackID: "ready", relativeFilename: "ready.m4a", installedBytes: 1, sha256: "x", state: .ready)
        let context = ModelContext(fixture.container)
        context.insert(WatchPlaybackStateModel(queueTrackIDs: ["missing", "ready"], currentIndex: 1, elapsedSeconds: 12))
        try context.save()
        let restored = try await fixture.repository.restorePlaybackState()
        #expect(restored?.queueTrackIDs == ["ready"]); #expect(restored?.currentIndex == 0)
        #expect(restored?.elapsedSeconds == 12)
        // Repeating the restore is stable, not progressively destructive.
        let again = try await fixture.repository.restorePlaybackState()
        #expect(again?.queueTrackIDs == ["ready"]); #expect(again?.currentIndex == 0)
    }

    @Test func testPlaybackRestoreClearsAQueueWithNoReadyTracks() async throws {
        let fixture = try Fixture()
        try await fixture.repository.upsertTrack(.init(trackID: "gone", title: "Gone"))
        let context = ModelContext(fixture.container)
        context.insert(WatchPlaybackStateModel(queueTrackIDs: ["gone"], currentIndex: 0, elapsedSeconds: 30))
        try context.save()
        let restored = try await fixture.repository.restorePlaybackState()
        #expect(restored?.queueTrackIDs == [])
        #expect(restored?.currentIndex == 0)
        #expect(restored?.elapsedSeconds == 0)
    }

    @Test func testDeterministicSeedCanRunRepeatedly() async throws {
        let fixture = try Fixture()
        try await fixture.repository.seedDeterministicFixture(); try await fixture.repository.seedDeterministicFixture()
        let trackIDs = try await fixture.repository.tracks().map(\.id)
        let playlistIDs = try await fixture.repository.playlists().map(\.id)
        #expect(trackIDs == ["fixture-track"]); #expect(playlistIDs == ["fixture-playlist"])
    }

    @Test func testAllSchemaModelsPersist() throws {
        let container = try WatchStoreBootstrap.inMemory(), context = ModelContext(container)
        context.insert(WatchDownloadJobModel(requestID: "request", trackID: "track", rootIDs: ["root"], attemptToken: "attempt"))
        context.insert(WatchDownloadRootModel(rootID: "root", kind: .playlist, sourceID: "playlist", desiredTrackIDs: ["track"]))
        context.insert(WatchPlaybackStateModel(queueTrackIDs: ["track"], currentIndex: 0))
        context.insert(WatchSyncStateModel(protocolVersion: 1, pairedLibraryIdentity: "library"))
        try context.save()
        #expect(try context.fetch(FetchDescriptor<WatchDownloadJobModel>()).first?.state == .queued)
        #expect(try context.fetch(FetchDescriptor<WatchDownloadRootModel>()).first?.kind == .playlist)
        #expect(try context.fetch(FetchDescriptor<WatchPlaybackStateModel>()).first?.queueTrackIDs == ["track"])
        #expect(try context.fetch(FetchDescriptor<WatchSyncStateModel>()).first?.pairedLibraryIdentity == "library")
    }

    @Test func testUnknownRawValuesDecodeToSafeStatesRatherThanCrashing() throws {
        let container = try WatchStoreBootstrap.inMemory(), context = ModelContext(container)
        let job = WatchDownloadJobModel(requestID: "r", trackID: "t", rootIDs: [], attemptToken: "a")
        let root = WatchDownloadRootModel(rootID: "root", kind: .track, sourceID: "s", desiredTrackIDs: [])
        let asset = WatchAssetModel(trackID: "t", relativeFilename: "t.m4a", installedBytes: 1, sha256: "x", validationState: .ready)
        context.insert(job); context.insert(root); context.insert(asset)
        job.stateRaw = "from-a-newer-build"; root.kindRaw = "from-a-newer-build"; asset.validationStateRaw = "from-a-newer-build"
        try context.save()
        #expect(job.state == .failed)
        #expect(root.kind == .track)
        // An unrecognized validation state must never read as playable.
        #expect(asset.validationState == .corrupt)
    }

    @Test func testPersistentStoreRelaunches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = root.appendingPathComponent("library.store"), audio = root.appendingPathComponent("audio")
        var first: WatchStoreBootstrapResult? = WatchStoreBootstrap.open(storeURL: store, audioDirectory: audio)
        let repository = WatchLibraryRepository(container: try #require(first?.container), audioDirectory: audio)
        try await repository.seedDeterministicFixture(); first = nil
        let second = WatchStoreBootstrap.open(storeURL: store, audioDirectory: audio)
        let reopened = WatchLibraryRepository(container: try #require(second.container), audioDirectory: audio)
        let reopenedIDs = try await reopened.tracks().map(\.id)
        #expect(second.state == .ready); #expect(reopenedIDs == ["fixture-track"])
    }

    /// A store written by a build that predates some of the current models must migrate forward
    /// through `WatchSchemaMigrationPlan` without losing the rows it already held.
    @Test func testOlderContainerMigratesForwardAndKeepsItsRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = root.appendingPathComponent("library.store"), audio = root.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)

        let oldSchema = Schema([WatchStoreMetadata.self, WatchTrackModel.self, WatchAssetModel.self])
        var old: ModelContainer? = try ModelContainer(
            for: oldSchema,
            configurations: ModelConfiguration(WatchStoreBootstrap.storeName, schema: oldSchema, url: store, cloudKitDatabase: .none))
        let oldContext = ModelContext(try #require(old))
        oldContext.insert(WatchTrackModel(trackID: "carried", title: "Carried Over", artist: "Artist"))
        oldContext.insert(WatchStoreMetadata(key: "written-by", value: "old-build"))
        try oldContext.save()
        old = nil

        let upgraded = WatchStoreBootstrap.open(storeURL: store, audioDirectory: audio)
        #expect(upgraded.state == .ready, "an additive schema change must migrate, not quarantine")
        let repository = WatchLibraryRepository(container: try #require(upgraded.container), audioDirectory: audio)
        let carried = try await repository.tracks().map(\.id)
        let writtenBy = try await repository.metadata("written-by")
        #expect(carried == ["carried"])
        #expect(writtenBy == "old-build")
        // Entities absent from the old store are usable immediately after the upgrade.
        try await repository.upsertPlaylist(.init(playlistID: "new", title: "New", trackIDs: ["carried"]))
        let playlistIDs = try await repository.playlists().map(\.id)
        #expect(playlistIDs == ["new"])
    }

    @Test func testCorruptStoreIsQuarantinedAudioPreservedAndRecoveryRepeatsSafely() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = root.appendingPathComponent("library.store"), audio = root.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        try Data("not-a-store".utf8).write(to: store)
        try Data("music".utf8).write(to: audio.appendingPathComponent("keep.m4a"))
        let recovered = WatchStoreBootstrap.open(storeURL: store, audioDirectory: audio, now: Date(timeIntervalSince1970: 1))
        #expect(recovered.state == .recovered)
        let quarantine = try #require(recovered.quarantinedStoreURL)
        #expect(recovered.recoverableFiles == [.init(relativeFilename: "keep.m4a", bytes: 5)])
        // The unreadable store is moved aside for diagnosis, not deleted.
        #expect(FileManager.default.fileExists(atPath: quarantine.appendingPathComponent("library.store").path))
        let repeated = WatchStoreBootstrap.open(storeURL: store, audioDirectory: audio)
        #expect(repeated.state == .ready)
        #expect(repeated.quarantinedStoreURL == nil)
        #expect(FileManager.default.fileExists(atPath: audio.appendingPathComponent("keep.m4a").path))
    }

    private func assertThrows(_ expected: WatchLibraryError, _ body: () async throws -> Void,
                              sourceLocation: SourceLocation = #_sourceLocation) async {
        do { try await body(); Issue.record("expected \(expected)", sourceLocation: sourceLocation) }
        catch let error as WatchLibraryError { #expect(error == expected, sourceLocation: sourceLocation) }
        catch { Issue.record("unexpected error \(error)", sourceLocation: sourceLocation) }
    }
}

private struct Fixture {
    let root: URL
    let audio: URL
    let artwork: URL
    let container: ModelContainer
    let repository: WatchLibraryRepository
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        audio = root.appendingPathComponent("audio"); try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        artwork = root.appendingPathComponent("artwork"); try FileManager.default.createDirectory(at: artwork, withIntermediateDirectories: true)
        container = try WatchStoreBootstrap.inMemory()
        repository = WatchLibraryRepository(container: container, audioDirectory: audio, artworkDirectory: artwork)
    }
    @discardableResult
    func write(_ name: String, bytes: Data) throws -> (sha256: String, bytes: Int64) {
        let url = audio.appendingPathComponent(name)
        try bytes.write(to: url)
        return try WatchFileDigest.measure(url)
    }
}
