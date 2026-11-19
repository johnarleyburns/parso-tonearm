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
        private let player = AudioPlayer()

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

        private func makeTrack(_ i: Int) -> TrackRow {
            let t = Track(id: Int64(i), albumId: 1, sourceId: 1, title: "Track \(i)", trackNo: i, discNo: nil,
                          durationSec: 120, codec: "MP3", sampleRate: nil, bitDepthOrBitrate: nil,
                          sortKey: "\(i)")
            let a = Asset(id: Int64(i), trackId: Int64(i), kind: .remote, bookmark: nil, relPath: nil,
                          remoteURL: "https://archive.org/track\(i).mp3", altRemoteURL: nil,
                          sizeBytes: nil, unsupportedReason: nil)
            return TrackRow(track: t, album: nil, source: nil, asset: a)
        }

        private func start(provider: ScriptedProvider?, mix: KeepPlayingMixProviding? = nil) -> AudioPlayer {
            player.keepPlayingEnabled = false
            player.play(tracks: (1...3).map(makeTrack), startAt: 2)
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

        private func realIDs() async throws -> [Int64] {
            let ids = (try? await LibraryStore.shared.allTrackRows())?.compactMap { $0.track.id } ?? []
            if ids.count < 2 { try Test.cancel("Needs library tracks to hydrate against") }
            return Array(ids.prefix(2))
        }

        @Test func testMixSequenceSkipsClapProvider() async throws {
            let picks = try await realIDs()
            let provider = ScriptedProvider(strict: .ready([]), broader: .ready([]))
            let player = start(provider: provider, mix: FixedMix(ids: picks))
            await player.extendKeepPlayingQueueForTesting()
            #expect(provider.scopes.isEmpty)
            #expect(Set(keepPlayingReasons(player)) == [.mixMatched])
        }

        @Test func testStrictClapAppendsMixMatched() async throws {
            let picks = try await realIDs()
            let provider = ScriptedProvider(strict: .ready(picks), broader: .ready([]))
            let player = start(provider: provider, mix: FixedMix(ids: []))
            await player.extendKeepPlayingQueueForTesting()
            #expect(provider.scopes == [.djCompatible(anchorTrackID: 3)])
            #expect(Set(keepPlayingReasons(player)) == [.mixMatched])
            #expect(!player.keepPlayingLastExtensionWasFallback)
        }

        @Test func testBroaderClapAppendsSoundSimilar() async throws {
            let picks = try await realIDs()
            let provider = ScriptedProvider(strict: .unavailable, broader: .ready(picks))
            let player = start(provider: provider)
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
