import Foundation
import Testing
@testable import TonearmCore

@MainActor
@Suite struct UpNextTests {

    // MARK: - Queue Source

    @Test func testQueueSourceFromPlaylist() {
        let playlist = Playlist(id: 1, title: "Test Playlist", kind: .manual,
                                folderBookmark: nil, watch: false)
        let source = QueueSource.playlist(playlist)
        #expect(source.label == "From Playlist: Test Playlist")
    }

    @Test func testQueueSourceFromSource() {
        let src = Source(id: 1, kind: .iaItem, iaIdentifier: "test",
                         originalURL: nil, title: "Beethoven",
                         addedAt: Date(), lastResolvedAt: nil,
                         followUpdates: false, licenseText: nil, memberCapHit: false)
        let source = QueueSource.source(src)
        #expect(source.label == "From Library: Beethoven")
    }

    @Test func testQueueSourceLibrary() {
        #expect(QueueSource.library.label == "From Music")
    }

    @Test func testQueueSourceAmbient() {
        #expect(QueueSource.ambient.label == "Ambient")
    }

    @Test func testQueueSourceNone() {
        #expect(QueueSource.none.label == "")
    }

    // MARK: - Up Next

    @Test func testUpNextContents() {
        let player = AudioPlayer()
        let src = Source(id: 1, kind: .iaItem, iaIdentifier: "x",
                         originalURL: nil, title: "Test Source",
                         addedAt: Date(), lastResolvedAt: nil,
                         followUpdates: false, licenseText: nil, memberCapHit: false)
        let album = Album(id: 1, sourceId: 1, title: "Album", artist: "Artist")

        let tracks: [TrackRow] = (1...10).map { i in
            let t = Track(id: Int64(i), albumId: 1, sourceId: 1,
                          title: "Track \(i)", trackNo: i, discNo: nil,
                          durationSec: 120, codec: "MP3", sampleRate: nil,
                          bitDepthOrBitrate: nil, sortKey: "\(i)")
            let a = Asset(id: Int64(i), trackId: Int64(i), kind: .remote,
                          bookmark: nil, relPath: nil,
                          remoteURL: "https://archive.org/download/test/track\(i).mp3",
                          altRemoteURL: nil, sizeBytes: nil, unsupportedReason: nil)
            return TrackRow(track: t, album: album, source: src, asset: a)
        }

        player.play(tracks: tracks, startAt: 2, source: .source(src))

        #expect(player.queueSource == .source(src))
        #expect(player.index == 2)
        #expect(player.queue.count == 10)
        #expect(player.upNextTracks.count == 7) // tracks after index 2 = 3..9 = 7
        #expect(player.upNextTracks.first?.track.title == "Track 4")
        #expect(player.upNextTracks.last?.track.title == "Track 10")
    }

    @Test func testUpNextEmptyWhenLastTrack() {
        let player = AudioPlayer()
        let src = Source(id: 1, kind: .iaItem, iaIdentifier: "x",
                         originalURL: nil, title: "Test",
                         addedAt: Date(), lastResolvedAt: nil,
                         followUpdates: false, licenseText: nil, memberCapHit: false)
        let album = Album(id: 1, sourceId: 1, title: "A", artist: "B")
        let t = Track(id: 1, albumId: 1, sourceId: 1, title: "Only",
                      trackNo: 1, discNo: nil, durationSec: 60, codec: "MP3",
                      sampleRate: nil, bitDepthOrBitrate: nil, sortKey: "1")
        let a = Asset(id: 1, trackId: 1, kind: .remote, bookmark: nil,
                      relPath: nil, remoteURL: "https://archive.org/test.mp3",
                      altRemoteURL: nil, sizeBytes: nil, unsupportedReason: nil)
        let row = TrackRow(track: t, album: album, source: src, asset: a)

        player.play(tracks: [row], startAt: 0)

        #expect(player.upNextTracks.count == 0)
    }

    @Test func testUpNextAfterPlayResets() {
        let player = AudioPlayer()
        let src = Source(id: 1, kind: .iaItem, iaIdentifier: "x",
                         originalURL: nil, title: "Test",
                         addedAt: Date(), lastResolvedAt: nil,
                         followUpdates: false, licenseText: nil, memberCapHit: false)
        let album = Album(id: 1, sourceId: 1, title: "A", artist: "B")

        let tracks1: [TrackRow] = (1...5).map { i in
            let t = Track(id: Int64(i), albumId: 1, sourceId: 1,
                          title: "A\(i)", trackNo: i, discNo: nil,
                          durationSec: 60, codec: "MP3", sampleRate: nil,
                          bitDepthOrBitrate: nil, sortKey: "\(i)")
            let a = Asset(id: Int64(i), trackId: Int64(i), kind: .remote,
                          bookmark: nil, relPath: nil,
                          remoteURL: "https://archive.org/a\(i).mp3",
                          altRemoteURL: nil, sizeBytes: nil, unsupportedReason: nil)
            return TrackRow(track: t, album: album, source: src, asset: a)
        }

        player.play(tracks: tracks1, startAt: 0)
        #expect(player.upNextTracks.count == 4)

        let tracks2: [TrackRow] = (1...3).map { i in
            let t = Track(id: Int64(i + 10), albumId: 1, sourceId: 1,
                          title: "B\(i)", trackNo: i, discNo: nil,
                          durationSec: 60, codec: "MP3", sampleRate: nil,
                          bitDepthOrBitrate: nil, sortKey: "\(i)")
            let a = Asset(id: Int64(i + 10), trackId: Int64(i + 10),
                          kind: .remote, bookmark: nil, relPath: nil,
                          remoteURL: "https://archive.org/b\(i).mp3",
                          altRemoteURL: nil, sizeBytes: nil, unsupportedReason: nil)
            return TrackRow(track: t, album: album, source: src, asset: a)
        }

        player.play(tracks: tracks2, startAt: 1)
        #expect(player.upNextTracks.count == 1)
    }

    // MARK: - Direct library play

    private func libraryRows(_ prefix: String, _ ids: ClosedRange<Int>) -> [TrackRow] {
        let src = Source(id: 1, kind: .iaItem, iaIdentifier: "x", originalURL: nil, title: "T",
                         addedAt: Date(), lastResolvedAt: nil, followUpdates: false,
                         licenseText: nil, memberCapHit: false)
        let album = Album(id: 1, sourceId: 1, title: "A", artist: "B")
        return ids.map { i in
            let t = Track(id: Int64(i), albumId: 1, sourceId: 1, title: "\(prefix)\(i)", trackNo: i,
                          discNo: nil, durationSec: 60, codec: "MP3", sampleRate: nil,
                          bitDepthOrBitrate: nil, sortKey: "\(i)")
            let a = Asset(id: Int64(i), trackId: Int64(i), kind: .remote, bookmark: nil, relPath: nil,
                          remoteURL: "https://archive.org/\(prefix)\(i).mp3", altRemoteURL: nil,
                          sizeBytes: nil, unsupportedReason: nil)
            return TrackRow(track: t, album: album, source: src, asset: a)
        }
    }

    @Test func testDirectLibraryPlayReplacesQueueAndNotifiesOnce() {
        let player = AudioPlayer()
        player.play(tracks: libraryRows("Old", 1...5), startAt: 2)
        let results = libraryRows("New", 20...24)
        var messages: [String] = []

        player.playLibraryResult(results, startAt: 1) { messages.append($0) }

        #expect(player.queue.map(\.id) == results.map(\.id))
        #expect(player.index == 1)
        #expect(player.queueSource == .library)
        #expect(player.upNextTracks.map(\.track.title) == ["New22", "New23", "New24"])
        #expect(messages == ["Queue updated with New21"])
        #expect(AudioPlayer.queueReplacedToastTag == "playback.queue-replaced")
    }

    @Test func testDirectLibraryPlayWithEmptyQueueDoesNotNotify() {
        let player = AudioPlayer()
        player.play(tracks: [], startAt: 0)
        #expect(player.queue.isEmpty)
        var messages: [String] = []
        player.playLibraryResult(libraryRows("New", 20...22), startAt: 0) { messages.append($0) }
        #expect(messages.isEmpty)
    }
}
