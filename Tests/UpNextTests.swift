import XCTest
@testable import TonearmCore

@MainActor
final class UpNextTests: XCTestCase {

    // MARK: - Queue Source

    func testQueueSourceFromPlaylist() {
        let playlist = Playlist(id: 1, title: "Test Playlist", kind: .manual,
                                folderBookmark: nil, watch: false)
        let source = QueueSource.playlist(playlist)
        XCTAssertEqual(source.label, "From Playlist: Test Playlist")
    }

    func testQueueSourceFromSource() {
        let src = Source(id: 1, kind: .iaItem, iaIdentifier: "test",
                         originalURL: nil, title: "Beethoven",
                         addedAt: Date(), lastResolvedAt: nil,
                         followUpdates: false, licenseText: nil, memberCapHit: false)
        let source = QueueSource.source(src)
        XCTAssertEqual(source.label, "From Source: Beethoven")
    }

    func testQueueSourceLibrary() {
        XCTAssertEqual(QueueSource.library.label, "From Library")
    }

    func testQueueSourceAmbient() {
        XCTAssertEqual(QueueSource.ambient.label, "Ambient")
    }

    func testQueueSourceNone() {
        XCTAssertEqual(QueueSource.none.label, "")
    }

    // MARK: - Up Next

    func testUpNextContents() {
        let player = AudioPlayer.shared
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

        XCTAssertEqual(player.queueSource, .source(src))
        XCTAssertEqual(player.index, 2)
        XCTAssertEqual(player.queue.count, 10)
        XCTAssertEqual(player.upNextTracks.count, 7) // tracks after index 2 = 3..9 = 7
        XCTAssertEqual(player.upNextTracks.first?.track.title, "Track 4")
        XCTAssertEqual(player.upNextTracks.last?.track.title, "Track 10")
    }

    func testUpNextEmptyWhenLastTrack() {
        let player = AudioPlayer.shared
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

        XCTAssertEqual(player.upNextTracks.count, 0)
    }

    func testUpNextAfterPlayResets() {
        let player = AudioPlayer.shared
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
        XCTAssertEqual(player.upNextTracks.count, 4)

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
        XCTAssertEqual(player.upNextTracks.count, 1)
    }
}
