// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tonearm (Platterhead DJ) — Copyright (C) 2026 John Arley Burns.
// See ../../LICENSE.

#if !os(watchOS)
import Combine
import Foundation
import TonearmCore
import TonearmDiscovery
import UIKit

/// The iOS lifecycle adapter for the discovery/analysis indexing subsystem
/// (app UI and iOS background lifecycle adapters depend on TonearmDiscovery).
/// It:
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
    /// identifier used by the discovery BG processing task.
    static let backgroundTaskIdentifier = "guru.parso.tonearm.discovery-index"

    private let store: LibraryStore
    private let sampler = SchedulingSampler()

    private var assembly: DiscoveryAssembly?
    private(set) var lastStatusError: String?
    private var background: DiscoveryBackgroundController?
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
            snapshotProvider: { sampler.snapshot() })
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
        let scheduler: any BackgroundTaskScheduling = BGTaskSchedulerAdapter()
        let controller = DiscoveryBackgroundController(
            assembly: assembly,
            settings: settings,
            scheduler: scheduler,
            identifier: Self.backgroundTaskIdentifier,
            // Real report: "Sound Index often says 'waiting for background
            // processing time from iOS' even when I have the app
            // foregrounded." Root cause: this used to force
            // `sampler.setAppState(.background)` unconditionally whenever a
            // BGProcessingTask was granted, then only clear
            // `hasBackgroundProcessingGrant` (never restore `appState`) when
            // it ended — trusting scene-phase transitions alone to correct
            // it afterward. iOS can genuinely invoke an already-scheduled
            // BGProcessingTask shortly AFTER the user has reopened the app
            // (a documented timing quirk, not a bug in the scheduling
            // request itself); when that happens here, `appState` got stuck
            // on `.background` with no further scene-phase event to fix it,
            // so `IndexPolicy.decide()` kept taking the `.background` branch
            // — which requires a grant — even though the app was genuinely
            // foreground and didn't need one (the `.foreground` branch below
            // never checks it). Read the real, current `UIApplication.
            // applicationState` every time the grant changes instead of
            // assuming — self-corrects regardless of ordering.
            onBackgroundGrantChanged: { granted in
                sampler.setHasBackgroundProcessingGrant(granted)
                Task { @MainActor in
                    sampler.setAppState(Self.currentApplicationStateIsBackground() ? .background : .foreground)
                }
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
        let scheduler: any BackgroundTaskScheduling = BGTaskSchedulerAdapter()
        didRegisterBackgroundTask = scheduler.register(
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
        observePlayback()
        await refreshPauseFromStore()
        sampler.setAppState(Self.currentApplicationStateIsBackground() ? .background : .foreground)
        // Keep Playing is an endless mix under Build a Mix's BPM/key/energy
        // rules; no semantic model is involved.
        AudioPlayer.shared.keepPlayingMixProvider = KeepPlayingMixContinuation(store: LibraryStore.shared)

        let assembly = await makeAssembly()
        do {
            let recovery = try await assembly.recoverAndReconcileAtLaunch()
            try? await assembly.settings.updateRuntime(
                lastStartAt: Date(),
                lastStopReason: "launch: reset \(recovery.resetIndexLeases) leases, bootstrapped \(recovery.bootstrappedTracks), drained \(recovery.drainedOutbox)")
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
                        NotificationCenter.default.post(
                            name: .tonearmMusicalMetadataDidChange, object: nil)
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
        let wifiOnly = (try? await assembly.settings.isRemoteIndexingWiFiOnly()) ?? true
        sampler.setUserPaused(paused)
        sampler.setChargingOnlySetting(chargingOnly)
        sampler.setRemoteIndexingWiFiOnlySetting(wifiOnly)
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

    /// Real report: "I tried the toggle and nothing happened, nothing is
    /// indexing." Cause: `DiscoveryReconciler.bootstrapAllTracks()` only
    /// creates a job for a track that has NONE yet — and a remote-only
    /// track that was ineligible before this setting existed never got one,
    /// so it stays job-less until something re-runs the reconciler. That
    /// only happened at the next app launch (`recoverAndReconcileAtLaunch`)
    /// — turning the setting on mid-session did nothing visible until then.
    /// Re-running bootstrap (idempotent — a no-op for every track that
    /// already has a job) and kicking a drain immediately after the
    /// flip fixes that: newly-eligible tracks get queued right away.
    func setRemoteIndexingEnabled(_ on: Bool) async {
        let assembly = await makeAssembly()
        try? await assembly.settings.setRemoteIndexingEnabled(on)
        if on { _ = await enqueueUnindexedTracks() }
    }

    func setRemoteIndexingWiFiOnly(_ on: Bool) async {
        let assembly = await makeAssembly()
        try? await assembly.settings.setRemoteIndexingWiFiOnly(on)
        sampler.setRemoteIndexingWiFiOnlySetting(on)
    }

    /// A rough, honest estimate of the one-time data cost to sparsely sample
    /// every currently remote-only track in the library — what the Settings
    /// confirmation dialog shows before letting the user turn off Wi-Fi-only.
    /// Uses the same per-track worst-case figure the plan's own byte budget
    /// is built on (~180s of audio at a conservative 192kbps): real usage is
    /// typically lower (many tracks are shorter, or already local), never
    /// meaningfully higher (the fetch is capped to what a track's windows
    /// need, never the whole file).
    func remoteIndexingEstimate() async -> (trackCount: Int, estimatedBytes: Int64) {
        let assembly = await makeAssembly()
        let count = (try? await assembly.reconciler.remoteOnlyTrackCount()) ?? 0
        return (count, Int64(count) * RemoteIndexingByteEstimate.perTrackBytes)
    }

    /// "Analyze selected next" (plan §10.4): ensure the track has an index
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
        do {
            lastStatusError = nil
            return try await assembly.statusSnapshot()
        } catch {
            lastStatusError = String(describing: error)
            return nil
        }
    }

    /// Throwing variant for `SnapshotCoordinator`, which needs the failure.
    func statusSnapshotOrThrow() async throws -> IndexStatusSnapshot {
        let assembly = await makeAssembly()
        do {
            lastStatusError = nil
            return try await assembly.statusSnapshot()
        } catch {
            lastStatusError = String(describing: error)
            throw error
        }
    }

    /// "Retry failed" action (plan §10 action 4).
    @discardableResult
    func retryFailed() async -> Int {
        let assembly = await makeAssembly()
        let count = (try? await assembly.retryFailedJobs()) ?? 0
        if count > 0 { startForegroundTickLoop() }
        return count
    }

    /// Manual "Enqueue unindexed tracks" action — real report: reconciliation
    /// (what decides whether a track qualifies for a job) only ever runs
    /// automatically at app launch or on a live catalog-change event; it
    /// never re-runs just because eligibility criteria changed (e.g. the
    /// remote-indexing setting) or a track got missed for any other reason
    /// mid-session. `bootstrapAllTracks()` is already idempotent — a no-op
    /// for every track that already has a job — so this is always safe to
    /// press, not just after flipping a setting.
    @discardableResult
    func enqueueUnindexedTracks() async -> Int {
        let assembly = await makeAssembly()
        // Legacy remote tracks (added before commit 0a80ff8) never got a
        // persisted node reference, so they fail sparse-indexing eligibility
        // no matter how many times bootstrap runs — backfill it first.
        _ = await assembly.reconciler.backfillRemoteNodeReferences()
        let count = (try? await assembly.reconciler.bootstrapAllTracks()) ?? 0
        if count > 0 {
            _ = try? await assembly.drainQueue()
            startForegroundTickLoop()
        }
        return count
    }

    /// Up to `limit` real tracks in `bucket`, for the status screen's tappable detail list (real
    /// report: "let me actually see what's happening and what's indexed" — the counts alone
    /// couldn't answer that). On-device only, never exported (unlike `diagnostics()` above, which
    /// stays redacted for the plan §10.6 share sheet).
    func trackSummaries(for bucket: IndexJobRepository.TrackListBucket, limit: Int = 500) async
        -> [IndexJobRepository.TrackSummary]
    {
        let assembly = await makeAssembly()
        return (try? await assembly.jobs.trackSummaries(
            for: bucket, pipelineVersion: DiscoveryPipelineVersion.pipeline, limit: limit)) ?? []
    }

    /// Redacted diagnostics for the plan §10.6 share-sheet export.
    func diagnostics() async -> DiscoveryDiagnostics? {
        guard let snapshot = await statusSnapshot() else { return nil }
        let info = Bundle.main.infoDictionary
        let appVersion = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        let os = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        let family = "iPhone"
        return DiscoveryDiagnostics.make(
            snapshot: snapshot, appVersion: appVersion, buildNumber: build,
            osVersion: os, deviceFamily: family)
    }

    // MARK: - Helpers

    private static func currentApplicationStateIsBackground() -> Bool {
        UIApplication.shared.applicationState == .background
    }
}

#endif
