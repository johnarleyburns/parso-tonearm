import Foundation
import Network
import os
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

    /// Settings → "Prepare remote tracks on Wi-Fi only" (it used to be a separate flag the
    /// switch never reached).
    var wifiOnly: Bool {
        UserDefaults.standard.object(forKey: "smartTransitionsWiFiOnly") as? Bool ?? true
    }
    /// A mix is useless with unprepared transitions, so preparing one may use cellular even when
    /// the Wi-Fi-only setting is on.
    private var allowsCellularForWindow = false
    private var cellularBlocked: Bool { wifiOnly && !allowsCellularForWindow }
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

    func prepare(rows: [TrackRow], appState: AppState, allowsCellular: Bool = false) {
        task?.cancel()
        allowsCellularForWindow = allowsCellular
        var seen = Set<Int64>()
        let window = rows.filter { row in
            guard let id = row.track.id else { return false }
            return seen.insert(id).inserted
        }
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
        states[trackID] ?? .notPrepared
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
            if cellularBlocked && path.usesInterfaceType(.cellular) {
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
            let fileBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            let peak = TransitionDecodeBudget.estimatedPeakBytes(
                durationSec: row.track.durationSec, sampleRate: row.track.sampleRate, fileBytes: fileBytes)
            guard TransitionDecodeBudget.fits(estimatedPeakBytes: peak, availableBytes: Self.availableMemory()) else {
                // Said plainly in the prep list, never a crash: this track plays normally; it just
                // gets a standard crossfade instead of a beat-matched one.
                setState(.failed(String(localized: "Too long to prepare on this device")), for: id)
                return
            }
            setState(.analyzing(0.1), for: id)
            let analyze = analyzer
            let result = try await TransitionDecodeGate.shared.run {
                try analyze(url, row.track.codec)
            }
            guard !Task.isCancelled else { setState(.cancelled, for: id); return }
            setState(.analyzing(0.8), for: id)
            try await appState.store.saveDJAnalysis(
                result.payload.encoded(),
                meta: (result.payload.algorithmID, result.payload.version,
                       result.payload.sampleRate, result.frameCount,
                       result.payload.bpm, result.payload.key.camelot),
                trackId: id)
            preparedTrackIDs.insert(id)
            setState(.analyzing(1), for: id)
            setState(.ready, for: id)
        } catch is CancellationError {
            setState(.cancelled, for: id)
        } catch {
            setState(.failed(error.localizedDescription), for: id)
        }
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
              let waitingAppState,
              pathMonitor.currentPath.status == .satisfied,
              (!cellularBlocked || !pathMonitor.currentPath.usesInterfaceType(.cellular)) else { return }
        prepare(rows: waitingRows, appState: waitingAppState, allowsCellular: allowsCellularForWindow)
    }
}
