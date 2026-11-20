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
        await waitUntil { presenter.phase == .offlineNoResults }
        #expect(presenter.phase == .offlineNoResults)
        try await repository.upsertTrack(.init(trackID: "home", title: "Home Cooking I"))
        presenter.refresh()
        await waitUntil {
            if case .offlineResults = presenter.phase { return true }
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

    /// Polls the presenter instead of assuming a fixed 50 ms is enough while
    /// 1,600 other tests compete for the machine.
    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("presenter condition not met in time")
    }

    @Test func testStartsOnRecents() {
        let presenter = makePresenter(mode: .connected, recents: .init(["ambient", "piano"]))
        #expect(presenter.phase == .recent(["ambient", "piano"]))
    }

    @Test func testShortQueryIsTooShortWhileTyping() async {
        let presenter = makePresenter(mode: .connected)
        presenter.query = "a"
        await waitUntil { presenter.phase == .tooShort }
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
        await waitUntil { presenter.phase == .results([row("t1")]) }
        #expect(presenter.phase == .results([row("t1")]))

        presenter.query = "empty"
        await waitUntil { presenter.phase == .noResults }
        #expect(presenter.phase == .noResults)
        #expect(calls.count == 2)
    }

    @Test func testConnectedFaultBecomesUnreachable() async {
        let presenter = makePresenter(mode: .connected, connected: { _, _ in .failed(.init(code: .phoneUnavailable)) })
        presenter.query = "piano"
        await waitUntil { presenter.phase == .unreachable(fallback: []) }
        #expect(presenter.phase == .unreachable(fallback: []))
    }

    @Test func testSupersededReplyDoesNotRepaint() async {
        let slowStarted = Counter()
        let slowFinished = Counter()
        let presenter = makePresenter(mode: .connected, connected: { q, gen in
            if q == "slow" {
                slowStarted.bump()
                try? await Task.sleep(for: .milliseconds(80))
                slowFinished.bump()
                return .superseded
            }
            return .results(WatchSearchResponse(generation: gen, query: q, rows: [row("fresh")]))
        })
        presenter.query = "slow"
        await waitUntil { slowStarted.count == 1 }
        presenter.query = "fresh"
        await waitUntil { presenter.phase == .results([row("fresh")]) }
        // Wait for the superseded reply to actually arrive, then assert it did
        // not repaint over the newer query.
        await waitUntil { slowFinished.count == 1 }
        #expect(presenter.phase == .results([row("fresh")]),
                       "a late superseded reply must not overwrite the newer query's results")
    }

    @Test func testOfflineModeUsesLocalSearch() async {
        let presenter = makePresenter(mode: .offline, offline: { q in q == "rain" ? [row("local1")] : [] })
        presenter.query = "rain"
        await waitUntil { presenter.phase == .offlineResults([row("local1")]) }
        #expect(presenter.phase == .offlineResults([row("local1")]))

        presenter.query = "nothing"
        await waitUntil { presenter.phase == .offlineNoResults }
        #expect(presenter.phase == .offlineNoResults)
    }

    @Test func testSubmitRecordsRecentAndRunsImmediately() async {
        let recents = WatchInMemoryRecentSearchStore()
        let presenter = makePresenter(mode: .offline, offline: { _ in [row("x")] }, recents: recents)
        presenter.submit("jazz")
        await waitUntil { presenter.phase == .offlineResults([row("x")]) }
        #expect(recents.load() == ["jazz"])
        #expect(presenter.phase == .offlineResults([row("x")]))
    }

    @Test func testModeFlipReRunsQuery() async {
        let presenter = makePresenter(
            mode: .connected,
            connected: { _, _ in .failed(.init(code: .phoneUnavailable)) },
            offline: { _ in [row("localhit")] })
        presenter.query = "piano"
        await waitUntil { presenter.phase == .unreachable(fallback: [row("localhit")]) }
        #expect(presenter.phase == .unreachable(fallback: [row("localhit")]),
                       "a phone fault falls back to the watch's downloads and says so")

        presenter.setMode(.offline)
        await waitUntil { presenter.phase == .offlineResults([row("localhit")]) }
        #expect(presenter.phase == .offlineResults([row("localhit")]))
    }

    @Test func testClearingQueryReturnsToRecents() async {
        let presenter = makePresenter(mode: .offline, offline: { _ in [row("x")] },
                                      recents: .init(["old"]))
        presenter.query = "abc"
        await waitUntil { presenter.phase == .offlineResults([row("x")]) }
        presenter.query = ""
        await waitUntil { presenter.phase == .recent(["old"]) }
        #expect(presenter.phase == .recent(["old"]))
    }
}
