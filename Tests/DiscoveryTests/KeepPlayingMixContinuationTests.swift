import Foundation
import Testing
@testable import TonearmCore
@testable import TonearmDiscovery

/// Keep Playing as an endless mix: continuations follow the mixing rules from the last track,
/// stay in its genre when they can, and never repeat excluded tracks.
@Suite struct KeepPlayingMixContinuationTests {
    private func seed(_ store: LibraryStore, tracks: [(bpm: Double, key: String, genre: String, energy: Double?)]) async throws -> [Int64] {
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
                bpm: spec.bpm, key: spec.key, energy: spec.energy, scopeSeconds: 60, completedAt: Date())
            ids.append(track.id!)
        }
        return ids
    }

    @Test func testContinuationFollowsTheRulesAndStaysInGenre() async throws {
        let store = try LibraryStore(inMemory: true)
        var specs: [(bpm: Double, key: String, genre: String, energy: Double?)] = []
        for index in 0..<30 { specs.append((120 + Double(index % 5), ["8A", "9A", "8B"][index % 3], "House", 5)) }
        for index in 0..<30 { specs.append((121 + Double(index % 3), "8A", "Techno", 6)) }
        specs.append((60, "3B", "House", 1))  // incompatible: never follows a 120 BPM 8A track
        let ids = try await seed(store, tracks: specs)
        let provider = KeepPlayingMixContinuation(store: store)

        let result = await provider.mixContinuation(after: ids[0], excluding: [ids[1], ids[2]], limit: 8)
        #expect(!result.isRelaxed)
        let next = result.trackIDs
        #expect(next.count == 8)
        #expect(!(next.contains(ids[1]) || next.contains(ids[2]) || next.contains(ids[0])))
        #expect(!next.contains(ids.last!))
        let byID = Dictionary(uniqueKeysWithValues: zip(ids, specs))
        var previous = byID[ids[0]]!
        for id in next {
            let spec = byID[id]!
            #expect(spec.genre == "House", "Keep Playing stays in the anchor's genre")
            #expect(MixCompatibility.standard.bpmCompatible(previous.bpm, spec.bpm))
            #expect(MixCompatibility.keysCompatible(previous.key, spec.key))
            previous = spec
        }
    }

    @Test func testNothingStrictReturnsNearestAnalysedTracksInsteadOfEmpty() async throws {
        let store = try LibraryStore(inMemory: true)
        let ids = try await seed(store, tracks: [
            (120, "8A", "House", 5), (110, "3B", "House", 5), (180, "11B", "Jazz", 5),
        ])
        let result = await KeepPlayingMixContinuation(store: store).mixContinuation(
            after: ids[0], excluding: [], limit: 5)
        #expect(result.isRelaxed)
        #expect(result.trackIDs.first == ids[1], "the nearest BPM/key track wins over a random shuffle")
        #expect(!result.trackIDs.contains(ids[0]))
    }

    @Test func testRelaxedFallbackOrdersByEnergyWhenBPMAndKeyAreEqual() async throws {
        let store = try LibraryStore(inMemory: true)
        let ids = try await seed(store, tracks: [
            (120, "8A", "House", 5),   // anchor
            (120, "1A", "House", 9),   // same tempo, incompatible key, far energy
            (120, "2A", "House", 5),   // same tempo, incompatible key, matching energy
        ])
        let result = await KeepPlayingMixContinuation(store: store).mixContinuation(
            after: ids[0], excluding: [], limit: 5)
        #expect(result.isRelaxed)
        #expect(result.trackIDs.first == ids[2], "energy closeness breaks the BPM/key tie")
    }
}
