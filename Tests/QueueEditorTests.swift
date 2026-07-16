import XCTest

@testable import TonearmCore

@MainActor
final class QueueEditorTests: XCTestCase {

    func testMoveCurrentTrackUpdatesCurrentIndex() {
        let state = QueueEditor.State(queue: [1, 2, 3, 4], currentIndex: 2)

        let edited = QueueEditor.move(from: 2, to: 0, in: state)

        XCTAssertEqual(edited.queue, [3, 1, 2, 4])
        XCTAssertEqual(edited.currentIndex, 0)
    }

    func testMoveItemFromBelowCurrentToAboveCurrentTracksIndex() {
        let state = QueueEditor.State(queue: [1, 2, 3, 4], currentIndex: 2)

        let edited = QueueEditor.move(from: 3, to: 1, in: state)

        XCTAssertEqual(edited.queue, [1, 4, 2, 3])
        XCTAssertEqual(edited.currentIndex, 3)
    }

    func testMoveItemFromAboveCurrentToBelowCurrentTracksIndex() {
        let state = QueueEditor.State(queue: [1, 2, 3, 4], currentIndex: 2)

        let edited = QueueEditor.move(from: 0, to: 3, in: state)

        XCTAssertEqual(edited.queue, [2, 3, 4, 1])
        XCTAssertEqual(edited.currentIndex, 1)
    }

    func testMoveOntoCurrentSlotKeepsCurrentTrackSelected() {
        let state = QueueEditor.State(queue: [1, 2, 3, 4], currentIndex: 2)

        let edited = QueueEditor.move(from: 0, to: 2, in: state)

        XCTAssertEqual(edited.queue, [2, 3, 1, 4])
        XCTAssertEqual(edited.currentIndex, 1)
    }

    func testRemoveCurrentAdvancesToNextTrackWhenPossible() {
        let state = QueueEditor.State(queue: [1, 2, 3], currentIndex: 1)

        let edited = QueueEditor.remove(at: 1, in: state)

        XCTAssertEqual(edited.queue, [1, 3])
        XCTAssertEqual(edited.currentIndex, 1)
    }

    func testRemoveCurrentLastTrackFallsBackToPreviousTrack() {
        let state = QueueEditor.State(queue: [1, 2, 3], currentIndex: 2)

        let edited = QueueEditor.remove(at: 2, in: state)

        XCTAssertEqual(edited.queue, [1, 2])
        XCTAssertEqual(edited.currentIndex, 1)
    }

    func testInsertNextIntoEmptyQueueSelectsInsertedTrack() {
        let state = QueueEditor.State<Int>(queue: [], currentIndex: 7)

        let edited = QueueEditor.insertNext(42, in: state)

        XCTAssertEqual(edited.queue, [42])
        XCTAssertEqual(edited.currentIndex, 0)
    }

    func testAppendIntoEmptyQueueSelectsInsertedTrack() {
        let state = QueueEditor.State<Int>(queue: [], currentIndex: 3)

        let edited = QueueEditor.append(42, in: state)

        XCTAssertEqual(edited.queue, [42])
        XCTAssertEqual(edited.currentIndex, 0)
    }

    func testInvalidInputsNormalizeWithoutMutatingQueue() {
        let state = QueueEditor.State(queue: [1, 2], currentIndex: 99)

        XCTAssertEqual(QueueEditor.move(from: 8, to: 0, in: state),
                       QueueEditor.State(queue: [1, 2], currentIndex: 1))
        XCTAssertEqual(QueueEditor.remove(at: -1, in: state),
                       QueueEditor.State(queue: [1, 2], currentIndex: 1))
    }

    func testAudioPlayerQueueEditsDoNotResurrectRemovedTrackWhenShuffleRestores() throws {
        let player = AudioPlayer.shared
        let tracks = (1...8).map { makeTrack($0) }
        player.play(tracks: tracks, startAt: 2)
        let currentID = player.currentTrack?.id

        player.shuffle = true
        let removedID = player.queue.last?.id
        player.removeFromQueue(at: player.queue.count - 1)
        player.shuffle = false

        XCTAssertEqual(player.currentTrack?.id, currentID)
        XCTAssertFalse(player.queue.map(\.id).contains(try XCTUnwrap(removedID)))
    }

    private func makeTrack(_ id: Int) -> TrackRow {
        let source = Source(id: 1, kind: .iaItem, iaIdentifier: "x",
                            originalURL: nil, title: "Test Source",
                            addedAt: Date(), lastResolvedAt: nil,
                            followUpdates: false, licenseText: nil, memberCapHit: false)
        let album = Album(id: 1, sourceId: 1, title: "Album", artist: "Artist")
        let track = Track(id: Int64(id), albumId: 1, sourceId: 1,
                          title: "Track \(id)", trackNo: id, discNo: nil,
                          durationSec: 120, codec: "MP3", sampleRate: nil,
                          bitDepthOrBitrate: nil, sortKey: "\(id)")
        let asset = Asset(id: Int64(id), trackId: Int64(id), kind: .remote,
                          bookmark: nil, relPath: nil,
                          remoteURL: "https://archive.org/track\(id).mp3",
                          altRemoteURL: nil, sizeBytes: nil, unsupportedReason: nil)
        return TrackRow(track: track, album: album, source: source, asset: asset)
    }
}
