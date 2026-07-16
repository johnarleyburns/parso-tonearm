import XCTest

@testable import TonearmCore

final class RemotePathPolicyTests: XCTestCase {

    func testNormalizesRelativePath() throws {
        let path = try RemotePathPolicy.normalize("Music/Album/01%20Song.flac")

        XCTAssertEqual(path.rawValue, "Music/Album/01 Song.flac")
        XCTAssertEqual(path.segments, ["Music", "Album", "01 Song.flac"])
    }

    func testRejectsTraversal() {
        assertRejects("Music/../Secrets/song.mp3", .traversal)
        assertRejects("%2e%2e/Secrets/song.mp3", .traversal)
    }

    func testRejectsAbsolutePaths() {
        assertRejects("/Music/song.mp3", .absolutePath)
        assertRejects("\\Music\\song.mp3", .absolutePath)
    }

    func testRejectsURLEncodedSeparators() {
        assertRejects("Music%2FSong.mp3", .encodedSeparator)
        assertRejects("Music%5CSong.mp3", .encodedSeparator)
    }

    func testRejectsEmptySegments() {
        assertRejects("Music//Song.mp3", .emptySegment)
    }

    func testFiltersNonAudioNodes() {
        let nodes = [
            RemoteNode(id: "root", title: "Root", path: "Music", kind: .directory),
            RemoteNode(id: "collection", title: "Collection", path: "Albums", kind: .collection),
            RemoteNode(id: "mp3", title: "Track", path: "Music/Track.mp3", kind: .audio),
            RemoteNode(id: "flac", title: "Track", path: "Music/Track.FLAC", kind: .audio),
            RemoteNode(id: "jpg", title: "Cover", path: "Music/cover.jpg", kind: .audio),
            RemoteNode(id: "item", title: "Remote Item", path: "remote-item", kind: .item),
        ]

        XCTAssertEqual(
            RemotePathPolicy.audioNodes(from: nodes).map(\.id),
            ["root", "collection", "mp3", "flac"]
        )
        XCTAssertThrowsError(try RemotePathPolicy.requireAudioFile(path: "cover.jpg")) { error in
            XCTAssertEqual(error as? RemotePathPolicy.Rejection, .nonAudioExtension)
        }
    }

    func testEnforcesPageCap() throws {
        let items = Array(0 ... CollectionResolver.memberCap)
        let page = RemotePathPolicy.cappedPage(items)

        XCTAssertEqual(page.items.count, CollectionResolver.memberCap)
        XCTAssertTrue(page.capHit)
        XCTAssertThrowsError(try RemotePathPolicy.enforcePageCap(items)) { error in
            XCTAssertEqual(
                error as? RemotePathPolicy.Rejection,
                .pageCapExceeded(limit: CollectionResolver.memberCap)
            )
        }
        XCTAssertEqual(
            try RemotePathPolicy.enforcePageCap(Array(items.prefix(CollectionResolver.memberCap))),
            Array(items.prefix(CollectionResolver.memberCap))
        )
    }

    private func assertRejects(_ rawPath: String, _ expected: RemotePathPolicy.Rejection) {
        XCTAssertThrowsError(try RemotePathPolicy.normalize(rawPath)) { error in
            XCTAssertEqual(error as? RemotePathPolicy.Rejection, expected)
        }
    }
}
