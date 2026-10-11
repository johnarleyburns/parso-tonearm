import Foundation
import Network
import os
import SwiftUI
import TonearmCore
import TonearmDiscovery

/// Owns the small, visible preparation window used by Smart transitions: it
/// plans the opening blends of a queue ahead of playback with the same planner
/// the mix decks use (`BlendPreparation`), so the Mix preview and Up Next show
/// the blends that will play. It publishes every wait/failure state so there is
/// no silent background work.
@MainActor
final class TransitionPrepService: ObservableObject {
    @Published private(set) var states: [Int64: GridPrepState] = [:]
    @Published private(set) var stateSince: [Int64: Date] = [:]
    /// Bumped whenever a blend is planned, so views showing planned blends refresh.
    @Published private(set) var plannedRevision = 0

    /// Settings → "Prepare remote tracks on Wi-Fi only".
    var wifiOnly: Bool {
        UserDefaults.standard.object(forKey: "smartTransitionsWiFiOnly") as? Bool ?? true
    }
    /// A mix is useless with unprepared transitions, so preparing one may use cellular even when
    /// the Wi-Fi-only setting is on.
    private var allowsCellularForWindow = false
    private var cellularBlocked: Bool { wifiOnly && !allowsCellularForWindow }
    private var task: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private var waitingRows: [TrackRow] = []
    private var plainFadeEdges: Set<String> = []

    init() {
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.resumeWhenNetworkAllows() }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.platterhead.transition-prep-network"))
    }

    deinit { task?.cancel(); pathMonitor.cancel() }

    /// Plans the blends between consecutive `rows`, in order. `plainFadeEdges`
    /// ("fromID-toID") are edges the listener chose a plain fade for: not planned.
    func prepare(rows: [TrackRow], appState: AppState, allowsCellular: Bool = false,
                 plainFadeEdges: Set<String> = []) {
        task?.cancel()
        allowsCellularForWindow = allowsCellular
        self.plainFadeEdges = plainFadeEdges
        var seen = Set<Int64>()
        let window = rows.filter { row in
            guard let id = row.track.id else { return false }
            return seen.insert(id).inserted
        }
        waitingRows = window
        for row in window {
            if let id = row.track.id, states[id] != .ready { setState(.queued, for: id) }
        }
        run(window)
    }

    /// Build a Mix: downloads every track and plans every blend of the whole mix,
    /// in order, and returns when that is done, stopped or cancelled (the caller's
    /// task). `progress` gets each track's state as it changes, like `states`.
    func prepareAll(rows: [TrackRow], plainFadeEdges: Set<String> = [],
                    progress: @escaping @MainActor (Int64, GridPrepState) -> Void) async {
        task?.cancel()
        task = nil
        waitingRows = []
        allowsCellularForWindow = true
        self.plainFadeEdges = plainFadeEdges
        await BlendPreparation.prepare(
            rows: rows,
            gate: { [weak self] row in self?.blocker(for: row) },
            blends: { [weak self] from, to in self?.blends(from: from, to: to) ?? true },
            progress: { [weak self] id, state in
                self?.setState(state, for: id)
                if state == .ready { self?.plannedRevision += 1 }
                progress(id, state)
            })
    }

    private func run(_ window: [TrackRow]) {
        task?.cancel()
        task = Task { [weak self] in
            await BlendPreparation.prepare(
                rows: window,
                gate: { [weak self] row in self?.blocker(for: row) },
                blends: { [weak self] from, to in self?.blends(from: from, to: to) ?? true },
                progress: { [weak self] id, state in
                    self?.setState(state, for: id)
                    if state == .ready { self?.plannedRevision += 1 }
                })
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        waitingRows = []
        for (id, state) in states where state != .ready {
            setState(.cancelled, for: id)
        }
    }

    func retryFailed(rows: [TrackRow], appState: AppState) {
        prepare(rows: rows, appState: appState, plainFadeEdges: plainFadeEdges)
    }

    func transitionPrepState(for trackID: Int64) -> GridPrepState {
        states[trackID] ?? .notPrepared
    }

    func transitionPrepSince(for trackID: Int64) -> Date? {
        stateSince[trackID]
    }

    private func setState(_ state: GridPrepState, for id: Int64) {
        guard states[id] != state else { return }
        states[id] = state
        stateSince[id] = Date()
    }

    private func blends(from: TrackRow, to: TrackRow) -> Bool {
        if let fromID = from.track.id, let toID = to.track.id, plainFadeEdges.contains("\(fromID)-\(toID)") {
            return false
        }
        return !CrossfadeCurve.suppressesForGaplessAlbum(current: CrossfadeCurve.AlbumContinuity(row: from),
                                                         next: CrossfadeCurve.AlbumContinuity(row: to))
    }

    /// Why `row` can't be prepared now, said plainly in the prep list.
    private func blocker(for row: TrackRow) -> GridPrepState? {
        if row.asset?.kind == .remote {
            let path = pathMonitor.currentPath
            if path.status != .satisfied { return .waitingForNetwork }
            if cellularBlocked && path.usesInterfaceType(.cellular) { return .waitingForWiFi }
        }
        let peak = TransitionDecodeBudget.estimatedPeakBytes(
            durationSec: row.track.durationSec, sampleRate: row.track.sampleRate, fileBytes: nil)
        guard TransitionDecodeBudget.fits(estimatedPeakBytes: peak, availableBytes: Self.availableMemory()) else {
            // This track plays normally; it just gets no planned blend ahead of time.
            return .failed(String(localized: "Too long to prepare on this device"))
        }
        return nil
    }

    /// What this process can still allocate before the OS ends it (iOS), or nil where there's no
    /// such limit to respect (macOS).
    private static func availableMemory() -> Int64? {
        #if os(iOS)
        return Int64(os_proc_available_memory())
        #else
        return nil
        #endif
    }

    private func resumeWhenNetworkAllows() {
        guard !waitingRows.isEmpty,
              states.values.contains(where: { $0 == .waitingForNetwork || $0 == .waitingForWiFi }),
              pathMonitor.currentPath.status == .satisfied,
              (!cellularBlocked || !pathMonitor.currentPath.usesInterfaceType(.cellular)) else { return }
        run(waitingRows)
    }
}
