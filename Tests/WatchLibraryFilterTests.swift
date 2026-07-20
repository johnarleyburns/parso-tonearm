import XCTest
@testable import TonearmCore

final class WatchLibraryFilterTests: XCTestCase {

    func testOnWatchTracksFiltersByFileExistence() {
        let rows = [
            TrackRow.fake(trackId: 1, relPath: "audio/t1.mp3"),
            TrackRow.fake(trackId: 2, relPath: "audio/t2.mp3"),
            TrackRow.fake(trackId: 3, relPath: nil)
        ]
        let existing: Set<String> = ["audio/t1.mp3", "audio/t2.mp3"]
        let filtered = WatchLibraryFilter.onWatchTracks(rows) { existing.contains($0) }
        XCTAssertEqual(filtered.count, 2)
        XCTAssertEqual(filtered.map(\.id), [1, 2])
    }

    func testTetheredReturnsAll() {
        let rows = [
            TrackRow.fake(trackId: 1, relPath: "a.mp3"),
            TrackRow.fake(trackId: 2, relPath: nil)
        ]
        let filtered = WatchLibraryFilter.tetheredTracks(rows)
        XCTAssertEqual(filtered.count, 2)
    }

    func testUntetheredReturnsOnlyOnWatch() {
        let rows = [
            TrackRow.fake(trackId: 1, relPath: "audio/t1.mp3"),
            TrackRow.fake(trackId: 2, relPath: nil)
        ]
        let filtered = WatchLibraryFilter.untetheredTracks(rows) { $0 == "audio/t1.mp3" }
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].id, 1)
    }

    func testCapAtLimit() {
        let rows = (0..<10_000).map { TrackRow.fake(trackId: Int64($0)) }
        let capped = WatchLibraryFilter.cap(rows, at: 5000)
        XCTAssertEqual(capped.count, 5000)
    }

    func testCapBelowLimitReturnsAll() {
        let rows = (0..<100).map { TrackRow.fake(trackId: Int64($0)) }
        let capped = WatchLibraryFilter.cap(rows, at: 5000)
        XCTAssertEqual(capped.count, 100)
    }

    func testVisiblePlaylistsFilterByManifest() {
        let playlists = [
            Playlist(id: 1, title: "Rock", kind: .manual, folderBookmark: nil, watch: false),
            Playlist(id: 2, title: "Pop", kind: .manual, folderBookmark: nil, watch: false)
        ]
        let items: [String: [String]] = [
            "Rock": ["t1", "t2"],
            "Pop": ["t3"]
        ]
        let manifest: Set<String> = ["t1"]
        let visible = WatchLibraryFilter.visiblePlaylists(
            allPlaylists: playlists, playlistItems: items, manifestKeys: manifest)
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible[0].title, "Rock")
    }
}

private extension TrackRow {
    static func fake(trackId: Int64, relPath: String? = nil) -> TrackRow {
        let asset = relPath.map { Asset(
            id: 1, trackId: trackId, kind: .managedCopy,
            bookmark: nil, relPath: $0, remoteURL: nil, altRemoteURL: nil,
            sizeBytes: 1000, unsupportedReason: nil)
        }
        return TrackRow(
            track: Track(id: trackId, albumId: nil, sourceId: 1,
                         title: "T\(trackId)", trackNo: 1, discNo: nil,
                         durationSec: 200, codec: "MP3", sampleRate: nil,
                         bitDepthOrBitrate: nil, sortKey: "T\(trackId)"),
            album: nil, source: nil, asset: asset)
    }
}
