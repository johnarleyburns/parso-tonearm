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
            // Always `.cpuOnly` (`.background`) for automatic indexing, never GPU/ANE
            // (`.foreground`), regardless of scene state. Real report: indexing almost never
            // progressed — the status surface constantly read "waiting for the device to cool
            // down" on a device that did not feel hot. Root cause: this closure gave every
            // automatic embed CPU+GPU/ANE compute whenever the app scene happened to be
            // foregrounded (the common case — nothing here is actually latency-sensitive
            // "foreground" work, just automatic indexing that runs while the app is open).
            // Running the CLAP encoder on GPU/ANE nudges `ProcessInfo.thermalState` from
            // `.nominal` to `.fair` well before a device feels warm; IndexPolicy's `.fair`
            // recovery requires 60 *continuous* nominal seconds (IMPLEMENT_CLAP_PLAN.md §6),
            // so each blip reset that clock — the scheduler spent nearly all its time waiting
            // out a debounce window it kept re-triggering. There is no shipped "analyze this
            // one track now" interactive path today (`isUserSelectedTrackRequest` is always
            // `false` — see `SchedulingSampler.snapshot()`), so nothing currently needs the
            // GPU/ANE path; CPU-only is slower per track but produces real, sustained progress
            // instead of a self-defeating thermal loop. Revisit if/when a genuine interactive
            // single-track request ships.
            executionContext: { .background },
            modelDownloadProgressProvider: { DiscoveryModelResources.shared.currentDownloadProgress() },
            modelDownloadErrorProvider: { DiscoveryModelResources.shared.currentDownloadError() },
            modelDownloadTagDebugProvider: { DiscoveryModelResources.shared.currentPerTagDebugSummary() },
            modelDiagnosticsProvider: { DiscoveryModelResources.shared.currentDiagnosticsDetail() })
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
        observeMemoryWarnings()
        await refreshPauseFromStore()
        sampler.setAppState(currentApplicationStateIsBackground() ? .background : .foreground)
        // Keep Playing (main-library queue continuation) reuses this same
        // CLAP retrieval engine — wire the real adapter in now that Discovery
        // is up. Before this runs (and always under `swift test`), the seam
        // stays `nil` and `AudioPlayer` takes its honest shuffle-continue
        // fallback instead.
        AudioPlayer.shared.keepPlayingProvider = KeepPlayingDiscoveryProvider()

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

    /// Actually wires up `ModelManager.releaseCachedModel()` (plan §6: "release models/buffers on
    /// thermal serious/critical or memory warning when safe") — it existed but nothing ever called
    /// it. Real risk this closes: each CLAP encoder is 130–240 MB; once loaded it stayed resident
    /// for the rest of the process even under a real memory warning. Indexing now deliberately
    /// keeps running during playback (a main use case, not paused for it — see `IndexPolicy`), so
    /// a long locked-screen listening session can hold decoded audio buffers AND a resident CLAP
    /// model in memory at the same time; not releasing the model on a memory warning is exactly
    /// the kind of pressure that escalates into a jetsam kill, which matches the real report of
    /// the app disappearing during locked-screen playback. `SchedulingSampler` already observes
    /// `UIApplication.didReceiveMemoryWarningNotification` for the scheduling gate (which still
    /// blocks the NEXT index job) — this adds the actual model release the plan called for
    /// alongside it. Safe at any time: the model reloads lazily on the next `audioEncoder`/
    /// `textEncoder` call.
    private func observeMemoryWarnings() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.assembly?.models.releaseCachedModel() }
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

    // MARK: - Search surface (plan §10.1, C07)

    /// The one process-wide search view model, wired to the real retrieval
    /// engine (`DiscoveryAssembly.search`), the existing metadata search
    /// (`LibraryStore.search` — needs no model download) and the same
    /// `AppState` playback path an ordinary library row uses.
    func searchViewModel(appState: AppState, player: AudioPlayer) async -> DiscoverySearchViewModel {
        if let searchVM { return searchVM }
        let vm = await buildSearchViewModel(appState: appState, player: player)
        searchVM = vm
        return vm
    }

    /// A fresh, independent `DiscoverySearchViewModel` — deliberately NOT
    /// memoized, unlike `searchViewModel(appState:player:)` above. Built for
    /// the Listen tab's mood entry point (docs/plans/mood-based-listening-
    /// plan.md §2's audit note / §5 step 5): that screen's own
    /// `searchText`/`positiveRefinements` must be independent of "Find by
    /// sound"'s, or selecting mood pills here would corrupt (or be
    /// corrupted by) whatever the user has set on that other screen. Still
    /// reuses the one shared `assembly.search` (`makeAssembly()` memoizes
    /// that separately from `searchVM`), so the CLAP model itself is never
    /// loaded twice.
    func makeSearchViewModel(appState: AppState, player: AudioPlayer) async -> DiscoverySearchViewModel {
        await buildSearchViewModel(appState: appState, player: player)
    }

    private func buildSearchViewModel(appState: AppState, player: AudioPlayer) async -> DiscoverySearchViewModel {
        let assembly = await makeAssembly()
        let service = await assembly.search
        let coordinator = DiscoverySearchCoordinator(service: service)
        let store = self.store

        return DiscoverySearchViewModel(
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
    }

    /// "Analyze this track" for a stale/missing reference embedding (plan §9)
    /// and "Analyze selected next" (plan §10.4): ensure the track has an index
    /// job and kick a foreground drain.
    func analyzeTrack(_ trackID: Int64) async {
        let assembly = await makeAssembly()
        _ = try? await assembly.reconciler.bootstrapAllTracks()
        startForegroundTickLoop()
    }

    // MARK: - Keep Playing (main-library queue continuation)

    /// The real CLAP nearest-neighbor lookup behind `AudioPlayer`'s
    /// `KeepPlayingSimilarityProviding` seam: runs the same `SearchService`
    /// "more like this track" mode (`DiscoverySearchMode.similar`) search
    /// already used for "More Like This" in Now Playing, against the
    /// most-recently-played track. Reports `.waitingForModel` /
    /// `.unavailable` rather than ever silently returning nothing, so
    /// `AudioPlayer` can fall back honestly and say why (CLAUDE.md
    /// "no silent/magic background work").
    func keepPlayingLookup(
        after recentlyPlayed: [Int64], excluding: Set<Int64>, limit: Int
    ) async -> KeepPlayingLookup {
        guard let referenceTrackID = recentlyPlayed.first else { return .unavailable }
        let assembly = await makeAssembly()
        let modelAvailable = await assembly.models.isModelResourceAvailable()

        // Over-fetch so filtering out already-queued/history tracks still
        // leaves up to `limit` real picks.
        let requestLimit = min(ValidatedQuery.maxLimit, limit + excluding.count + 5)
        let query = DiscoverySearchQuery(limit: requestLimit)
        let response = await assembly.search.search(query, referenceTrackID: referenceTrackID)

        switch response.state {
        case .ready:
            let ids = response.results.map(\.trackID).filter { !excluding.contains($0) }
            guard !ids.isEmpty else { return modelAvailable ? .unavailable : .waitingForModel }
            return .ready(Array(ids.prefix(limit)))
        case .modelMissing, .modelDownloadFailed:
            return .waitingForModel
        default:
            // .unindexedReference, .zeroIndexed, .noMatches, .emptyLibrary,
            // .emptyScope, .sourceUnavailable, .searchFailed,
            // .validationFailed, .cancelled — the model itself is fine, this
            // reference/scope just has nothing usable right now.
            return .unavailable
        }
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

/// Adapts `DiscoveryRuntimeController` to `AudioPlayer`'s
/// `KeepPlayingSimilarityProviding` seam. This indirection exists because
/// `TonearmCore` (where `AudioPlayer` lives) cannot import `TonearmDiscovery`
/// directly — that package already depends on `TonearmCore`, so the reverse
/// import would cycle — while this file, part of the app target, already
/// depends on both.
struct KeepPlayingDiscoveryProvider: KeepPlayingSimilarityProviding {
    func continuationTrackIDs(
        after recentlyPlayed: [Int64], excluding: Set<Int64>, limit: Int
    ) async -> KeepPlayingLookup {
        await DiscoveryRuntimeController.shared.keepPlayingLookup(
            after: recentlyPlayed, excluding: excluding, limit: limit)
    }
}
#endif
