import Foundation
import Testing
@testable import TonearmCore

@MainActor
@Suite final class ShuffleRepeatTests {
    private let player = AudioPlayer()

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

    // MARK: - Shuffle

    @Test func testShuffleReordersQueue() {
        let tracks = (1...10).map { makeTrack($0) }
        player.play(tracks: tracks, startAt: 0)
        let originalIds = player.queue.map { $0.id }

        player.shuffle = true
        let shuffledIds = player.queue.map { $0.id }

        #expect(player.index == 0)
        #expect(shuffledIds.count == 10)
        #expect(shuffledIds.first == originalIds.first, "Current track should stay first")
        #expect(originalIds != shuffledIds, "Queue should be reordered")
    }

    @Test func testShufflePreservesCurrentTrack() {
        let tracks = (1...10).map { makeTrack($0) }
        player.play(tracks: tracks, startAt: 4)
        let currentId = player.currentTrack?.id

        player.shuffle = true
        #expect(player.queue.first?.id == currentId)
    }

    @Test func testShuffleOffRestoresOrder() {
        let tracks = (1...10).map { makeTrack($0) }
        player.play(tracks: tracks, startAt: 2)
        let originalOrder = tracks.map { $0.id }

        player.shuffle = true
        player.shuffle = false

        let restored = player.queue.map { $0.id }
        #expect(restored == originalOrder)
        #expect(player.index == 2)
    }

    @Test func testShuffleSingleTrackNoChange() {
        let tracks = [makeTrack(1)]
        player.play(tracks: tracks, startAt: 0)
        let originalIds = player.queue.map { $0.id }

        player.shuffle = true
        #expect(player.queue.map { $0.id } == originalIds)
    }

    // MARK: - Repeat

    @Test func testRepeatModeCycles() {
        player.repeatMode = .off
        player.cycleRepeatMode()
        #expect(player.repeatMode == .all)
        player.cycleRepeatMode()
        #expect(player.repeatMode == .one)
        player.cycleRepeatMode()
        #expect(player.repeatMode == .off)
    }

    @Test func testRepeatAllWraps() {
        player.repeatMode = .all
        let tracks = [makeTrack(1), makeTrack(2), makeTrack(3)]
        player.play(tracks: tracks, startAt: 2)
        player.next()
        #expect(player.index == 0)
    }

    @Test func testRepeatOneDoesNotAdvance() {
        player.repeatMode = .one
        let tracks = [makeTrack(1), makeTrack(2)]
        player.play(tracks: tracks, startAt: 0)
        player.next()
        #expect(player.index == 0, "Index stays the same on repeat one")
    }

    @Test func testRepeatOffStopsAtEnd() {
        player.repeatMode = .off
        let tracks = [makeTrack(1), makeTrack(2)]
        player.play(tracks: tracks, startAt: 1)
        player.next()
        #expect(!player.isPlaying)
    }
}
