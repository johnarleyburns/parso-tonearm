#if !os(watchOS)
import Foundation
import Testing
@testable import TonearmCore

extension SharedProductionSingletonTests {
    /// Mandatory DJ-compatible Keep Playing policy: no preference, fixed stage order.
    @Suite struct KeepPlayingMandatoryMatchSourceTests {
        @Test func testMatchingPreferenceAndCopyAreGone() throws {
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            let forbidden = ["keepPlaying" + "MatchingTracksOnly", "Select matching" + " tracks"]
            let enumerator = FileManager.default.enumerator(
                at: repo.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)
            var checked = 0
            while let url = enumerator?.nextObject() as? URL {
                guard ["swift", "xcstrings"].contains(url.pathExtension),
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                checked += 1
                for word in forbidden { #expect(!text.contains(word), "\(word) in \(url.lastPathComponent)") }
            }
            #expect(checked > 0)
        }
    }

    @MainActor
    @Suite final class KeepPlayingMandatoryMatchTests {
        private let player = AudioPlayer.makeForTesting()

        private final class ScriptedProvider: KeepPlayingSimilarityProviding, @unchecked Sendable {
            let strict: KeepPlayingLookup
            let broader: KeepPlayingLookup
            private let lock = NSLock()
            private var _scopes: [KeepPlayingSimilarityScope] = []
            var scopes: [KeepPlayingSimilarityScope] { lock.lock(); defer { lock.unlock() }; return _scopes }
            private func record(_ scope: KeepPlayingSimilarityScope) {
                lock.lock(); _scopes.append(scope); lock.unlock()
            }
            init(strict: KeepPlayingLookup, broader: KeepPlayingLookup) {
                self.strict = strict; self.broader = broader
            }
            func continuationTrackIDs(
                after recentlyPlayed: [Int64], excluding: Set<Int64>, scope: KeepPlayingSimilarityScope,
                limit: Int
            ) async -> KeepPlayingLookup {
                record(scope)
                if case .djCompatible = scope { return strict }
                return broader
            }
        }

        private struct FixedMix: KeepPlayingMixProviding {
            let ids: [Int64]
            func mixContinuation(after trackID: Int64, excluding: Set<Int64>, limit: Int) async -> [Int64] { ids }
        }

        private func makeTrack(_ i: Int64) -> TrackRow {
            let t = Track(id: i, albumId: 1, sourceId: 1, title: "Track \(i)", trackNo: Int(i), discNo: nil,
                          durationSec: 120, codec: "MP3", sampleRate: nil, bitDepthOrBitrate: nil,
                          sortKey: "\(i)")
            let a = Asset(id: i, trackId: i, kind: .remote, bookmark: nil, relPath: nil,
                          remoteURL: "https://archive.org/track\(i).mp3", altRemoteURL: nil,
                          sizeBytes: nil, unsupportedReason: nil)
            return TrackRow(track: t, album: nil, source: nil, asset: a)
        }

        /// A deterministic in-memory Keep Playing library with analyzed picks.
        /// Using the shared `LibraryStore` here made the mix/sound-similar
        /// reasons depend on whatever rows a parallel suite had inserted (and
        /// those rows have no BPM/key, so a `.mixMatched` pick legitimately
        /// degrades to `.soundSimilar`).
        private func fixtureLibrary(picks: [Int64]) -> KeepPlayingLibrary {
            let rows = picks.map(makeTrack)
            return KeepPlayingLibrary(
                allTrackRows: { rows },
                tracksForSource: { _ in rows },
                trackRow: { id in rows.first { $0.track.id == id } },
                excludedTrackIDs: { [] },
                djLoadTrackInfo: { ids in
                    var info: [Int64: DJLoadTrackInfo] = [:]
                    for id in ids where rows.contains(where: { $0.track.id == id }) {
                        info[id] = DJLoadTrackInfo(bpm: 120, camelotKey: "8A")
                    }
                    return info
                })
        }

        private func start(provider: ScriptedProvider?, mix: KeepPlayingMixProviding? = nil) -> AudioPlayer {
            player.keepPlayingEnabled = false
            player.play(tracks: [1, 2, 3].map { makeTrack(Int64($0)) }, startAt: 2)
            player.keepPlayingEnabled = true
            player.keepPlayingProvider = provider
            player.keepPlayingMixProvider = mix
            return player
        }

        private func keepPlayingReasons(_ player: AudioPlayer) -> [KeepPlayingRecommendationReason] {
            player.queueEntries.compactMap {
                if case .keepPlaying(let r) = $0.origin { return r }
                return nil
            }
        }

        private let picks: [Int64] = [101, 102]

        @Test func testMixSequenceSkipsClapProvider() async throws {
            let provider = ScriptedProvider(strict: .ready([]), broader: .ready([]))
            let player = start(provider: provider, mix: FixedMix(ids: picks))
            player.keepPlayingLibrary = fixtureLibrary(picks: picks)
            await player.extendKeepPlayingQueueForTesting()
            #expect(provider.scopes.isEmpty)
            #expect(Set(keepPlayingReasons(player)) == [.mixMatched])
        }

        @Test func testStrictClapAppendsMixMatched() async throws {
            let provider = ScriptedProvider(strict: .ready(picks), broader: .ready([]))
            let player = start(provider: provider, mix: FixedMix(ids: []))
            player.keepPlayingLibrary = fixtureLibrary(picks: picks)
            await player.extendKeepPlayingQueueForTesting()
            #expect(provider.scopes == [.djCompatible(anchorTrackID: 3)])
            #expect(Set(keepPlayingReasons(player)) == [.mixMatched])
            #expect(!player.keepPlayingLastExtensionWasFallback)
        }

        @Test func testBroaderClapAppendsSoundSimilar() async throws {
            let provider = ScriptedProvider(strict: .unavailable, broader: .ready(picks))
            let player = start(provider: provider)
            player.keepPlayingLibrary = fixtureLibrary(picks: picks)
            await player.extendKeepPlayingQueueForTesting()
            #expect(provider.scopes == [.djCompatible(anchorTrackID: 3), .broaderSimilarity])
            #expect(Set(keepPlayingReasons(player)) == [.soundSimilar])
        }

        @Test func testModelNotReadyUsesModelUnavailableShuffleOnly() async throws {
            let provider = ScriptedProvider(strict: .waitingForModel, broader: .waitingForModel)
            let player = start(provider: provider)
            await player.extendKeepPlayingQueueForTesting()
            #expect(player.keepPlayingFallbackReason == .waitingForModel)
            #expect(keepPlayingReasons(player).allSatisfy { $0 == .modelUnavailableShuffle })
        }

        @Test func testAvailableButEmptyUsesNoMatchShuffleOnly() async throws {
            let provider = ScriptedProvider(strict: .unavailable, broader: .unavailable)
            let player = start(provider: provider)
            await player.extendKeepPlayingQueueForTesting()
            #expect(player.keepPlayingFallbackReason == .unavailable)
            #expect(keepPlayingReasons(player).allSatisfy { $0 == .noMatchShuffle })
        }
    }
}
#endif
