import Testing

@testable import TonearmCore

@Suite struct RemotePathPolicyTests {

    @Test func testNormalizesRelativePath() throws {
        let path = try RemotePathPolicy.normalize("Music/Album/01%20Song.flac")

        #expect(path.rawValue == "Music/Album/01 Song.flac")
        #expect(path.segments == ["Music", "Album", "01 Song.flac"])
    }

    @Test func testRejectsTraversal() {
        assertRejects("Music/../Secrets/song.mp3", .traversal)
        assertRejects("%2e%2e/Secrets/song.mp3", .traversal)
    }

    @Test func testRejectsAbsolutePaths() {
        assertRejects("/Music/song.mp3", .absolutePath)
        assertRejects("\\Music\\song.mp3", .absolutePath)
    }

    @Test func testRejectsURLEncodedSeparators() {
        assertRejects("Music%2FSong.mp3", .encodedSeparator)
        assertRejects("Music%5CSong.mp3", .encodedSeparator)
    }

    @Test func testRejectsEmptySegments() {
        assertRejects("Music//Song.mp3", .emptySegment)
    }

    @Test func testFiltersNonAudioNodes() {
        let nodes = [
            RemoteNode(id: "root", title: "Root", path: "Music", kind: .directory),
            RemoteNode(id: "collection", title: "Collection", path: "Albums", kind: .collection),
            RemoteNode(id: "mp3", title: "Track", path: "Music/Track.mp3", kind: .audio),
            RemoteNode(id: "flac", title: "Track", path: "Music/Track.FLAC", kind: .audio),
            RemoteNode(id: "jpg", title: "Cover", path: "Music/cover.jpg", kind: .audio),
            RemoteNode(id: "item", title: "Remote Item", path: "remote-item", kind: .item),
        ]

        #expect(
            RemotePathPolicy.audioNodes(from: nodes).map(\.id) ==
            ["root", "collection", "mp3", "flac"]
        )
        do {
            _ = try RemotePathPolicy.requireAudioFile(path: "cover.jpg")
            Issue.record("expected requireAudioFile(path: \"cover.jpg\") to throw")
        } catch {
            #expect(error as? RemotePathPolicy.Rejection == .nonAudioExtension)
        }
    }

    @Test func testEnforcesPageCap() throws {
        let items = Array(0 ... CollectionResolver.memberCap)
        let page = RemotePathPolicy.cappedPage(items)

        #expect(page.items.count == CollectionResolver.memberCap)
        #expect(page.capHit)
        do {
            _ = try RemotePathPolicy.enforcePageCap(items)
            Issue.record("expected enforcePageCap(items) to throw")
        } catch {
            #expect(
                error as? RemotePathPolicy.Rejection ==
                .pageCapExceeded(limit: CollectionResolver.memberCap)
            )
        }
        #expect(
            try RemotePathPolicy.enforcePageCap(Array(items.prefix(CollectionResolver.memberCap))) ==
            Array(items.prefix(CollectionResolver.memberCap))
        )
    }

    private func assertRejects(_ rawPath: String, _ expected: RemotePathPolicy.Rejection) {
        do {
            _ = try RemotePathPolicy.normalize(rawPath)
            Issue.record("expected normalize(\"\(rawPath)\") to throw")
        } catch {
            #expect(error as? RemotePathPolicy.Rejection == expected)
        }
    }
}
