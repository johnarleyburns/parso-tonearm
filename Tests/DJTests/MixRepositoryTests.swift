import XCTest
import AVFoundation
@testable import TonearmDJ

/// Commit 5.12 — the mixes data layer (§41.12): the finished-mix library, the
/// §37.4 timeline reads, title/notes updates, delete (row + user-content file),
/// and the storage roll-up. Recordings are user content — never auto-evicted,
/// never silently dropped (§43.6, §46.2).
@MainActor
final class MixRepositoryTests: XCTestCase {

    func testCompletedMixesListsFinishedNewestFirstAndExcludesInProgress() async throws {
        let (store, root) = try makeStore()
        try insertMix(store, root: root, title: "Old set", duration: 60, recordedAt: daysAgo(2))
        try insertMix(store, root: root, title: "Friday set", duration: 120, recordedAt: daysAgo(1))
        try insertMix(store, root: root, title: "In progress", duration: 0,
                      recordedAt: Date(), localState: .recording)

        let mixes = try await store.completedMixes()
        XCTAssertEqual(mixes.map(\.title), ["Friday set", "Old set"],
                       "finished mixes newest-first; the in-progress journal row is not a mix yet")
    }

    func testCompletedMixesShowsACorruptRowHonestly() async throws {
        let (store, root) = try makeStore()
        try insertMix(store, root: root, title: "Lost one", duration: 0,
                      recordedAt: Date(), localState: .corrupt)
        let mixes = try await store.completedMixes()
        XCTAssertEqual(mixes.map(\.title), ["Lost one"],
                       "a corrupt row is shown, never silently dropped (§46.2)")
        XCTAssertEqual(mixes.first?.state, .corrupt)
    }

    func testMixTrackEventsReadInPositionOrder() async throws {
        let (store, root) = try makeStore()
        let mixID = try insertMix(store, root: root, title: "Friday set", duration: 120)
        try insertEvent(store, mixID: mixID, title: "First", position: 1, deck: "A")
        try insertEvent(store, mixID: mixID, title: "Second", position: 2, deck: "B")

        let events = try await store.mixTrackEvents(mixID: mixID)
        XCTAssertEqual(events.map(\.title), ["First", "Second"])
        XCTAssertEqual(events.map(\.position), [1, 2])
    }

    func testUpdateMixPersistsTitleAndNotes() async throws {
        let (store, root) = try makeStore()
        let mixID = try insertMix(store, root: root, title: "Untitled", duration: 60)
        try await store.updateMix(mixID: mixID, title: "The long one", notes: "Bass swap clean")
        let fetched = try await store.mix(mixID: mixID)
        let mix = try XCTUnwrap(fetched)
        XCTAssertEqual(mix.title, "The long one")
        XCTAssertEqual(mix.notes, "Bass swap clean")
    }

    func testMixAssetURLResolvesAndReportsAbsence() async throws {
        let (store, root) = try makeStore()
        let session = root.appendingPathComponent("mix-1", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try Data([0x00]).write(to: session.appendingPathComponent("mix.m4a"))
        let mixID = try insertMix(store, root: root, title: "With file", duration: 10,
                                  localRelPath: "mix-1/mix.m4a")

        let repository = MixRepository(store: store, mixesRoot: root)
        let url = try await repository.mixAssetURL(mixID: mixID)
        XCTAssertEqual(url, session.appendingPathComponent("mix.m4a"))

        // A row whose file is gone is absence, not corruption (§46.2).
        try FileManager.default.removeItem(at: session)
        let gone = try await repository.mixAssetURL(mixID: mixID)
        XCTAssertNil(gone)
    }

    func testDeleteMixRemovesTheRowAndTheUserContentFile() async throws {
        let (store, root) = try makeStore()
        let session = root.appendingPathComponent("mix-2", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try Data([0x01, 0x02, 0x03]).write(to: session.appendingPathComponent("mix.m4a"))
        let mixID = try insertMix(store, root: root, title: "Delete me", duration: 10,
                                  localRelPath: "mix-2/mix.m4a")
        try insertEvent(store, mixID: mixID, title: "Only", position: 1, deck: "A")

        let repository = MixRepository(store: store, mixesRoot: root)
        try await repository.deleteMix(mixID: mixID)

        let deletedFetch = try await store.mix(mixID: mixID)
        XCTAssertNil(deletedFetch, "the mix row is gone")
        let remainingEvents = try await store.mixTrackEvents(mixID: mixID)
        XCTAssertEqual(remainingEvents.count, 0,
                       "the timeline rows cascade-delete with the mix")
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.path),
                       "the recording's audio file (and its session directory) are removed with it")
    }

    func testMixStorageBytesSumsFinishedMixesOnly() async throws {
        let (store, root) = try makeStore()
        try insertMix(store, root: root, title: "One", duration: 60, sizeBytes: 40_000_000)
        try insertMix(store, root: root, title: "Two", duration: 60, sizeBytes: 60_000_000)
        try insertMix(store, root: root, title: "In flight", duration: 0, sizeBytes: 5_000_000,
                      recordedAt: Date(), localState: .recording)
        let bytes = try await store.mixStorageBytes()
        XCTAssertEqual(bytes, 100_000_000,
                       "the storage readout is the finished mixes' size — the in-progress row is not user content yet")
    }

    // MARK: - Helpers

    private func makeStore() throws -> (DJLibraryStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = try DJLibraryStore(path: tmp.appendingPathComponent("dj.sqlite"))
        return (store, tmp.appendingPathComponent("Mixes", isDirectory: true))
    }

    @discardableResult
    private func insertMix(_ store: DJLibraryStore, root: URL, title: String,
                           duration: Double, sizeBytes: Int64 = 1_000,
                           localRelPath: String? = nil, recordedAt: Date = Date(),
                           localState: MixLocalState = .complete) throws -> Int64 {
        var mix = DJMix(syncID: UUID().uuidString,
                        title: title,
                        durationSec: duration,
                        trackCount: 0,
                        format: RecordingEncoder.formatName,
                        sizeBytes: sizeBytes,
                        recordedAt: recordedAt,
                        localState: localState.rawValue)
        try store.pool.write { db in
            try mix.insert(db)
            guard let mixID = mix.id else { return }
            var asset = DJMixAsset(mixID: mixID,
                                   localRelPath: localRelPath ?? "session-\(mixID)/mix.m4a",
                                   totalBytes: sizeBytes)
            try asset.insert(db)
        }
        return mix.id!
    }

    private func insertEvent(_ store: DJLibraryStore, mixID: Int64, title: String,
                             position: Int, deck: String) throws {
        var event = DJMixTrackEvent(mixID: mixID, trackID: nil, title: title, artist: nil,
                                    deck: deck, startOffsetSec: Double(position - 1) * 60,
                                    bpmAtPlay: nil, camelotAtPlay: nil, position: position)
        try store.pool.write { db in
            try event.insert(db)
        }
    }

    private func daysAgo(_ days: Int) -> Date {
        Date(timeIntervalSinceNow: -Double(days) * 86_400)
    }
}
