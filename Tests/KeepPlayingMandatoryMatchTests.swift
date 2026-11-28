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

        private struct FixedMix: KeepPlayingMixProviding {
            let result: KeepPlayingMixResult
            func mixContinuation(
                after trackID: Int64, excluding: Set<Int64>, limit: Int
            ) async -> KeepPlayingMixResult { result }
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

        private let picks: [Int64] = [101, 102]

        private func start(mix: KeepPlayingMixProviding?) -> AudioPlayer {
            player.keepPlayingLibrary = fixtureLibrary(picks: picks)
            player.keepPlayingEnabled = false
            player.play(tracks: [1, 2, 3].map { makeTrack(Int64($0)) }, startAt: 2)
            player.keepPlayingEnabled = true
            player.keepPlayingMixProvider = mix
            return player
        }

        private func keepPlayingReasons(_ player: AudioPlayer) -> [KeepPlayingRecommendationReason] {
            player.queueEntries.compactMap {
                if case .keepPlaying(let r) = $0.origin { return r }
                return nil
            }
        }

        @Test func testMixSequenceAppendsMixMatched() async throws {
            let player = start(mix: FixedMix(result: .init(trackIDs: picks)))
            await player.extendKeepPlayingQueueForTesting()
            #expect(Set(keepPlayingReasons(player)) == [.mixMatched])
            #expect(!player.keepPlayingLastExtensionWasFallback)
        }

        @Test func testRelaxedMixSequenceAppendsRelaxedMixMatched() async throws {
            let player = start(mix: FixedMix(result: .init(trackIDs: picks, isRelaxed: true)))
            await player.extendKeepPlayingQueueForTesting()
            #expect(Set(keepPlayingReasons(player)) == [.relaxedMixMatched])
            #expect(!player.keepPlayingLastExtensionWasFallback)
        }

        @Test func testEmptyMixUsesNoMatchShuffleOnly() async throws {
            let player = start(mix: FixedMix(result: .empty))
            await player.extendKeepPlayingQueueForTesting()
            #expect(player.keepPlayingFallbackReason == .noCompatibleTracks)
            #expect(keepPlayingReasons(player).allSatisfy { $0 == .noMatchShuffle })
        }
    }
}
#endif
