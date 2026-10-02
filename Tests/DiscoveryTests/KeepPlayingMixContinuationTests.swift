import XCTest
@testable import TonearmCore
@testable import TonearmDiscovery

/// Keep Playing as an endless mix: continuations follow the mixing rules from the last track,
/// stay in its genre when they can, and never repeat excluded tracks.
final class KeepPlayingMixContinuationTests: XCTestCase {
    private func seed(_ store: LibraryStore, tracks: [(bpm: Double, key: String, genre: String)]) async throws -> [Int64] {
        let source = try await store.insertSource(Source(
            id: nil, kind: .local, iaIdentifier: nil, originalURL: nil, title: "Test", addedAt: Date(),
            lastResolvedAt: nil, followUpdates: false, licenseText: nil, memberCapHit: false))
        var ids: [Int64] = []
        for (index, spec) in tracks.enumerated() {
            let track = try await store.insertTrack(Track(
                id: nil, albumId: nil, sourceId: source.id!, title: "T\(index)", trackNo: nil, discNo: nil,
                durationSec: 200, codec: "MP3", sampleRate: nil, bitDepthOrBitrate: nil,
                sortKey: "t\(index)", genre: spec.genre, composer: nil, artistId: nil))
            let asset = try await store.insertAsset(Asset(
                id: nil, trackId: track.id!, kind: .remote, bookmark: nil, relPath: nil,
                remoteURL: "https://example.com/\(index).mp3", altRemoteURL: nil, sizeBytes: nil,
                unsupportedReason: nil, persistedArtworkURL: nil))
            try await store.seedBuiltInMusicalAnalysis(
                trackId: track.id!, assetId: asset.id!, analysisVersion: DiscoveryPipelineVersion.musicalAnalysis,
                bpm: spec.bpm, key: spec.key, energy: nil, scopeSeconds: 60, completedAt: Date())
            ids.append(track.id!)
        }
        return ids
    }

    func testContinuationFollowsTheRulesAndStaysInGenre() async throws {
        let store = try LibraryStore(inMemory: true)
        var specs: [(bpm: Double, key: String, genre: String)] = []
        for index in 0..<30 { specs.append((120 + Double(index % 5), ["8A", "9A", "8B"][index % 3], "House")) }
        for index in 0..<30 { specs.append((121 + Double(index % 3), "8A", "Techno")) }
        specs.append((60, "3B", "House"))  // incompatible: never follows a 120 BPM 8A track
        let ids = try await seed(store, tracks: specs)
        let provider = KeepPlayingMixContinuation(store: store)

        let next = await provider.mixContinuation(after: ids[0], excluding: [ids[1], ids[2]], limit: 8)
        XCTAssertEqual(next.count, 8)
        XCTAssertFalse(next.contains(ids[1]) || next.contains(ids[2]) || next.contains(ids[0]))
        XCTAssertFalse(next.contains(ids.last!))
        let byID = Dictionary(uniqueKeysWithValues: zip(ids, specs))
        var previous = byID[ids[0]]!
        for id in next {
            let spec = byID[id]!
            XCTAssertEqual(spec.genre, "House", "Keep Playing stays in the anchor's genre")
            XCTAssertTrue(MixCompatibility.standard.bpmCompatible(previous.bpm, spec.bpm))
            XCTAssertTrue(MixCompatibility.keysCompatible(previous.key, spec.key))
            previous = spec
        }
    }

    func testNothingCompatibleReturnsEmptySoKeepPlayingFallsBack() async throws {
        let store = try LibraryStore(inMemory: true)
        let ids = try await seed(store, tracks: [(120, "8A", "House"), (60, "3B", "House"), (180, "11B", "Jazz")])
        let next = await KeepPlayingMixContinuation(store: store).mixContinuation(after: ids[0], excluding: [], limit: 5)
        XCTAssertTrue(next.isEmpty)
    }
}
