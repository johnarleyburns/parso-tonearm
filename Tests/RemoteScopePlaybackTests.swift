import Foundation
import XCTest

@testable import TonearmCore

final class RemoteScopePlaybackTests: XCTestCase {

    private func audioNode(_ id: String, path: String) -> RemoteNode {
        RemoteNode(id: id, title: id, path: path, kind: .audio)
    }

    private func directoryNode(_ id: String, path: String) -> RemoteNode {
        RemoteNode(id: id, title: id, path: path, kind: .directory)
    }

    private func collectionNode(_ id: String, path: String) -> RemoteNode {
        RemoteNode(id: id, title: id, path: path, kind: .collection)
    }

    private func nodes(_ items: [(String, RemoteNode.Kind, String)]) -> [RemoteNode] {
        items.map { id, kind, path in
            RemoteNode(id: id, title: id, path: path, kind: kind)
        }
    }

    private final class FakeProvider: @unchecked Sendable, RemoteLibraryProvider {
        let sourceKind: SourceKind
        private let tree: [String: [RemoteNode]]
        private let failingPaths: Set<String>
        private(set) var browseCount = 0

        init(sourceKind: SourceKind = .subsonic,
             tree: [String: [RemoteNode]],
             failingPaths: Set<String> = []) {
            self.sourceKind = sourceKind
            self.tree = tree
            self.failingPaths = failingPaths
        }

        func browse(path: String) async throws -> [RemoteNode] {
            browseCount += 1
            if failingPaths.contains(path) { throw URLError(.badServerResponse) }
            return tree[path] ?? []
        }

        func resolve(node: RemoteNode) async throws -> ResolvedAsset {
            ResolvedAsset(url: try XCTUnwrap(URL(string: "https://example.com/\(node.id)")))
        }

        func refresh() async throws {}
    }

    func testLibraryLevelReturnsFirstAlbumOfFirstArtist() async {
        let provider = FakeProvider(tree: [
            "": [directoryNode("artistA", path: "artist/A"),
                 directoryNode("artistB", path: "artist/B")],
            "artist/A": [collectionNode("albumA1", path: "album/A1"),
                         collectionNode("albumA2", path: "album/A2")],
            "album/A1": [audioNode("t1", path: "song/1"),
                         audioNode("t2", path: "song/2")],
        ])
        let found = await RemoteScopePlayback.firstAudioNodes(in: provider, path: "")
        XCTAssertEqual(found.map(\.id), ["t1", "t2"])
    }

    func testArtistLevelReturnsFirstAlbumTracks() async {
        let provider = FakeProvider(tree: [
            "artist/A": [collectionNode("albumA1", path: "album/A1"),
                         collectionNode("albumA2", path: "album/A2")],
            "album/A1": [audioNode("t1", path: "song/1")],
            "album/A2": [audioNode("t3", path: "song/3")],
        ])
        let found = await RemoteScopePlayback.firstAudioNodes(in: provider, path: "artist/A")
        XCTAssertEqual(found.map(\.id), ["t1"])
    }

    func testAlbumLevelReturnsTracksDirectly() async {
        let provider = FakeProvider(tree: [
            "album/A2": [audioNode("t3", path: "song/3"),
                         audioNode("t4", path: "song/4")],
        ])
        let found = await RemoteScopePlayback.firstAudioNodes(in: provider, path: "album/A2")
        XCTAssertEqual(found.map(\.id), ["t3", "t4"])
    }

    func testEmptyBranchFallsThroughToNextSibling() async {
        let provider = FakeProvider(tree: [
            "": [directoryNode("artistX", path: "artist/X"),
                 directoryNode("artistB", path: "artist/B")],
            "artist/X": [collectionNode("albumX", path: "album/X")],
            "album/X": [],
            "artist/B": [collectionNode("albumB1", path: "album/B1")],
            "album/B1": [audioNode("t4", path: "song/4"),
                         audioNode("t5", path: "song/5")],
        ])
        let found = await RemoteScopePlayback.firstAudioNodes(in: provider, path: "")
        XCTAssertEqual(found.map(\.id), ["t4", "t5"])
    }

    func testFailingBrowseTreatsBranchAsEmpty() async {
        let provider = FakeProvider(
            tree: [
                "": [directoryNode("artistA", path: "artist/A"),
                     directoryNode("artistB", path: "artist/B")],
                "artist/B": [collectionNode("albumB1", path: "album/B1")],
                "album/B1": [audioNode("t4", path: "song/4")],
            ],
            failingPaths: ["artist/A"]
        )
        let found = await RemoteScopePlayback.firstAudioNodes(in: provider, path: "")
        XCTAssertEqual(found.map(\.id), ["t4"])
    }

    func testEmptyLibraryReturnsNothing() async {
        let provider = FakeProvider(tree: [:])
        let found = await RemoteScopePlayback.firstAudioNodes(in: provider, path: "")
        XCTAssertTrue(found.isEmpty)
    }

    func testCycleInPathsDoesNotHang() async {
        let provider = FakeProvider(tree: [
            "": [directoryNode("artistA", path: "artist/A")],
            "artist/A": [directoryNode("loop", path: "artist/A")],
        ])
        let found = await RemoteScopePlayback.firstAudioNodes(in: provider, path: "")
        XCTAssertTrue(found.isEmpty)
    }

    func testDepthLimitStopsDeepFolderChains() async {
        let provider = FakeProvider(tree: [
            "": [directoryNode("folder1", path: "folder/1")],
            "folder/1": [directoryNode("folder2", path: "folder/2")],
            "folder/2": [directoryNode("folder3", path: "folder/3")],
            "folder/3": [directoryNode("folder4", path: "folder/4")],
            "folder/4": [directoryNode("folder5", path: "folder/5")],
            "folder/5": [directoryNode("folder6", path: "folder/6")],
            "folder/6": [audioNode("deep", path: "song/deep")],
        ])
        let found = await RemoteScopePlayback.firstAudioNodes(in: provider, path: "")
        XCTAssertTrue(found.isEmpty, "depth beyond maxDepth must not be reached")
    }

    func testTopLevelAudioIsPlayedDirectly() async {
        let provider = FakeProvider(tree: [
            "": [audioNode("t1", path: "song/1"),
                 directoryNode("artistA", path: "artist/A")],
        ])
        let found = await RemoteScopePlayback.firstAudioNodes(in: provider, path: "")
        XCTAssertEqual(found.map(\.id), ["t1"])
    }
}
