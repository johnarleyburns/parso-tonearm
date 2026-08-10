import XCTest
import GRDB

@testable import TonearmDJ

final class DJRecordRoundTripTests: XCTestCase {
    private var db: DatabaseQueue!

    /// Whole-second timestamps: SQLite `datetime` stores millisecond precision,
    /// so sub-second values do not round-trip exactly.
    private func fixedDate() -> Date {
        Date(timeIntervalSince1970: 1_700_000_000)
    }

    override func setUpWithError() throws {
        db = try DatabaseQueue()
        try DJSchema.migrator().migrate(db)
    }

    func testArtistRoundTrip() throws {
        var artist = DJArtist(
            syncID: UUID().uuidString,
            name: "Orbital",
            sortName: "Orbital",
            createdAt: fixedDate()
        )
        try db.write { try artist.insert($0) }
        XCTAssertNotNil(artist.id)

        let fetched = try db.read { try DJArtist.fetchOne($0, key: artist.id) }
        XCTAssertEqual(fetched, artist)
    }

    func testAlbumRoundTrip() throws {
        var album = DJAlbum(
            syncID: UUID().uuidString,
            title: "Snivilisation",
            albumArtist: "Orbital",
            year: 1994,
            artworkID: "sniv",
            createdAt: fixedDate()
        )
        try db.write { try album.insert($0) }
        XCTAssertNotNil(album.id)

        let fetched = try db.read { try DJAlbum.fetchOne($0, key: album.id) }
        XCTAssertEqual(fetched, album)
    }

    func testTrackRoundTrip() throws {
        let now = fixedDate()
        var track = DJTrack(
            syncID: UUID().uuidString,
            albumID: nil,
            title: "Halcyon + On + On",
            durationSec: 562.0,
            codec: "flac",
            sampleRate: 44_100,
            channelCount: 2,
            contentHash: "sha256-fixture",
            sortKey: "halcyon + on + on",
            bpm: 105.2,
            camelot: "8A",
            addedAt: now,
            updatedAt: now
        )
        try db.write { try track.insert($0) }
        XCTAssertNotNil(track.id)

        let fetched = try db.read { try DJTrack.fetchOne($0, key: track.id) }
        XCTAssertEqual(fetched, track)
    }

    func testFolderRoundTrip() throws {
        var folder = DJFolder(
            syncID: UUID().uuidString,
            displayPath: "/Volumes/DJ Archive",
            bookmark: Data("bookmark-bytes".utf8),
            addedAt: fixedDate(),
            lastScanAt: fixedDate()
        )
        try db.write { try folder.insert($0) }
        XCTAssertNotNil(folder.id)

        let fetched = try db.read { try DJFolder.fetchOne($0, key: folder.id) }
        XCTAssertEqual(fetched, folder)
    }

    func testAssetRoundTrip() throws {
        let now = fixedDate()
        var track = DJTrack(
            syncID: UUID().uuidString,
            title: "Chime",
            contentHash: "sha256-fixture-2",
            sortKey: "chime",
            addedAt: now,
            updatedAt: now
        )
        try db.write { try track.insert($0) }

        var asset = DJAsset(
            trackID: track.id!,
            bookmark: Data("asset-bookmark".utf8),
            relPath: "Crimea/Chime.flac",
            sizeBytes: 12_345_678,
            fileModifiedAt: now,
            unsupportedReason: nil
        )
        try db.write { try asset.insert($0) }
        XCTAssertNotNil(asset.id)

        let fetched = try db.read { try DJAsset.fetchOne($0, key: asset.id) }
        XCTAssertEqual(fetched, asset)
    }

    func testImportEventRoundTrip() throws {
        var event = DJImportEvent(
            trackID: nil,
            kind: "discovered",
            detail: "folder scan found 3 files",
            at: fixedDate()
        )
        try db.write { try event.insert($0) }
        XCTAssertNotNil(event.id)

        let fetched = try db.read { try DJImportEvent.fetchOne($0, key: event.id) }
        XCTAssertEqual(fetched, event)
    }
}
