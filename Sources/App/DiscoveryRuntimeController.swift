// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tonearm (Platterhead DJ) — Copyright (C) 2026 John Arley Burns.
// See ../../LICENSE.

#if canImport(UIKit) && !os(watchOS)
import Combine
import Foundation
import TonearmCore
import TonearmDiscovery
import UIKit

/// The iOS lifecycle adapter for the Discovery/CLAP indexing subsystem
/// (IMPLEMENT_CLAP_PLAN.md §3: "App UI and iOS background lifecycle adapters
/// depend on TonearmDiscovery"; §6/§7). It:
///
///  - owns the single process-wide `DiscoveryAssembly` (plan §7: "only one
///    scheduler exists per process"),
///  - gathers REAL power/thermal/playback/app-state into a
///    `DiscoverySchedulingSnapshot` — never fabricated (plan §6),
///  - registers the `guru.parso.tonearm.discovery-index` BGProcessingTask and
///    drives a bounded `drainQueue()` pass from both the foreground tick loop
///    and the background handler, sharing the one scheduler.
///
/// UIKit/BackgroundTasks live here and nowhere in `TonearmDiscovery`, keeping
/// that package portable and unit-testable.
@MainActor
final class DiscoveryRuntimeController {
    static let shared = DiscoveryRuntimeController()

    /// Must match `BGTaskSchedulerPermittedIdentifiers` in Info.plist and the
    /// identifier named in IMPLEMENT_CLAP_PLAN.md §7.
    static let backgroundTaskIdentifier = "guru.parso.tonearm.discovery-index"

    private let store: LibraryStore
    private let sampler = SchedulingSampler()

    private var assembly: DiscoveryAssembly?
    private var background: DiscoveryBackgroundController?
    private var searchVM: DiscoverySearchViewModel?
    private var didRegisterBackgroundTask = false
    private var didStart = false
    private var tickLoop: Task<Void, Never>?
    private var pauseRefresh: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    private init(store: LibraryStore = .shared) {
        self.store = store
    }

    private func makeAssembly() async -> DiscoveryAssembly {
        if let assembly { return assembly }
        let writer = await store.dbQueue
        let sampler = self.sampler
        let built = DiscoveryAssembly(
            writer: writer,
            snapshotProvider: { sampler.snapshot() },
            // Real CLAP audio-encoder + bundled mel-filterbank resolution
            // (C04 Apple-host step, plan §8). Returns `.unavailable` — jobs
            // park at `waitingForModel` — until the `clap-audio` ODR pack is
            // actually on disk; never a fabricated embedding.
            modelResourceProvider: { DiscoveryModelResources.shared.currentResources() },
            executionContext: { sampler.isBackground ? .background : .foreground },
            modelDownloadProgressProvider: { DiscoveryModelResources.shared.currentDownloadProgress() })
        assembly = built
        return built
    }

    /// Lazily build the portable `DiscoveryBackgroundController` that owns
    /// every BackgroundTasks concern (submit / handle / coalesce / expiration
    /// / `discovery_runtime` telemetry — C05). This controller retains only
    /// launch sequencing + the foreground tick loop.
    private func backgroundController() async -> DiscoveryBackgroundController {
        if let background { return background }
        let assembly = await makeAssembly()
        let sampler = self.sampler
        let settings = await assembly.settings
        let controller = DiscoveryBackgroundController(
            assembly: assembly,
            settings: settings,
            scheduler: BGTaskSchedulerAdapter(),
            identifier: Self.backgroundTaskIdentifier,
            onBackgroundGrantChanged: { granted in
                if granted { sampler.setAppState(.background) }
                sampler.setHasBackgroundProcessingGrant(granted)
            })
        background = controller
        return controller
    }

    // MARK: - Launch registration (call from TonearmApp.init, before launch completes)

    /// Register the BG task handler exactly once, before the app finishes
    /// launching, from a delegate reachable in a headless launch (plan §7).
    /// The registration call itself must be synchronous at launch; the
    /// handler routes into the portable `DiscoveryBackgroundController`.
    func registerBackgroundTask() {
        guard !didRegisterBackgroundTask else { return }
        didRegisterBackgroundTask = BGTaskSchedulerAdapter().register(
            identifier: Self.backgroundTaskIdentifier
        ) { invocation in
            Task { @MainActor in
                await DiscoveryRuntimeController.shared.backgroundController().run(invocation)
            }
        }
    }

    // MARK: - Start (call after the DB/bootstrap is ready)

    func startAfterBootstrap() async {
        guard !didStart else { return }
        didStart = true

        sampler.beginObserving()
        DiscoveryModelResources.shared.beginAccessing()
        observePlayback()
        await refreshPauseFromStore()
        sampler.setAppState(currentApplicationStateIsBackground() ? .background : .foreground)

        let assembly = await makeAssembly()
        do {
            let recovery = try await assembly.recoverAndReconcileAtLaunch()
            try? await assembly.settings.updateRuntime(
                lastStartAt: Date(),
                lastStopReason: "launch: reset \(recovery.resetIndexLeases) leases, "
                    + "bootstrapped \(recovery.bootstrappedTracks), drained \(recovery.drainedOutbox)")
        } catch {
            NSLog("[Discovery] launch recovery failed: \(error)")
        }

        startForegroundTickLoop()
        startPauseRefreshLoop()
    }

    // MARK: - Scene transitions

    func scenePhaseChanged(toBackground: Bool) {
        sampler.setAppState(toBackground ? .background : .foreground)
        if toBackground {
            Task { await self.backgroundController().submitPendingWorkRequestIfNeeded() }
        } else {
            startForegroundTickLoop()
        }
    }

    // MARK: - Foreground tick loop

    private func startForegroundTickLoop() {
        guard didStart, tickLoop == nil else { return }
        tickLoop = Task { [weak self] in
            defer { Task { @MainActor in self?.tickLoop = nil } }
            while !Task.isCancelled {
                guard let self else { return }
                if self.sampler.isBackground {
                    try? await Task.sleep(for: .seconds(30))
                    continue
                }
                let assembly = await self.makeAssembly()
                do {
                    let completed = try await assembly.drainQueue()
                    if completed > 0 {
                        try? await assembly.settings.updateRuntime(
                            lastRunAt: Date(), lastSuccessfulWorkAt: Date())
                    }
                } catch {
                    NSLog("[Discovery] foreground drain error: \(error)")
                }
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    /// Playback gating (plan §6: "Playback active: Pause automatic audio
    /// analysis ... Resume when playback stops").
    private func observePlayback() {
        AudioPlayer.shared.$isPlaying
            .removeDuplicates()
            .sink { [weak self] playing in
                guard let self else { return }
                self.sampler.setPlaybackActive(playing)
                if !playing { self.startForegroundTickLoop() }
            }
            .store(in: &cancellables)
    }

    private func startPauseRefreshLoop() {
        guard pauseRefresh == nil else { return }
        pauseRefresh = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await self?.refreshPauseFromStore()
            }
        }
    }

    private func refreshPauseFromStore() async {
        let assembly = await makeAssembly()
        let paused = (try? await assembly.settings.isPaused()) ?? false
        let chargingOnly = (try? await assembly.settings.isChargingOnly()) ?? false
        sampler.setUserPaused(paused)
        sampler.setChargingOnlySetting(chargingOnly)
    }

    /// Real scheduler control for the status UI (plan §10 action 4).
    func setPaused(_ paused: Bool) async {
        let assembly = await makeAssembly()
        try? await assembly.settings.setPaused(paused)
        sampler.setUserPaused(paused)
        if !paused { startForegroundTickLoop() }
    }

    func setChargingOnly(_ on: Bool) async {
        let assembly = await makeAssembly()
        try? await assembly.settings.setChargingOnly(on)
        sampler.setChargingOnlySetting(on)
    }

    // MARK: - Search surface (plan §10.1, C07)

    /// The one process-wide search view model, wired to the real retrieval
    /// engine (`DiscoveryAssembly.search`), the existing metadata search
    /// (`LibraryStore.search` — needs no model download) and the same
    /// `AppState` playback path an ordinary library row uses.
    func searchViewModel(appState: AppState, player: AudioPlayer) async -> DiscoverySearchViewModel {
        if let searchVM { return searchVM }
        let assembly = await makeAssembly()
        let service = await assembly.search
        let coordinator = DiscoverySearchCoordinator(service: service)
        let store = self.store

        let vm = DiscoverySearchViewModel(
            coordinator: coordinator,
            service: service,
            metadataSearch: { query in
                do {
                    var rows = try await store.search(query.text)
                    if let ids = query.sourceIDs {
                        let set = Set(ids)
                        rows = rows.filter { set.contains($0.track.sourceId) }
                    }
                    return .success(rows)
                } catch {
                    return .failure(error)
                }
            },
            onPlay: { [weak appState, weak player] result in
                guard let appState, let player else { return }
                Task { @MainActor in
                    var row = result.track
                    if row.id < 0, let persisted = await appState.persistRemoteTrack(row) {
                        row = persisted
                    }
                    player.play(tracks: [row], startAt: 0, source: .library)
                }
            },
            onAnalyzeTrack: { trackID in
                Task { @MainActor in await DiscoveryRuntimeController.shared.analyzeTrack(trackID) }
            },
            onDownloadModels: {
                DiscoveryModelResources.shared.beginAccessing()
            },
            onOpenIndexStatus: {})
        searchVM = vm
        return vm
    }

    /// "Analyze this track" for a stale/missing reference embedding (plan §9)
    /// and "Analyze selected next" (plan §10.4): ensure the track has an index
    /// job and kick a foreground drain.
    func analyzeTrack(_ trackID: Int64) async {
        let assembly = await makeAssembly()
        _ = try? await assembly.reconciler.bootstrapAllTracks()
        startForegroundTickLoop()
    }

    // MARK: - Status surface (plan §10, C07)

    /// A consistent snapshot of the persisted indexing state for the status
    /// banner + screen. `nil` only if the DB read genuinely failed.
    func statusSnapshot() async -> IndexStatusSnapshot? {
        let assembly = await makeAssembly()
        return try? await assembly.statusSnapshot()
    }

    /// "Retry failed" action (plan §10 action 4).
    @discardableResult
    func retryFailed() async -> Int {
        let assembly = await makeAssembly()
        let count = (try? await assembly.retryFailedJobs()) ?? 0
        if count > 0 { startForegroundTickLoop() }
        return count
    }

    /// Redacted diagnostics for the plan §10.6 share-sheet export.
    func diagnostics() async -> DiscoveryDiagnostics? {
        guard let snapshot = await statusSnapshot() else { return nil }
        let info = Bundle.main.infoDictionary
        let appVersion = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        let os = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        let family = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        return DiscoveryDiagnostics.make(
            snapshot: snapshot, appVersion: appVersion, buildNumber: build,
            osVersion: os, deviceFamily: family)
    }

    // MARK: - Helpers

    private func currentApplicationStateIsBackground() -> Bool {
        UIApplication.shared.applicationState == .background
    }
}
#endif
