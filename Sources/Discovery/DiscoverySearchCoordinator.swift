#if !os(watchOS)
import Foundation

/// Wraps `SearchService` with the input-side contract from plan §9: a 250 ms
/// debounce, a monotonic generation guard so a slow earlier response cannot
/// overwrite a newer one, and cooperative cancellation of the superseded
/// query (its in-flight `SearchService.search` is told to stop at the next
/// scan block / inference boundary, and its result is discarded).
///
/// Portable and UI-agnostic: a SwiftUI view model observes `latest` /
/// `deliver`, this type owns only scheduling.
public actor DiscoverySearchCoordinator {
    public static let debounceInterval: Duration = .milliseconds(250)

    private let service: SearchService
    private let debounce: Duration

    private var generation: Int64 = 0
    private var currentTask: Task<Void, Never>?
    /// Set true when a generation is superseded — its `isCancelled` closure
    /// reads this via a captured box.
    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    }
    private var currentFlag: CancelFlag?

    public init(service: SearchService, debounce: Duration = DiscoverySearchCoordinator.debounceInterval) {
        self.service = service
        self.debounce = debounce
    }

    /// Submit a query. `deliver` is invoked at most once, and only if this
    /// submission is still the newest when its result arrives. A superseded
    /// submission never calls `deliver` and never leaves an obsolete snapshot.
    @discardableResult
    public func submit(
        _ query: DiscoverySearchQuery,
        referenceTrackID: Int64? = nil,
        matchingReferenceTrackID: Int64? = nil,
        matchingTracksOnly: Bool = false,
        deliver: @escaping @Sendable (DiscoverySearchResponse) -> Void
    ) -> Int64 {
        generation += 1
        let myGeneration = generation

        currentFlag?.cancel()
        currentTask?.cancel()

        let flag = CancelFlag()
        currentFlag = flag
        let service = self.service
        let debounce = self.debounce

        currentTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            if flag.isCancelled || Task.isCancelled { return }
            let response = await service.search(
                query, referenceTrackID: referenceTrackID,
                matchingReferenceTrackID: matchingReferenceTrackID,
                matchingTracksOnly: matchingTracksOnly,
                isCancelled: { flag.isCancelled || Task.isCancelled })
            guard let self else { return }
            let isCurrent = await self.isCurrent(myGeneration)
            guard isCurrent, !flag.isCancelled, response.state != .cancelled else { return }
            deliver(response)
        }
        return myGeneration
    }

    /// Cancel any in-flight query without submitting a new one.
    public func cancelPending() {
        currentFlag?.cancel()
        currentTask?.cancel()
        currentFlag = nil
        currentTask = nil
    }

    private func isCurrent(_ g: Int64) -> Bool { g == generation }
}
#endif
