import Foundation
import Testing
@testable import TonearmWatchCore
import TonearmWatchProtocol

private func row(_ id: String) -> WatchResultRow {
    WatchResultRow(kind: .track, id: id, title: id)
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

@MainActor
@Suite struct WatchSearchPresenterTests {
    @Test func testTypingSearchesSyncedCatalogAndMetadataArrivalRefreshesResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WatchLibraryRepository(container: try WatchStoreBootstrap.inMemory(),
            audioDirectory: root, artworkDirectory: root)
        let presenter = makePresenter(mode: .offline, offline: { query in
            let tracks = (try? await repository.tracks(readyOnly: false)) ?? []
            let playlists = (try? await repository.playlists()) ?? []
            return WatchLocalCatalogSearch.rows(query: query, tracks: tracks, playlists: playlists,
                                                onWatchOnly: false)
        })
        presenter.query = "Home Cooking"
        await waitForPhase(presenter) { $0 == .offlineNoResults }
        #expect(presenter.phase == .offlineNoResults)
        try await repository.upsertTrack(.init(trackID: "home", title: "Home Cooking I"))
        presenter.refresh()
        await waitForPhase(presenter) {
            if case .offlineResults = $0 { return true }
            return false
        }
        guard case .offlineResults(let rows) = presenter.phase else {
            Issue.record("Typed query must refresh when catalog metadata arrives")
            return
        }
        #expect(rows.map(\.id) == ["home"])
        #expect(!rows[0].isDownloadedOnWatch, "Search All Music includes undownloaded catalog tracks")
        #expect(presenter.recentSearches.isEmpty, "Refresh is not a user submission")
    }

    private func makePresenter(
        mode: WatchSearchPresenter.Mode,
        connected: @escaping WatchSearchPresenter.ConnectedSearch = { _, _ in .failed(.init(code: .transferFailed)) },
        offline: @escaping WatchSearchPresenter.OfflineSearch = { _ in [] },
        recents: WatchInMemoryRecentSearchStore = .init()
    ) -> WatchSearchPresenter {
        WatchSearchPresenter(
            mode: mode, connectedSearch: connected, offlineSearch: offline, recents: recents,
            debounce: .zero, sleep: { _ in })
    }

    private final class Waiter: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var done = false
        func wait() async {
            await withCheckedContinuation { c in
                lock.lock()
                if done { lock.unlock(); c.resume() } else { continuation = c; lock.unlock() }
            }
        }
        func signal() {
            lock.lock()
            if done { lock.unlock(); return }
            done = true
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume()
        }
    }

    /// Waits on the presenter's own phase-change signal instead of polling from
    /// a busy loop; a watchdog still bounds a genuine failure.
    private func waitForPhase(
        _ presenter: WatchSearchPresenter,
        _ predicate: @escaping (WatchSearchPresenter.Phase) -> Bool
    ) async {
        if predicate(presenter.phase) { return }
        let waiter = Waiter()
        presenter.phaseDidChange = { phase in if predicate(phase) { waiter.signal() } }
        let watchdog = Task { try? await Task.sleep(for: .seconds(10)); waiter.signal() }
        await waiter.wait()
        watchdog.cancel()
        presenter.phaseDidChange = nil
        if !predicate(presenter.phase) { Issue.record("presenter condition not met in time") }
    }

    @Test func testStartsOnRecents() {
        let presenter = makePresenter(mode: .connected, recents: .init(["ambient", "piano"]))
        #expect(presenter.phase == .recent(["ambient", "piano"]))
    }

    @Test func testShortQueryIsTooShortWhileTyping() async {
        let presenter = makePresenter(mode: .connected)
        presenter.query = "a"
        await waitForPhase(presenter) { $0 == .tooShort }
        #expect(presenter.phase == .tooShort)
    }

    @Test func testConnectedResultsAndNoResults() async {
        let calls = Counter()
        let presenter = makePresenter(mode: .connected, connected: { q, gen in
            calls.bump()
            return .results(WatchSearchResponse(generation: gen, query: q,
                                                rows: q == "empty" ? [] : [row("t1")]))
        })
        presenter.query = "piano"
        await waitForPhase(presenter) { $0 == .results([row("t1")]) }
        #expect(presenter.phase == .results([row("t1")]))

        presenter.query = "empty"
        await waitForPhase(presenter) { $0 == .noResults }
        #expect(presenter.phase == .noResults)
        #expect(calls.count == 2)
    }

    @Test func testConnectedFaultBecomesUnreachable() async {
        let presenter = makePresenter(mode: .connected, connected: { _, _ in .failed(.init(code: .phoneUnavailable)) })
        presenter.query = "piano"
        await waitForPhase(presenter) { $0 == .unreachable(fallback: []) }
        #expect(presenter.phase == .unreachable(fallback: []))
    }

    @Test func testSupersededReplyDoesNotRepaint() async {
        let slowStarted = Waiter()
        let slowFinished = Waiter()
        let presenter = makePresenter(mode: .connected, connected: { q, gen in
            if q == "slow" {
                slowStarted.signal()
                try? await Task.sleep(for: .milliseconds(80))
                slowFinished.signal()
                return .superseded
            }
            return .results(WatchSearchResponse(generation: gen, query: q, rows: [row("fresh")]))
        })
        presenter.query = "slow"
        await slowStarted.wait()
        presenter.query = "fresh"
        await waitForPhase(presenter) { $0 == .results([row("fresh")]) }
        // Wait for the superseded reply to actually arrive, then assert it did
        // not repaint over the newer query.
        await slowFinished.wait()
        #expect(presenter.phase == .results([row("fresh")]),
                       "a late superseded reply must not overwrite the newer query's results")
    }

    @Test func testOfflineModeUsesLocalSearch() async {
        let presenter = makePresenter(mode: .offline, offline: { q in q == "rain" ? [row("local1")] : [] })
        presenter.query = "rain"
        await waitForPhase(presenter) { $0 == .offlineResults([row("local1")]) }
        #expect(presenter.phase == .offlineResults([row("local1")]))

        presenter.query = "nothing"
        await waitForPhase(presenter) { $0 == .offlineNoResults }
        #expect(presenter.phase == .offlineNoResults)
    }

    @Test func testSubmitRecordsRecentAndRunsImmediately() async {
        let recents = WatchInMemoryRecentSearchStore()
        let presenter = makePresenter(mode: .offline, offline: { _ in [row("x")] }, recents: recents)
        presenter.submit("jazz")
        await waitForPhase(presenter) { $0 == .offlineResults([row("x")]) }
        #expect(recents.load() == ["jazz"])
        #expect(presenter.phase == .offlineResults([row("x")]))
    }

    @Test func testModeFlipReRunsQuery() async {
        let presenter = makePresenter(
            mode: .connected,
            connected: { _, _ in .failed(.init(code: .phoneUnavailable)) },
            offline: { _ in [row("localhit")] })
        presenter.query = "piano"
        await waitForPhase(presenter) { $0 == .unreachable(fallback: [row("localhit")]) }
        #expect(presenter.phase == .unreachable(fallback: [row("localhit")]),
                       "a phone fault falls back to the watch's downloads and says so")

        presenter.setMode(.offline)
        await waitForPhase(presenter) { $0 == .offlineResults([row("localhit")]) }
        #expect(presenter.phase == .offlineResults([row("localhit")]))
    }

    @Test func testClearingQueryReturnsToRecents() async {
        let presenter = makePresenter(mode: .offline, offline: { _ in [row("x")] },
                                      recents: .init(["old"]))
        presenter.query = "abc"
        await waitForPhase(presenter) { $0 == .offlineResults([row("x")]) }
        presenter.query = ""
        await waitForPhase(presenter) { $0 == .recent(["old"]) }
        #expect(presenter.phase == .recent(["old"]))
    }
}
