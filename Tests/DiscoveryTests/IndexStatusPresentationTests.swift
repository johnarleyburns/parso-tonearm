#if !os(watchOS)
import Foundation
import Testing

@testable import TonearmCore
@testable import TonearmDiscovery

/// C07 status-surface view-model mapping: the
/// distinct response states must map to distinct display, and diagnostics
/// export must stay redacted (aggregate counts only, no track identity).
@Suite struct IndexStatusPresentationTests {
    private func coverage(
        total: Int, complete: Int = 0, queuedOrRunning: Int = 0, waiting: Int = 0, failed: Int = 0,
        waitingBreakdown: [DiscoveryJobState: Int] = [:],
        mostRecentFailureError: IndexJobRepository.JobErrorSample? = nil
    ) -> IndexJobRepository.Coverage {
        IndexJobRepository.Coverage(
            total: total, complete: complete, queuedOrRunning: queuedOrRunning,
            waiting: waiting, failed: failed,
            waitingBreakdown: waitingBreakdown, mostRecentFailureError: mostRecentFailureError)
    }

    private func snapshot(
        _ coverage: IndexJobRepository.Coverage,
        paused: Bool = false, chargingOnly: Bool = false,
        runtime: DiscoveryRuntime = DiscoveryRuntime(id: 1),
        blockReason: IndexBlockReason? = nil,
        thermal: ThermalDiagnostic? = nil,
        currentlyIndexingTrack: IndexJobRepository.RunningTrackSummary? = nil,
        recentCompletionRate: Double? = nil
    ) -> IndexStatusSnapshot {
        IndexStatusSnapshot(
            coverage: coverage, isPaused: paused, isChargingOnly: chargingOnly,
            runtime: runtime,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            schedulerBlockReason: blockReason,
            thermalDiagnostic: thermal,
            currentlyIndexingTrack: currentlyIndexingTrack,
            recentCompletionRate: recentCompletionRate)
    }

    @Test func testEmptyLibrary() {
        let p = IndexStatusPresentation.make(from: snapshot(coverage(total: 0)))
        #expect(p.phase == .emptyLibrary)
        #expect(p.headline == "Sound index: not started")
        #expect(!p.showsBanner)
        #expect(!p.canPause)
        #expect(!p.canResume)
    }

    @Test func testUpToDate() {
        let p = IndexStatusPresentation.make(from: snapshot(coverage(total: 1042, complete: 1042)))
        #expect(p.phase == .upToDate)
        #expect(p.headline == "Sound index: 1,042 / 1,042 tracks")
        #expect(p.fractionComplete == 1.0)
        #expect(p.showsBanner)
        #expect(!p.canPause)
    }

    @Test func testIndexingInProgress() {
        let p = IndexStatusPresentation.make(
            from: snapshot(coverage(total: 1042, complete: 238, queuedOrRunning: 804)))
        #expect(p.phase == .indexing)
        #expect(p.headline == "Sound index: 238 / 1,042 tracks")
        #expect(abs(p.fractionComplete - 238.0 / 1042.0) <= 0.0001)
        #expect(p.canPause)
        #expect(!p.canResume)
    }

    @Test func testPausedTakesPrecedenceOverQueuedWork() {
        let p = IndexStatusPresentation.make(
            from: snapshot(coverage(total: 100, complete: 10, queuedOrRunning: 90), paused: true))
        #expect(p.phase == .paused)
        #expect(p.canResume)
        #expect(!p.canPause)
    }

    @Test func testWaitingForPowerIsDistinct() {
        let p = IndexStatusPresentation.make(
            from: snapshot(
                coverage(total: 100, complete: 40, waiting: 60),
                chargingOnly: true))
        #expect(p.phase == .waiting)
        #expect(p.detail.lowercased().contains("power"))
    }

    /// Real user report: "Waiting to continue. Indexing resumes when
    /// conditions allow. That is as much of a non-statement as I've ever
    /// heard." Root cause was `waitingBreakdown` never reaching the
    /// presentation layer at all (`DiscoveryAssembly.drainQueue` discarded
    /// the real per-job reason on every tick). With a real breakdown, the
    /// dominant reason must be named, not the generic text.
    @Test func testWaitingDetailNamesTheDominantRealReason() {
        let p = IndexStatusPresentation.make(
            from: snapshot(
                coverage(
                    total: 100, complete: 90, waiting: 10,
                    waitingBreakdown: [.waitingForAsset: 10])))
        #expect(p.phase == .waiting)
        #expect(p.detail.contains("audio file"), "\(p.detail)")
        #expect(!p.detail.contains("conditions allow"), "\(p.detail)")
    }

    /// The user's other real complaint: "sometimes I see failures but
    /// retrying also fails" — a `.retryScheduled` majority must surface the
    /// actual last error, not just "will retry automatically" with no
    /// explanation of what keeps going wrong.
    @Test func testWaitingDetailForRetrySchedulesSurfacesTheLastError() {
        let p = IndexStatusPresentation.make(
            from: snapshot(
                coverage(
                    total: 100, complete: 90, waiting: 10,
                    waitingBreakdown: [.retryScheduled: 10],
                    mostRecentFailureError: IndexJobRepository.JobErrorSample(
                        code: "windowReadFailed",
                        message: "Could not read audio window from the source file."))))
        #expect(p.phase == .waiting)
        #expect(p.detail.contains("retry automatically"), "\(p.detail)")
        #expect(
            p.detail.contains("Could not read audio window from the source file."), "\(p.detail)")
    }

    /// A `.waiting` snapshot with no breakdown at all (an older/synthetic
    /// caller) must still fall back to the previous, still-honest generic
    /// text rather than crash or show nothing.
    @Test func testWaitingDetailFallsBackWithoutABreakdown() {
        let p = IndexStatusPresentation.make(
            from: snapshot(coverage(total: 100, complete: 90, waiting: 10)))
        #expect(p.phase == .waiting)
        #expect(p.detail.contains("conditions allow"), "\(p.detail)")
    }

    /// The `.needsAttention` (all-failed) detail must also surface the real
    /// last error when one is known — the same non-statement problem
    /// applied to `.failed` jobs, not just `.waiting` ones.
    @Test func testNeedsAttentionSurfacesTheLastRealErrorWhenKnown() {
        let p = IndexStatusPresentation.make(
            from: snapshot(
                coverage(
                    total: 100, complete: 95, failed: 5,
                    mostRecentFailureError: IndexJobRepository.JobErrorSample(
                        code: "decodeFailed", message: "Audio decode failed."))))
        #expect(p.phase == .needsAttention)
        #expect(p.detail.contains("Audio decode failed."), "\(p.detail)")
    }

    @Test func testNeedsAttentionWhenOnlyFailures() {
        let p = IndexStatusPresentation.make(
            from: snapshot(coverage(total: 100, complete: 95, failed: 5)))
        #expect(p.phase == .needsAttention)
        #expect(p.canRetryFailed)
        #expect(p.failedCount == 5)
    }

    @Test func testRetryOfferedEvenWhileIndexingContinues() {
        let p = IndexStatusPresentation.make(
            from: snapshot(coverage(total: 100, complete: 50, queuedOrRunning: 45, failed: 5)))
        #expect(p.phase == .indexing)
        #expect(p.canRetryFailed)
    }

    /// The regression this fix is for: real user report was "Sound Index
    /// says 0/2364 tracks... after 5+ minutes, not a single track has been
    /// indexed... [status screen] just says indexing, nothing about
    /// downloading, waiting, no progress ever evident." Before the fix,
    /// `schedulerBlockReason` did not exist and this exact
    /// coverage (all jobs queued, zero complete) produced `.indexing` with a
    /// generic "Indexing N tracks…" detail no matter what was actually
    /// blocking the scheduler underneath.
    @Test func testBlockedSchedulerNeverShownAsGenericIndexing() {
        let p = IndexStatusPresentation.make(
            from: snapshot(
                coverage(total: 2364, complete: 0, queuedOrRunning: 2364),
                blockReason: .thermalFair))
        #expect(p.phase == .blockedByPolicy)
        #expect(p.phase != .indexing)
        #expect(
            !p.detail.lowercased().hasPrefix("indexing"),
            "must surface the real reason, not the generic indexing label")
        #expect(p.detail.lowercased().contains("cool down"))
        // The headline (raw counts) is unaffected — only `detail`/`phase`
        // change; "0 / 2,364" must still read exactly as reported.
        #expect(p.headline == "Sound index: 0 / 2,364 tracks")
    }

    /// The actual bug report this answers: "it always says waiting for the device to cool down,
    /// but the device is NOT hot." Root cause was `IndexPolicy`'s `.fair` recovery rule blocking
    /// on `continuousNominalSeconds < 60` even while the device had already returned to
    /// `.nominal` — collapsed into the same "cool down" text as an actually-hot device. With a
    /// real `ThermalDiagnostic`, a currently-`.nominal` block must read as genuinely different
    /// from a currently-`.serious`/`.critical` one, and must say real numbers, not just a label.
    @Test func testThermalDetailDistinguishesRecoveringFromActuallyHot() {
        let recovering = IndexStatusPresentation.make(
            from: snapshot(
                coverage(total: 10, complete: 0, queuedOrRunning: 10), blockReason: .thermalFair,
                thermal: ThermalDiagnostic(state: .nominal, continuousNominalSeconds: 37)))
        #expect(recovering.detail.lowercased().contains("normal"),
                      "a currently-nominal device must not read as hot: \(recovering.detail)")
        #expect(recovering.detail.contains("23"),
                      "must show the real seconds remaining (60 - 37 = 23): \(recovering.detail)")

        let actuallyHot = IndexStatusPresentation.make(
            from: snapshot(
                coverage(total: 10, complete: 0, queuedOrRunning: 10), blockReason: .thermalSerious,
                thermal: ThermalDiagnostic(state: .serious, continuousNominalSeconds: 0)))
        #expect(actuallyHot.detail.lowercased().contains("hot"),
                      "a genuinely serious/critical state must say so: \(actuallyHot.detail)")

        #expect(recovering.detail != actuallyHot.detail)
    }

    @Test func testEachPolicyBlockReasonHasADistinctNonGenericDetail() {
        let reasons: [IndexBlockReason] = [
            .thermalFair, .thermalSerious, .thermalCritical,
            .memoryWarning, .lowBatteryOrLowPowerMode, .chargingOnlyRequired,
            .backgroundGrantMissing,
        ]
        var seenDetails = Set<String>()
        for reason in reasons {
            let p = IndexStatusPresentation.make(
                from: snapshot(
                    coverage(total: 10, complete: 0, queuedOrRunning: 10), blockReason: reason))
            #expect(p.phase == .blockedByPolicy, "\(reason)")
            #expect(!p.detail.isEmpty, "\(reason)")
            seenDetails.insert(p.detail)
        }
        // Thermal variants intentionally share one user-facing message;
        // otherwise every reason should read distinctly.
        #expect(seenDetails.count >= reasons.count - 2)
    }

    /// `userPaused` already has its own dedicated, higher-priority phase
    /// (`.paused`, checked via `snapshot.isPaused`) — a leftover
    /// `schedulerBlockReason == .userPaused` from a stale tick must not
    /// create a second, redundant "blocked" phase.
    @Test func testStaleUserPausedBlockReasonDoesNotOverrideNormalIndexing() {
        let p = IndexStatusPresentation.make(
            from: snapshot(
                coverage(total: 10, complete: 2, queuedOrRunning: 8),
                blockReason: .userPaused))
        #expect(p.phase == .indexing)
    }

    @Test func testDiagnosticsAreRedactedAggregatesOnly() {
        let runtime = DiscoveryRuntime(
            id: 1, lastRunAt: Date(timeIntervalSince1970: 1_700_000_100),
            lastStopReason: "background: 3 completed")
        let snap = snapshot(
            coverage(total: 10, complete: 4, waiting: 6), runtime: runtime)
        let diag = DiscoveryDiagnostics.make(
            snapshot: snap, appVersion: "1.2.3", buildNumber: "456",
            osVersion: "iOS 18.5", deviceFamily: "iPhone")

        let json = diag.jsonString()
        #expect(json.contains("\"tracksTotal\" : 10"))
        #expect(json.contains("\"tracksFailed\" : 0"))
        #expect(json.contains("background: 3 completed"))
        // No identity leakage vectors.
        #expect(!json.lowercased().contains("http"))
        #expect(!json.lowercased().contains("file://"))
        #expect(!json.lowercased().contains("token"))
        #expect(!json.lowercased().contains("bookmark"))

        let text = diag.plainText()
        #expect(text.contains("10 total"))
        #expect(text.contains("1.2.3 (456)"))
    }
}

/// ETA + current-track presentation. A single analysis unit has no window
/// fraction, so the current track is identified without a fabricated %.
@Suite struct IndexStatusETATests {
    private func coverage(
        total: Int, complete: Int = 0, queuedOrRunning: Int = 0, waiting: Int = 0, failed: Int = 0
    ) -> IndexJobRepository.Coverage {
        IndexJobRepository.Coverage(
            total: total, complete: complete, queuedOrRunning: queuedOrRunning,
            waiting: waiting, failed: failed,
            waitingBreakdown: [:], mostRecentFailureError: nil)
    }

    private func snapshot(
        _ coverage: IndexJobRepository.Coverage,
        blockReason: IndexBlockReason? = nil,
        currentlyIndexingTrack: IndexJobRepository.RunningTrackSummary? = nil,
        recentCompletionRate: Double? = nil
    ) -> IndexStatusSnapshot {
        IndexStatusSnapshot(
            coverage: coverage, isPaused: false, isChargingOnly: false,
            runtime: DiscoveryRuntime(id: 1),
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            schedulerBlockReason: blockReason,
            thermalDiagnostic: nil,
            currentlyIndexingTrack: currentlyIndexingTrack,
            recentCompletionRate: recentCompletionRate)
    }

    @Test func testCurrentTrackAndETAShowOnlyWhileActivelyIndexing() {
        let track = IndexJobRepository.RunningTrackSummary(
            id: 1, title: "Some Song", artistName: "Some Artist")
        let p = IndexStatusPresentation.make(
            from: snapshot(
                coverage(total: 50, complete: 10, queuedOrRunning: 40),
                currentlyIndexingTrack: track, recentCompletionRate: 1.0 / 60))
        #expect(p.phase == .indexing)
        #expect(p.currentTrackTitle == "Some Song")
        #expect(p.currentTrackArtist == "Some Artist")
        #expect(p.estimatedTimeRemainingText != nil)
    }

    @Test func testCurrentTrackAndETAAreSuppressedWhenBlockedByPolicy() {
        let track = IndexJobRepository.RunningTrackSummary(
            id: 1, title: "Stuck Song", artistName: nil)
        let p = IndexStatusPresentation.make(
            from: snapshot(
                coverage(total: 50, complete: 10, queuedOrRunning: 40),
                blockReason: .thermalSerious,
                currentlyIndexingTrack: track, recentCompletionRate: 1.0 / 60))
        #expect(p.phase == .blockedByPolicy)
        #expect(p.currentTrackTitle == nil)
        #expect(p.estimatedTimeRemainingText == nil)
    }

    @Test func testEstimatedTimeRemainingTextIsNeverFabricatedWithoutARealRate() {
        #expect(IndexStatusPresentation.estimatedTimeRemainingText(remaining: 100, rate: nil) == nil)
        #expect(IndexStatusPresentation.estimatedTimeRemainingText(remaining: 0, rate: 1.0 / 60) == nil)
        #expect(IndexStatusPresentation.estimatedTimeRemainingText(remaining: 100, rate: 0) == nil)
    }

    @Test func testEstimatedTimeRemainingTextRoundsToCoarseHonestUnits() {
        let minutes = IndexStatusPresentation.estimatedTimeRemainingText(remaining: 10, rate: 1.0 / 10)
        #expect(minutes == "About 2 min remaining")
        let hours = IndexStatusPresentation.estimatedTimeRemainingText(remaining: 1000, rate: 1.0 / 10)
        #expect(hours == "About 3 hr remaining")
        let soon = IndexStatusPresentation.estimatedTimeRemainingText(remaining: 1, rate: 1.0 / 10)
        #expect(soon == "Finishing up…")
    }
}
#endif
