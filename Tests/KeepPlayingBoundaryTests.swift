import Foundation
import Testing
@testable import TonearmCore

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

private final class DeferredKeepPlayingProvider: KeepPlayingSimilarityProviding, @unchecked Sendable {
    private let gate: AsyncGate
    private let result: KeepPlayingLookup
    private let lock = NSLock()
    private var calls = 0

    init(gate: AsyncGate, result: KeepPlayingLookup) {
        self.gate = gate
        self.result = result
    }

    private func recordCall() { lock.lock(); calls += 1; lock.unlock() }

    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }

    func continuationTrackIDs(
        after recentlyPlayed: [Int64], excluding: Set<Int64>, scope: KeepPlayingSimilarityScope, limit: Int
    ) async -> KeepPlayingLookup {
        recordCall()
        await gate.wait()
        return result
    }
}

private struct ImmediateKeepPlayingProvider: KeepPlayingSimilarityProviding {
    let result: KeepPlayingLookup
    func continuationTrackIDs(
        after recentlyPlayed: [Int64], excluding: Set<Int64>, scope: KeepPlayingSimilarityScope, limit: Int
    ) async -> KeepPlayingLookup { result }
}

extension SharedProductionSingletonTests {
    /// Terminal async continuation/resume protocol of Keep Playing. Deterministic:
    /// completions are released through an actor gate, never wall-clock sleeps.
    @MainActor
    @Suite final class KeepPlayingBoundaryTests {
        private let src = Source(id: 1, kind: .iaItem, iaIdentifier: "x",
                                 originalURL: nil, title: "Test Source",
                                 addedAt: Date(), lastResolvedAt: nil,
                                 followUpdates: false, licenseText: nil, memberCapHit: false)
        private lazy var album = Album(id: 1, sourceId: 1, title: "Album", artist: "Artist")

        private lazy var fixtureRows: [TrackRow] = (1...2).map { i in
            let t = Track(id: Int64(i), albumId: 1, sourceId: 1, title: "Track \(i)", trackNo: i, discNo: nil,
                          durationSec: 120, codec: "MP3", sampleRate: nil, bitDepthOrBitrate: nil, sortKey: "\(i)")
            let a = Asset(id: Int64(i), trackId: Int64(i), kind: .remote, bookmark: nil, relPath: nil,
                          remoteURL: "https://archive.org/track\(i).mp3", altRemoteURL: nil,
                          sizeBytes: nil, unsupportedReason: nil)
            return TrackRow(track: t, album: album, source: src, asset: a)
        }

        private func reset(_ player: AudioPlayer) {
            player.keepPlayingEnabled = false
            player.keepPlayingProvider = nil
            player.resetRestoreForTesting()
            if !player.queue.isEmpty { player.removeFromQueue(atOffsets: IndexSet(0..<player.queue.count)) }
            player.repeatMode = .off
            player.shuffle = false
        }

        init() async throws {
            PlaybackStateFileStore.fileURLOverride = FileManager.default.temporaryDirectory
                .appendingPathComponent("tonearm-boundary-\(UUID().uuidString).json")
            reset(AudioPlayer.shared)
        }

        isolated deinit {
            reset(AudioPlayer.shared)
            PlaybackStateFileStore.fileURLOverride = nil
        }

        /// Yields the main actor until `condition` holds (bounded by iterations, not time).
        private func eventually(_ condition: () -> Bool) async throws {
            for _ in 0..<10_000 {
                if condition() { return }
                await Task.yield()
            }
            Issue.record("condition never became true")
        }

        @Test func testTerminalQueueWaitResumesExactlyOnceWhenAsyncContinuationAppendsRows() async throws {
            let library = (try? await LibraryStore.shared.allTrackRows()) ?? []
            if library.isEmpty { try Test.cancel("Needs a library track to hydrate against") }
            let pick = try #require(library.first?.track.id)
            let player = AudioPlayer.shared
            let gate = AsyncGate()
            let provider = DeferredKeepPlayingProvider(gate: gate, result: .ready([pick]))
            player.keepPlayingProvider = provider
            player.keepPlayingEnabled = true
            player.play(tracks: [fixtureRows[0]], startAt: 0)

            player.next()
            #expect(player.keepPlayingBoundaryState ==
                           .waiting(queueGeneration: player.keepPlayingBoundaryGeneration, terminalIndex: 0))
            #expect(!player.isPlaying)
            await gate.open()
            try await eventually { player.queue.count >= 2 && player.index == 1 && player.isPlaying }
            #expect(player.queue[1].track.id == pick)
            #expect(player.keepPlayingBoundaryState == .idle)
            #expect(provider.callCount == 1)
        }

        @Test func testTerminalEmptyResultBecomesExplicitExhaustedStateWithoutHiddenRetryLoop() async throws {
            let player = AudioPlayer.shared
            player.keepPlayingProvider = ImmediateKeepPlayingProvider(result: .unavailable)
            player.keepPlayingEnabled = true
            player.play(tracks: [fixtureRows[0]], startAt: 0)
            player.next()
            try await eventually { player.keepPlayingBoundaryState.isExhausted && !player.keepPlayingExtensionInFlight }
            #expect(!player.isPlaying)
            #expect(player.keepPlayingFallbackReason == .unavailable)

            // A further terminal next() must not start another attempt.
            let state = player.keepPlayingBoundaryState
            player.next()
            for _ in 0..<50 { await Task.yield() }
            #expect(!player.keepPlayingExtensionInFlight)
            #expect(player.keepPlayingBoundaryState == state)
        }

        @Test func testStaleContinuationCannotResumeReplacementQueueOrDisabledKeepPlaying() async throws {
            let player = AudioPlayer.shared

            // Queue replacement.
            let gate = AsyncGate()
            player.keepPlayingProvider = DeferredKeepPlayingProvider(gate: gate, result: .ready([2]))
            player.keepPlayingEnabled = true
            player.play(tracks: [fixtureRows[0]], startAt: 0)
            player.next()
            guard case .waiting = player.keepPlayingBoundaryState else {
                Issue.record("expected waiting")
                return
            }
            player.keepPlayingEnabled = false
            player.play(tracks: [fixtureRows[1]], startAt: 0)
            #expect(player.keepPlayingBoundaryState == .idle)
            await gate.open()
            for _ in 0..<50 { await Task.yield() }
            #expect(player.queue.map(\.id) == [fixtureRows[1].id])
            #expect(player.index == 0)
            #expect(player.keepPlayingBoundaryState == .idle)

            // Keep Playing disabled while waiting.
            let gate2 = AsyncGate()
            player.keepPlayingProvider = DeferredKeepPlayingProvider(gate: gate2, result: .ready([2]))
            player.keepPlayingEnabled = true
            player.play(tracks: [fixtureRows[0]], startAt: 0)
            player.next()
            player.keepPlayingEnabled = false
            #expect(player.keepPlayingBoundaryState == .idle)
            await gate2.open()
            for _ in 0..<50 { await Task.yield() }
            #expect(player.queue.count == 1)
            #expect(player.index == 0)
            #expect(!player.isPlaying)
        }
    }
}
