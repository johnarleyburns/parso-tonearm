import Testing

@testable import TonearmCore

@Suite struct TagEditWriteBackTests {
    @Test func testAppliesTagEditPlanToLibraryRowsAndSearchIndex() async throws {
        let store = try LibraryStore(inMemory: true)
        var source = Source(
            id: nil,
            kind: .local,
            iaIdentifier: nil,
            originalURL: nil,
            title: "Local",
            addedAt: Date(),
            lastResolvedAt: nil,
            followUpdates: false,
            licenseText: nil,
            memberCapHit: false
        )
        source = try await store.insertSource(source)
        let sourceID = try #require(source.id)
        var album = Album(id: nil, sourceId: sourceID, title: "Old Album", artist: "Old Artist", year: 1999)
        album = try await store.insertAlbum(album)
        let albumID = try #require(album.id)
        var track = Track(
            id: nil,
            albumId: albumID,
            sourceId: sourceID,
            title: "Old Title",
            trackNo: 1,
            discNo: nil,
            durationSec: nil,
            codec: "MP3",
            sampleRate: nil,
            bitDepthOrBitrate: nil,
            sortKey: "0001",
            genre: "Rock",
            composer: nil
        )
        track = try await store.insertTrack(track)
        let trackID = try #require(track.id)
        _ = try await store.insertAsset(Asset(
            id: nil,
            trackId: trackID,
            kind: .localRef,
            bookmark: nil,
            relPath: "/tmp/01 Old Title.mp3",
            remoteURL: nil,
            altRemoteURL: nil,
            sizeBytes: nil,
            unsupportedReason: nil
        ))

        let operation = TagEdit.Operation(
            trackID: trackID,
            localPath: "/tmp/01 Old Title.mp3",
            changes: [
                TagEdit.Change(field: .title, before: .text("Old Title"), after: .text("New Title")),
                TagEdit.Change(field: .genre, before: .text("Rock"), after: .text("Soul")),
                TagEdit.Change(field: .composer, before: nil, after: .text("Writer")),
                TagEdit.Change(field: .trackNumber, before: .integer(1), after: .integer(7)),
                TagEdit.Change(field: .albumTitle, before: .text("Old Album"), after: .text("New Album")),
                TagEdit.Change(field: .year, before: .integer(1999), after: .integer(2026)),
            ]
        )
        let plan = TagEdit.Plan(operations: [operation], undoOperations: [], issues: [])

        let applied = try await store.applyTagEditPlan(plan)
        let loadedRow = try await store.trackRow(id: trackID)
        let row = try #require(loadedRow)
        let search = try await store.search("Soul")

        #expect(applied == 1)
        #expect(row.track.title == "New Title")
        #expect(row.track.genre == "Soul")
        #expect(row.track.composer == "Writer")
        #expect(row.track.trackNo == 7)
        #expect(row.track.sortKey == "0007")
        #expect(row.album?.title == "New Album")
        #expect(row.album?.year == 2026)
        #expect(search.map(\.id) == [trackID])
    }

    @Test func testRefusesPlanWithValidationErrors() async throws {
        let store = try LibraryStore(inMemory: true)
        let operation = TagEdit.Operation(
            trackID: 999,
            localPath: "/tmp/missing.mp3",
            changes: [TagEdit.Change(field: .title, before: .text("A"), after: .text("B"))]
        )
        let plan = TagEdit.Plan(
            operations: [operation],
            undoOperations: [],
            issues: [.readOnly(trackID: 999, reason: "Remote")]
        )

        let applied = try await store.applyTagEditPlan(plan)

        #expect(applied == 0)
    }
}
