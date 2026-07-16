import XCTest
@testable import TonearmCore

@MainActor
final class ShuffleRepeatTests: XCTestCase {

    private let src = Source(id: 1, kind: .iaItem, iaIdentifier: "x",
                              originalURL: nil, title: "Test Source",
                              addedAt: Date(), lastResolvedAt: nil,
                              followUpdates: false, licenseText: nil, memberCapHit: false)
    private lazy var album = Album(id: 1, sourceId: 1, title: "Album", artist: "Artist")

    private func makeTrack(_ i: Int) -> TrackRow {
        let t = Track(id: Int64(i), albumId: 1, sourceId: 1,
                      title: "Track \(i)", trackNo: i, discNo: nil,
                      durationSec: 120, codec: "MP3", sampleRate: nil,
                      bitDepthOrBitrate: nil, sortKey: "\(i)")
        let a = Asset(id: Int64(i), trackId: Int64(i), kind: .remote,
                      bookmark: nil, relPath: nil,
                      remoteURL: "https://archive.org/track\(i).mp3",
                      altRemoteURL: nil, sizeBytes: nil, unsupportedReason: nil)
        return TrackRow(track: t, album: album, source: src, asset: a)
    }

    override func tearDown() {
        AudioPlayer.shared.shuffle = false
        AudioPlayer.shared.repeatMode = .off
        super.tearDown()
    }

    // MARK: - Shuffle

    func testShuffleReordersQueue() {
        let player = AudioPlayer.shared
        let tracks = (1...10).map { makeTrack($0) }
        player.play(tracks: tracks, startAt: 0)
        let originalIds = player.queue.map { $0.id }

        player.shuffle = true
        let shuffledIds = player.queue.map { $0.id }

        XCTAssertEqual(player.index, 0)
        XCTAssertEqual(shuffledIds.count, 10)
        XCTAssertEqual(shuffledIds.first, originalIds.first, "Current track should stay first")
        XCTAssertNotEqual(originalIds, shuffledIds, "Queue should be reordered")
    }

    func testShufflePreservesCurrentTrack() {
        let player = AudioPlayer.shared
        let tracks = (1...10).map { makeTrack($0) }
        player.play(tracks: tracks, startAt: 4)
        let currentId = player.currentTrack?.id

        player.shuffle = true
        XCTAssertEqual(player.queue.first?.id, currentId)
    }

    func testShuffleOffRestoresOrder() {
        let player = AudioPlayer.shared
        let tracks = (1...10).map { makeTrack($0) }
        player.play(tracks: tracks, startAt: 2)
        let originalOrder = tracks.map { $0.id }

        player.shuffle = true
        player.shuffle = false

        let restored = player.queue.map { $0.id }
        XCTAssertEqual(restored, originalOrder)
        XCTAssertEqual(player.index, 2)
    }

    func testShuffleSingleTrackNoChange() {
        let player = AudioPlayer.shared
        let tracks = [makeTrack(1)]
        player.play(tracks: tracks, startAt: 0)
        let originalIds = player.queue.map { $0.id }

        player.shuffle = true
        XCTAssertEqual(player.queue.map { $0.id }, originalIds)
    }

    // MARK: - Repeat

    func testRepeatModeCycles() {
        let player = AudioPlayer.shared
        player.repeatMode = .off
        player.cycleRepeatMode()
        XCTAssertEqual(player.repeatMode, .all)
        player.cycleRepeatMode()
        XCTAssertEqual(player.repeatMode, .one)
        player.cycleRepeatMode()
        XCTAssertEqual(player.repeatMode, .off)
    }

    func testRepeatAllWraps() {
        let player = AudioPlayer.shared
        player.repeatMode = .all
        let tracks = [makeTrack(1), makeTrack(2), makeTrack(3)]
        player.play(tracks: tracks, startAt: 2)
        player.next()
        XCTAssertEqual(player.index, 0)
    }

    func testRepeatOneDoesNotAdvance() {
        let player = AudioPlayer.shared
        player.repeatMode = .one
        let tracks = [makeTrack(1), makeTrack(2)]
        player.play(tracks: tracks, startAt: 0)
        player.next()
        XCTAssertEqual(player.index, 0, "Index stays the same on repeat one")
    }

    func testRepeatOffStopsAtEnd() {
        let player = AudioPlayer.shared
        player.repeatMode = .off
        let tracks = [makeTrack(1), makeTrack(2)]
        player.play(tracks: tracks, startAt: 1)
        player.next()
        XCTAssertFalse(player.isPlaying)
    }
}
