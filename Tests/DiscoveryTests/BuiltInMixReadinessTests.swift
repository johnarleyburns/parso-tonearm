import XCTest
@testable import TonearmCore
@testable import TonearmDiscovery
import ParsoAudioAnalysis

/// Build a Mix on a fresh install: the bundled Mood Starter tracks must carry tempo and key, the
/// seeded analysis must reach the same store read the Build a Mix sheet uses, and the planner
/// must place them. (Real report: Generate "does nothing" — every bundled track lacked BPM/key.)
final class BuiltInMixReadinessTests: XCTestCase {
    func testBundledIndexCarriesTempoAndKeyForNearlyEveryTrack() throws {
        let tracks = BuiltInMoodIndexProvider.tracks
        XCTAssertGreaterThan(tracks.count, 1_000, "the bundled Mood Starter index should load")
        let analysed = tracks.filter(\.hasMusicalAnalysis)
        XCTAssertGreaterThanOrEqual(Double(analysed.count) / Double(tracks.count), 0.95,
                                    "\(analysed.count)/\(tracks.count) bundled tracks have BPM + key")
        for track in analysed {
            let bpm = try XCTUnwrap(track.bpm)
            XCTAssertTrue((30...300).contains(bpm), "\(track.id) bpm \(bpm)")
            XCTAssertNotNil(CamelotKey(code: track.key ?? ""), "\(track.id) key \(track.key ?? "nil")")
        }
    }

    func testSeededBundleAnalysisReachesTheMixBuilderAndPlansAMix() async throws {
        let store = try LibraryStore(inMemory: true)
        let source = try await store.insertSource(Source(
            id: nil, kind: .local, iaIdentifier: nil, originalURL: nil, title: "Mood Starter",
            addedAt: Date(), lastResolvedAt: nil, followUpdates: false, licenseText: nil,
            memberCapHit: false))
        let sourceId = try XCTUnwrap(source.id)
        let bundled = Array(BuiltInMoodIndexProvider.tracks.filter(\.hasMusicalAnalysis).prefix(40))
        XCTAssertEqual(bundled.count, 40)

        var ids: [Int64] = []
        for entry in bundled {
            let track = try await store.insertTrack(Track(
                id: nil, albumId: nil, sourceId: sourceId, title: entry.title, trackNo: nil, discNo: nil,
                durationSec: entry.durationSec, codec: "MP3", sampleRate: nil, bitDepthOrBitrate: nil,
                sortKey: entry.title.lowercased(), genre: entry.genre, composer: nil, artistId: nil))
            let trackId = try XCTUnwrap(track.id)
            let asset = try await store.insertAsset(Asset(
                id: nil, trackId: trackId, kind: .remote, bookmark: nil, relPath: nil,
                remoteURL: entry.streamURL, altRemoteURL: nil, sizeBytes: nil, unsupportedReason: nil,
                persistedArtworkURL: nil))
            try await store.seedBuiltInMusicalAnalysis(
                trackId: trackId, assetId: try XCTUnwrap(asset.id),
                analysisVersion: DiscoveryPipelineVersion.musicalAnalysis,
                bpm: entry.bpm, key: entry.key, energy: entry.energy,
                scopeSeconds: entry.analysisScopeSeconds ?? 60, completedAt: Date())
            ids.append(trackId)
        }

        // The Build a Mix sheet's read: BPM and Camelot key per track.
        let info = try await store.djLoadTrackInfo(trackIds: ids)
        XCTAssertEqual(info.count, ids.count)
        let energies = try await store.discoveryEnergies(trackIds: ids)
        let candidates = ids.map { id in
            MixCandidate(trackID: id, bpm: info[id]?.bpm, camelot: info[id]?.camelotKey,
                         energy: energies[id], duration: 200)
        }
        XCTAssertTrue(candidates.allSatisfy { $0.bpm != nil && $0.camelot != nil },
                      "seeded analysis did not reach djLoadTrackInfo")

        for shape in MixShape.allCases {
            let plan = MixPlanner.plan(MixRequest(candidates: candidates, shape: shape, targetDuration: nil,
                                                  lockedFirst: nil, seed: 7))
            XCTAssertEqual(plan.steps.count, candidates.count, "\(shape) placed \(plan.steps.count)/\(candidates.count)")
            XCTAssertEqual(Set(plan.steps.map(\.trackID)), Set(ids))
        }
        let thirtyMinutes = MixPlanner.plan(MixRequest(candidates: candidates, shape: .risingBPM,
                                                       targetDuration: 30 * 60, lockedFirst: nil, seed: 7))
        XCTAssertFalse(thirtyMinutes.steps.isEmpty)
        XCTAssertLessThan(thirtyMinutes.steps.count, candidates.count)
    }

    /// A large "All tracks" mix from bundled tracks: every analysed track is placed, quickly.
    /// The whole bundled library (3,994 tracks) plans in ~2 s in a release build; before the
    /// accelerated solve it ran for minutes and Generate looked frozen. CI runs a debug build, so
    /// this uses 1,000 tracks (the solve is quadratic) with a broad bound.
    func testLargeBundledLibraryPlansQuickly() {
        let candidates = BuiltInMoodIndexProvider.tracks.enumerated().compactMap { index, track -> MixCandidate? in
            guard track.hasMusicalAnalysis else { return nil }
            let embedding = track.quantizedVector.map { Float(Int8(bitPattern: $0)) * Float(track.scale) }
            return MixCandidate(trackID: Int64(index), bpm: track.bpm, camelot: track.key, energy: track.energy,
                                artist: track.artist, duration: track.durationSec, embedding: embedding)
        }
        .prefix(1_000).map { $0 }
        XCTAssertEqual(candidates.count, 1_000)
        let start = Date()
        let plan = MixPlanner.plan(MixRequest(candidates: candidates, shape: .warmUpPeakCoolDown, seed: 3))
        let elapsed = Date().timeIntervalSince(start)
        print("LARGE_LIBRARY_PLAN \(candidates.count) tracks in \(elapsed) s")
        XCTAssertEqual(plan.steps.count, candidates.count)
        XCTAssertTrue(plan.excluded.isEmpty)
        XCTAssertLessThan(elapsed, 15, "a large library plan should stay interactive")
    }

    /// Build a Mix offers 15, 30 and 60 minutes. From the whole bundled library each length
    /// produces a mix of about that length, and Regenerate (a new seed) gives a different one.
    func testSessionLengthsFromTheWholeLibrary() {
        let candidates = BuiltInMoodIndexProvider.tracks.enumerated().compactMap { index, track -> MixCandidate? in
            guard track.hasMusicalAnalysis else { return nil }
            return MixCandidate(trackID: Int64(index), bpm: track.bpm, camelot: track.key, energy: track.energy,
                                artist: track.artist, duration: track.durationSec)
        }
        for minutes in [15.0, 30, 60] {
            let start = Date()
            let plan = MixPlanner.plan(MixRequest(candidates: candidates, shape: .risingBPM,
                                                  targetDuration: minutes * 60, seed: 1))
            let elapsed = Date().timeIntervalSince(start)
            let length = plan.steps.compactMap { step in candidates.first { $0.trackID == step.trackID }?.duration }
                .reduce(0, +) / 60
            print("SESSION \(Int(minutes)) min → \(plan.steps.count) tracks, \(String(format: "%.1f", length)) min, \(String(format: "%.2f", elapsed)) s")
            XCTAssertFalse(plan.steps.isEmpty)
            XCTAssertLessThanOrEqual(length, minutes, "\(minutes)-minute mix ran \(length) minutes")
            XCTAssertGreaterThan(length, minutes * 0.8, "\(minutes)-minute mix was only \(length) minutes")
            let shortClips = plan.steps.filter { step in
                (candidates.first { $0.trackID == step.trackID }?.duration ?? 0) < MixPlanner.shortClipSeconds
            }
            XCTAssertTrue(shortClips.isEmpty, "\(minutes)-minute mix used \(shortClips.count) short clips")
        }
        let first = MixPlanner.plan(MixRequest(candidates: candidates, shape: .risingBPM, targetDuration: 30 * 60, seed: 1))
        let again = MixPlanner.plan(MixRequest(candidates: candidates, shape: .risingBPM, targetDuration: 30 * 60, seed: 2))
        let overlap = Set(first.steps.map(\.trackID)).intersection(again.steps.map(\.trackID)).count
        print("SESSION regenerate overlap \(overlap)/\(first.steps.count)")
        XCTAssertLessThan(overlap, first.steps.count / 2, "Regenerate should pick a different mix")
    }
}
