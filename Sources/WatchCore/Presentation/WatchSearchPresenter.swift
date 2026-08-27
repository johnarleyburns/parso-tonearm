import Foundation
import TonearmWatchProtocol

/// Drives W2 — the watch's one search surface, in both modes.
///
/// Connected: pages the phone over the §5 protocol, debounced 250 ms after the second non-whitespace
/// character (§6.1), with a generation guard so a slow reply never repaints a newer query. A fault
/// or a bounded-wait timeout becomes `.unreachable` — an actionable state, never an endless spinner.
///
/// Offline: a normalized substring match against the local SwiftData store. Every offline row is a
/// ready, validated watch asset.
///
/// The debounce sleep and both search backends are injected, so the whole state machine runs under
/// `swift test` with no simulator, no timers, and no `WCSession`.
@MainActor
public final class WatchSearchPresenter: ObservableObject {
    public enum Mode: Equatable, Sendable { case connected, offline }

    public enum Phase: Equatable, Sendable {
        /// No submittable query yet: show recent searches (may be empty).
        case recent([String])
        /// A query below the two-character floor.
        case tooShort
        case loading
        case results([WatchResultRow])
        case noResults
        /// Connected only: the phone could not be reached within the bounded wait.
        case unreachable
        case offlineResults([WatchResultRow])
        case offlineNoResults
    }

    public typealias ConnectedSearch =
        @Sendable (_ query: String, _ generation: Int) async -> WatchSearchOutcome
    public typealias OfflineSearch = @Sendable (_ query: String) async -> [WatchResultRow]

    @Published public var query: String = "" {
        didSet { if query != oldValue { queryChanged() } }
    }
    @Published public private(set) var phase: Phase
    @Published public private(set) var mode: Mode

    private let connectedSearch: ConnectedSearch
    private let offlineSearch: OfflineSearch
    private let recents: any WatchRecentSearchStoring
    private let debounce: Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    private var generation = 0
    private var runTask: Task<Void, Never>?

    public init(mode: Mode,
                connectedSearch: @escaping ConnectedSearch,
                offlineSearch: @escaping OfflineSearch,
                recents: any WatchRecentSearchStoring = WatchRecentSearchStore(),
                debounce: Duration = .milliseconds(250),
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.mode = mode
        self.connectedSearch = connectedSearch
        self.offlineSearch = offlineSearch
        self.recents = recents
        self.debounce = debounce
        self.sleep = sleep
        self.phase = .recent(recents.load())
    }

    public var recentSearches: [String] { recents.load() }

    /// Called when the connection chrome flips modes; re-runs the current query in the new mode.
    public func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        queryChanged()
    }

    /// The explicit Search affordance / a tapped recent — submit immediately, no debounce.
    public func submit(_ text: String? = nil) {
        if let text { query = text }
        recents.record(query)
        run(afterDebounce: false)
    }

    public func clearRecents() {
        recents.clear()
        if case .recent = phase { phase = .recent([]) }
    }

    // MARK: - Private

    private func queryChanged() {
        run(afterDebounce: true)
    }

    private func run(afterDebounce: Bool) {
        runTask?.cancel()
        generation += 1
        let generation = generation
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            phase = .recent(recents.load())
            return
        }
        guard WatchSearchRequest.isSubmittableWhileTyping(trimmed) || !afterDebounce else {
            phase = .tooShort
            return
        }

        phase = .loading
        let mode = mode
        runTask = Task { [weak self] in
            if afterDebounce {
                guard let self, (try? await self.sleep(self.debounce)) != nil else { return }
            }
            guard !Task.isCancelled, let self else { return }

            switch mode {
            case .connected:
                let outcome = await self.connectedSearch(trimmed, generation)
                guard !Task.isCancelled, generation == self.generation else { return }
                switch outcome {
                case .results(let response):
                    self.phase = response.rows.isEmpty ? .noResults : .results(response.rows)
                case .superseded:
                    return
                case .failed:
                    self.phase = .unreachable
                }
            case .offline:
                let rows = await self.offlineSearch(trimmed)
                guard !Task.isCancelled, generation == self.generation else { return }
                self.phase = rows.isEmpty ? .offlineNoResults : .offlineResults(rows)
            }
        }
    }
}
