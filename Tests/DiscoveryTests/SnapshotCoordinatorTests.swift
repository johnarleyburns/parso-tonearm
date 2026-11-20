// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import TonearmDiscovery

/// Controlled repository stand-in: blocks until released, counts concurrency,
/// records whether the old operation saw cancellation.
private final class BlockingSource: @unchecked Sendable {
    private let lock = NSLock()
    private var gates: [CheckedContinuation<Void, Never>] = []
    private(set) var started = 0
    private(set) var concurrent = 0
    private(set) var maxConcurrent = 0
    private(set) var sawCancellation = 0
    var nextValue = 1
    var failNext = false
    var block = true

    private func begin() -> (Int, Bool, Bool) {
        lock.lock(); defer { lock.unlock() }
        started += 1; concurrent += 1; maxConcurrent = max(maxConcurrent, concurrent)
        let fail = failNext; failNext = false
        return (nextValue, block, fail)
    }
    private func park(_ c: CheckedContinuation<Void, Never>) {
        lock.lock(); gates.append(c); lock.unlock()
    }
    private func noteCancel() { lock.lock(); sawCancellation += 1; lock.unlock() }
    private func end() { lock.lock(); concurrent -= 1; lock.unlock() }

    func read() async throws -> Int {
        let (value, shouldBlock, fail) = begin()
        if shouldBlock {
            await withTaskCancellationHandler {
                await withCheckedContinuation { park($0) }
            } onCancel: {
                noteCancel()
            }
        }
        end()
        if fail { throw NSError(domain: "db", code: 1) }
        return value
    }

    func releaseAll() {
        lock.lock(); let g = gates; gates = []; lock.unlock()
        g.forEach { $0.resume() }
    }
}

@Suite struct SnapshotCoordinatorTests {
    private func make(_ src: BlockingSource, timeout: Duration = .milliseconds(80),
                      cooldown: Duration = .milliseconds(20)) -> SnapshotCoordinator<Int> {
        SnapshotCoordinator(timeout: timeout, retryCooldown: cooldown) { try await src.read() }
    }

    @Test func concurrentLoadsCoalesceIntoOneRead() async {
        let src = BlockingSource(); src.block = false
        let c = make(src)
        let results = await withTaskGroup(of: SnapshotOutcome<Int>.self) { g in
            for _ in 0..<20 { g.addTask { await c.load() } }
            return await g.reduce(into: []) { $0.append($1) }
        }
        #expect(results.allSatisfy { $0.value == 1 })
        #expect(src.maxConcurrent == 1)
        #expect(await c.inFlightReadCount == 0)
    }

    @Test func timeoutCancelsOldReadAndBoundsAdmission() async throws {
        let src = BlockingSource()
        let c = make(src)
        let first = await c.load()
        #expect(first.state == .timedOut)
        #expect(src.sawCancellation == 1)  // contained, not merely hidden
        // Repeated polling while the old read is blocked never stacks reads.
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(30))
            let o = await c.load()
            #expect(o.state == .busy || o.state == .retryingSoon)
        }
        #expect(src.started == 1)
        #expect(src.maxConcurrent == 1)
        #expect(await c.inFlightReadCount == 1)
        // Eventual old completion publishes (newest generation) and frees admission.
        src.releaseAll()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await c.inFlightReadCount == 0)
        #expect(await c.lastKnownGood?.value == 1)
    }

    @Test func lastGoodSurvivesTimeoutAndFailure() async throws {
        let src = BlockingSource(); src.block = false
        let c = make(src)
        let ok = await c.load()
        #expect(ok.state == .loaded)
        let stamp = try #require(ok.updatedAt)
        try await Task.sleep(for: .milliseconds(30))
        src.failNext = true
        let failed = await c.load()
        guard case .failed = failed.state else { Issue.record("expected failure"); return }
        #expect(failed.value == 1)
        #expect(failed.updatedAt == stamp)
        try await Task.sleep(for: .milliseconds(40))
        src.block = true
        let timedOut = await c.load()
        #expect(timedOut.state == .timedOut)
        #expect(timedOut.value == 1)
        #expect(timedOut.updatedAt == stamp)
    }

    @Test func failureIsDebouncedThenRetries() async throws {
        let src = BlockingSource(); src.block = false; src.failNext = true
        // A long cooldown makes the debounce assertion independent of how long
        // the parallel test runner takes to schedule the second call.
        let c = make(src, cooldown: .seconds(5))
        _ = await c.load()
        let debounced = await c.load()
        #expect(debounced.state == .retryingSoon)
        #expect(src.started == 1)
        // A state change clears the debounce and admits the retry immediately;
        // no wall-clock sleep is needed to prove the retry path works.
        await c.invalidate()
        #expect(await c.load().state == .loaded)
        #expect(src.started == 2)
    }

    @Test func invalidateDiscardsStaleResultAndRunsOneFreshRead() async throws {
        let src = BlockingSource()
        let c = make(src, timeout: .seconds(5))
        src.nextValue = 1
        async let first = c.load()
        try await Task.sleep(for: .milliseconds(30))
        src.nextValue = 2
        await c.invalidate()
        src.releaseAll()  // old read finishes with stale value 1
        try await Task.sleep(for: .milliseconds(30))
        src.block = false
        src.releaseAll()
        let out = await first
        #expect(out.value == 2)
        #expect(src.maxConcurrent <= 2)
        #expect(await c.lastKnownGood?.value == 2)
    }

    @Test func notBuiltEmptyValueIsPublishedAsLoaded() async {
        let c = SnapshotCoordinator<[Int]>(timeout: .seconds(1)) { [] }
        let o = await c.load()
        #expect(o.state == .loaded)
        #expect(o.value == [])
    }

    @Test func shutdownReleasesWaitersAndCancelsRead() async throws {
        let src = BlockingSource()
        let c = make(src, timeout: .seconds(5))
        async let pending = c.load()
        try await Task.sleep(for: .milliseconds(30))
        await c.shutdown()
        #expect(await pending.state == .cancelled)
        #expect(src.sawCancellation == 1)
        #expect(await c.load().state == .cancelled)
        src.releaseAll()
    }

    @Test func deinitCancelsInFlightRead() async throws {
        let src = BlockingSource()
        var c: SnapshotCoordinator<Int>? = make(src, timeout: .milliseconds(30), cooldown: .milliseconds(5))
        _ = await c?.load()  // times out; read abandoned & blocked
        c = nil
        try await Task.sleep(for: .milliseconds(30))
        #expect(src.sawCancellation >= 1)
        src.releaseAll()
    }
}
