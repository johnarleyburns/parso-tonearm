import XCTest
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
final class WatchSearchPresenterTests: XCTestCase {
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

    func testStartsOnRecents() {
        let presenter = makePresenter(mode: .connected, recents: .init(["ambient", "piano"]))
        XCTAssertEqual(presenter.phase, .recent(["ambient", "piano"]))
    }

    func testShortQueryIsTooShortWhileTyping() async {
        let presenter = makePresenter(mode: .connected)
        presenter.query = "a"
        await Task.yield()
        XCTAssertEqual(presenter.phase, .tooShort)
    }

    func testConnectedResultsAndNoResults() async {
        let calls = Counter()
        let presenter = makePresenter(mode: .connected, connected: { q, gen in
            calls.bump()
            return .results(WatchSearchResponse(generation: gen, query: q,
                                                rows: q == "empty" ? [] : [row("t1")]))
        })
        presenter.query = "piano"
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(presenter.phase, .results([row("t1")]))

        presenter.query = "empty"
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(presenter.phase, .noResults)
        XCTAssertEqual(calls.count, 2)
    }

    func testConnectedFaultBecomesUnreachable() async {
        let presenter = makePresenter(mode: .connected, connected: { _, _ in .failed(.init(code: .phoneUnavailable)) })
        presenter.query = "piano"
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(presenter.phase, .unreachable)
    }

    func testSupersededReplyDoesNotRepaint() async {
        let presenter = makePresenter(mode: .connected, connected: { q, gen in
            if q == "slow" {
                try? await Task.sleep(for: .milliseconds(80))
                return .superseded
            }
            return .results(WatchSearchResponse(generation: gen, query: q, rows: [row("fresh")]))
        })
        presenter.query = "slow"
        try? await Task.sleep(for: .milliseconds(10))
        presenter.query = "fresh"
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(presenter.phase, .results([row("fresh")]),
                       "a late superseded reply must not overwrite the newer query's results")
    }

    func testOfflineModeUsesLocalSearch() async {
        let presenter = makePresenter(mode: .offline, offline: { q in q == "rain" ? [row("local1")] : [] })
        presenter.query = "rain"
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(presenter.phase, .offlineResults([row("local1")]))

        presenter.query = "nothing"
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(presenter.phase, .offlineNoResults)
    }

    func testSubmitRecordsRecentAndRunsImmediately() async {
        let recents = WatchInMemoryRecentSearchStore()
        let presenter = makePresenter(mode: .offline, offline: { _ in [row("x")] }, recents: recents)
        presenter.submit("jazz")
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(recents.load(), ["jazz"])
        XCTAssertEqual(presenter.phase, .offlineResults([row("x")]))
    }

    func testModeFlipReRunsQuery() async {
        let presenter = makePresenter(
            mode: .connected,
            connected: { _, _ in .failed(.init(code: .phoneUnavailable)) },
            offline: { _ in [row("localhit")] })
        presenter.query = "piano"
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(presenter.phase, .unreachable)

        presenter.setMode(.offline)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(presenter.phase, .offlineResults([row("localhit")]))
    }

    func testClearingQueryReturnsToRecents() async {
        let presenter = makePresenter(mode: .offline, offline: { _ in [row("x")] },
                                      recents: .init(["old"]))
        presenter.query = "abc"
        try? await Task.sleep(for: .milliseconds(50))
        presenter.query = ""
        await Task.yield()
        XCTAssertEqual(presenter.phase, .recent(["old"]))
    }
}
