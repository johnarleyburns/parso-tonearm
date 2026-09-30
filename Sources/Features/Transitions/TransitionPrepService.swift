import Foundation
import Network
import SwiftUI
import TonearmCore
import TonearmDiscovery

/// Owns the small, visible preparation window used by Smart transitions.
/// The service intentionally publishes every wait/failure state so there is
/// no silent background work.
@MainActor
final class TransitionPrepService: ObservableObject {
    typealias Resolver = @Sendable (TrackRow, AppState) async throws -> URL
    typealias Analyzer = @Sendable (URL, String?) throws -> (payload: DJTrackPrepPayload,
                                                               frameCount: Int64)

    @Published private(set) var states: [Int64: GridPrepState] = [:]
    @Published private(set) var stateSince: [Int64: Date] = [:]
    @Published private(set) var preparedTrackIDs: Set<Int64> = []

    var wifiOnly = true
    private var task: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private let resolver: Resolver
    private let analyzer: Analyzer
    private var waitingRows: [TrackRow] = []
    private weak var waitingAppState: AppState?

    init(
        resolver: @escaping Resolver = { row, appState in
            try await appState.analysisPlayableURL(for: row)
        },
        analyzer: @escaping Analyzer = { url, codec in
            let result = try TrackGridAnalyzer.analyze(url: url, codec: codec)
            return (result.payload, result.frameCount)
        }
    ) {
        self.resolver = resolver
        self.analyzer = analyzer
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.resumeWhenNetworkAllows() }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.platterhead.transition-prep-network"))
    }

    deinit { task?.cancel(); pathMonitor.cancel() }

    func prepare(rows: [TrackRow], appState: AppState) {
        task?.cancel()
        let window = Array(rows.prefix(3))
        waitingRows = window
        waitingAppState = appState
        task = Task { [weak self] in
            for row in window {
                guard !Task.isCancelled, let id = row.track.id else { continue }
                await self?.prepare(row: row, id: id, appState: appState)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        waitingRows = []
        waitingAppState = nil
        for id in states.keys where !preparedTrackIDs.contains(id) {
            setState(.cancelled, for: id)
        }
    }

    func retryFailed(rows: [TrackRow], appState: AppState) {
        let failed = rows.filter { row in
            guard let id = row.track.id else { return false }
            if case .failed = states[id] { return true }
            return false
        }
        prepare(rows: failed, appState: appState)
    }

    func transitionPrepState(for trackID: Int64) -> GridPrepState {
        states[trackID] ?? .queued
    }

    func transitionPrepSince(for trackID: Int64) -> Date? {
        stateSince[trackID]
    }

    private func setState(_ state: GridPrepState, for id: Int64) {
        states[id] = state
        stateSince[id] = Date()
    }

    private func prepare(row: TrackRow, id: Int64, appState: AppState) async {
        if preparedTrackIDs.contains(id) { return }
        let requiresNetwork = row.asset?.kind == .remote
        if requiresNetwork {
            let path = pathMonitor.currentPath
            if path.status != .satisfied {
                setState(.waitingForNetwork, for: id)
                return
            }
            if wifiOnly && path.usesInterfaceType(.cellular) {
                setState(.waitingForWiFi, for: id)
                return
            }
        }
        if let cached = try? await appState.store.djTrackPrep(trackId: id),
            cached.analysisAlgorithm == DJTrackPrepPayload.currentAlgorithmID,
           cached.analysisPayloadVersion == DJTrackPrepPayload.currentVersion {
            preparedTrackIDs.insert(id)
            setState(.ready, for: id)
            return
        }
        setState(.queued, for: id)
        do {
            let url = try await resolver(row, appState)
            guard !Task.isCancelled else { setState(.cancelled, for: id); return }
            setState(.analyzing(0.15), for: id)
            let analyze = analyzer
            let result = try await Task.detached(priority: .utility) {
                try analyze(url, row.track.codec)
            }.value
            guard !Task.isCancelled else { setState(.cancelled, for: id); return }
            try await appState.store.saveDJAnalysis(
                result.payload.encoded(),
                meta: (result.payload.algorithmID, result.payload.version,
                       result.payload.sampleRate, result.frameCount,
                       result.payload.bpm, result.payload.key.camelot),
                trackId: id)
            preparedTrackIDs.insert(id)
            setState(.ready, for: id)
        } catch is CancellationError {
            setState(.cancelled, for: id)
        } catch {
            setState(.failed(error.localizedDescription), for: id)
        }
    }

    private func resumeWhenNetworkAllows() {
        guard !waitingRows.isEmpty,
              let waitingAppState,
              pathMonitor.currentPath.status == .satisfied,
              (!wifiOnly || !pathMonitor.currentPath.usesInterfaceType(.cellular)) else { return }
        prepare(rows: waitingRows, appState: waitingAppState)
    }
}
