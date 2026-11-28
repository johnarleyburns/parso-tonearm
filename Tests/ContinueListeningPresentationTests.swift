import Foundation
import Testing

@testable import TonearmCore

/// The Listen tab's "Continue your …" card must appear only for a paused,
/// resumable session that adds information beyond the mini player, and must
/// name the album/playlist it is continuing when the queue makes that knowable.
@Suite struct ContinueListeningPresentationTests {
    private func row(
        _ id: Int64, albumID: Int64? = 1, albumTitle: String? = "Album"
    ) -> TrackRow {
        let track = Track(
            id: id, albumId: albumID, sourceId: 1, title: "Track \(id)", trackNo: Int(id),
            discNo: nil, durationSec: 240, codec: "MP3", sampleRate: nil,
            bitDepthOrBitrate: nil, sortKey: "\(id)")
        let album = albumID.map { Album(id: $0, sourceId: 1, title: albumTitle ?? "Album", artist: "Artist") }
        return TrackRow(track: track, album: album, source: nil, asset: nil)
    }

    private func playlist(title: String = "Road Trip") -> Playlist {
        Playlist(
            id: 1, title: title, kind: .manual, folderBookmark: nil, watch: false)
    }

    private func source(title: String = "Cloud") -> Source {
        Source(
            id: 1, kind: .local, iaIdentifier: nil, originalURL: nil, title: title,
            addedAt: Date(), lastResolvedAt: nil, followUpdates: false,
            licenseText: nil, memberCapHit: false)
    }

    private func make(
        queue: [TrackRow], index: Int = 0, elapsed: Double = 60, duration: Double = 240,
        isPlaying: Bool = false, isAmbient: Bool = false,
        queueSource: QueueSource = .library
    ) -> ContinueListeningPresentation? {
        ContinueListeningPresentation(
            currentTrack: queue.indices.contains(index) ? queue[index] : queue.first,
            queue: queue, index: index, elapsed: elapsed, duration: duration,
            isPlaying: isPlaying, isAmbient: isAmbient, queueSource: queueSource)
    }

    @Test func testHiddenWhilePlaying() {
        #expect(make(queue: [row(1), row(2), row(3)], isPlaying: true) == nil)
    }

    @Test func testHiddenForAmbientPlayback() {
        #expect(make(queue: [row(1), row(2), row(3)], isAmbient: true) == nil)
    }

    @Test func testHiddenWhenThereIsNoTrack() {
        #expect(
            ContinueListeningPresentation(
                currentTrack: nil, queue: [], index: 0, elapsed: 60, duration: 240,
                isPlaying: false, isAmbient: false, queueSource: .none) == nil)
    }

    @Test func testShowsForAPausedQueueWithSeveralUnplayedTracks() throws {
        let p = try #require(
            make(
                queue: [
                    row(1, albumID: 1), row(2, albumID: 2), row(3, albumID: 3),
                    row(4, albumID: 4),
                ], index: 0, elapsed: 0))
        #expect(p.context == .queue)
        #expect(p.position == 1)
        #expect(p.total == 4)
        #expect(p.unplayedCount == 3)
    }

    @Test func testHiddenForASingleShortTrackAtTheStart() {
        #expect(make(queue: [row(1)], index: 0, elapsed: 5, duration: 240) == nil)
    }

    @Test func testShowsForASingleTrackWithMeaningfulProgress() throws {
        let p = try #require(make(queue: [row(1)], index: 0, elapsed: 75, duration: 240))
        #expect(p.elapsed == 75)
        #expect(p.unplayedCount == 0)
    }

    @Test func testHiddenNearTheEndOfATrack() {
        #expect(make(queue: [row(1)], index: 0, elapsed: 235, duration: 240) == nil)
    }

    @Test func testPlaylistSourceNamesThePlaylist() throws {
        let p = try #require(
            make(queue: [row(1), row(2), row(3)], queueSource: .playlist(playlist())))
        #expect(p.context == .playlist("Road Trip"))
    }

    @Test func testAlbumIsInferredWhenEveryQueuedTrackSharesIt() throws {
        let albumRows = [
            row(1, albumID: 7, albumTitle: "Abbey Road"),
            row(2, albumID: 7, albumTitle: "Abbey Road"),
            row(3, albumID: 7, albumTitle: "Abbey Road"),
        ]
        let p = try #require(make(queue: albumRows, queueSource: .library))
        #expect(p.context == .album("Abbey Road"))
    }

    @Test func testMixedAlbumQueueIsJustAQueue() throws {
        let p = try #require(
            make(queue: [row(1, albumID: 1), row(2, albumID: 2)], queueSource: .library))
        #expect(p.context == .queue)
    }

    @Test func testRestoredQueueWithNoSourceStillInfersTheAlbum() throws {
        let albumRows = [
            row(1, albumID: 9, albumTitle: "Blue"),
            row(2, albumID: 9, albumTitle: "Blue"),
        ]
        let p = try #require(make(queue: albumRows, queueSource: .none))
        #expect(p.context == .album("Blue"))
    }

    @Test func testSourceThatIsNotOneAlbumFallsBackToQueue() throws {
        let p = try #require(
            make(queue: [row(1, albumID: 1), row(2, albumID: 2)], queueSource: .source(source())))
        #expect(p.context == .queue)
    }

    @MainActor
    @Test func testContinuationQueueIsAlwaysJustAQueue() throws {
        let p = try #require(
            make(queue: [row(1, albumID: 1), row(2, albumID: 1)], queueSource: .continuation(
                FakeContinuation())))
        #expect(p.context == .queue)
    }

    @Test func testProgressTextIncludesPositionAndTime() throws {
        let p = try #require(make(queue: [row(1), row(2), row(3)], index: 1, elapsed: 62, duration: 240))
        #expect(p.progressText == "2 / 3 · 1:02 / 4:00")
    }

    @Test func testLongMixProgressUsesHours() throws {
        let p = try #require(make(queue: [row(1)], index: 0, elapsed: 3_725, duration: 7_200))
        #expect(p.progressText == "1 / 1 · 1:02:05 / 2:00:00")
    }
}

@MainActor
private final class FakeContinuation: QueueContinuationSource {
    func nextTracks(excluding: Set<Int64>, limit: Int) async -> [TrackRow] { [] }
}
