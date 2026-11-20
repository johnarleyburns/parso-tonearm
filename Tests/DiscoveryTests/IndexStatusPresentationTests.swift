#if !os(watchOS)
import Foundation
import Testing

@testable import TonearmCore
@testable import TonearmDiscovery

/// C07 status-surface view-model mapping (IMPLEMENT_CLAP_PLAN.md §10): the
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
        paused: Bool = false, chargingOnly: Bool = false, modelAvailable: Bool = true,
        downloadProgress: ModelDownloadProgress? = nil,
        runtime: DiscoveryRuntime = DiscoveryRuntime(id: 1),
        blockReason: IndexBlockReason? = nil,
        thermal: ThermalDiagnostic? = nil,
        currentlyIndexingTrack: IndexJobRepository.RunningTrackSummary? = nil,
        recentCompletionRate: Double? = nil
    ) -> IndexStatusSnapshot {
        IndexStatusSnapshot(
            coverage: coverage, isPaused: paused, isChargingOnly: chargingOnly,
            modelResourceAvailable: modelAvailable, modelDownloadProgress: downloadProgress,
            runtime: runtime,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            schedulerBlockReason: blockReason,
            thermalDiagnostic: thermal,
            currentlyIndexingTrack: currentlyIndexingTrack,
            recentCompletionRate: recentCompletionRate)
    }

    /// Reproduces the user's actual follow-up request: "downloading" with no
    /// size/percentage gives no way to know when it will finish. Real ODR
    /// bytes must flow through to both the detail text and a real progress
    /// fraction — never a fabricated one.
    @Test func testWaitingForModelShowsRealByteProgress() {
        let progress = ModelDownloadProgress(completedBytes: 42 * 1_048_576, totalBytes: 137 * 1_048_576)
        let p = IndexStatusPresentation.make(
            from: snapshot(
                coverage(total: 2694, complete: 0, queuedOrRunning: 2693, waiting: 1),
                modelAvailable: false, downloadProgress: progress))
        #expect(p.phase == .waitingForModel)
        #expect(abs((p.modelDownloadFraction ?? -1) - 42.0 / 137.0) <= 0.001)
        #expect(p.detail.contains("42"))
        #expect(p.detail.contains("137"))
        #expect(p.detail.contains("%"))
    }

    /// Before the system has reported any real byte count, the detail stays
    /// honest ("Downloading…", no fabricated 0/0 or 0%) and the fraction is
    /// nil so the view falls back to an indeterminate spinner.
    @Test func testWaitingForModelWithNoByteCountYetShowsNoFabricatedPercentage() {
        let p = IndexStatusPresentation.make(
            from: snapshot(
                coverage(total: 100, complete: 0, waiting: 100),
                modelAvailable: false, downloadProgress: nil))
        #expect(p.phase == .waitingForModel)
        #expect(p.modelDownloadFraction == nil)
        #expect(!p.detail.contains("%"))
    }

    /// Real-world regression: "it says 'Downloading the sound-search model
    /// - 0 of 0 MB (100%)' and never changes." A negligible total (one tiny
    /// tag finished, the ~137 MB tag never started) must fall back to the
    /// plain "Downloading…" text and a nil progress fraction — never a
    /// nonsensical, actively misleading "0 of 0 MB (100%)."
    @Test func testNegligibleTotalNeverRendersAsFalseCompletion() {
        let negligible = ModelDownloadProgress(completedBytes: 400_000, totalBytes: 400_000)
        let p = IndexStatusPresentation.make(
            from: snapshot(
                coverage(total: 2694, complete: 0, queuedOrRunning: 2693, waiting: 1),
                modelAvailable: false, downloadProgress: negligible))
        #expect(p.phase == .waitingForModel)
        #expect(p.modelDownloadFraction == nil, "a negligible total must never render as a real percentage")
        #expect(!p.detail.contains("100%"))
        #expect(!p.detail.contains("0 of 0"))
        #expect(p.detail == "Downloading the sound-search model…")
    }

    /// Real device diagnostics export (build 368): "no progress on the
    /// download, same thing" — `clap-audio: 1/1 bytes (finished);
    /// clap-text: 0/1 bytes (in progress)`. `NSBundleResourceRequest`
    /// doesn't guarantee real bytes here (Apple: implementation-defined,
    /// "often simply 1"), so `isNegligibleTotal` is true and the previous
    /// "0 of 0 MB (100%)" fix already stops it from lying — but a flat
    /// "Downloading…" with no numbers throws away the one thing that IS
    /// real here: one of the two components has genuinely finished. The
    /// detail must say so.
    @Test func testNegligibleTotalFallsBackToComponentCountNotSilence() {
        let coarseUnits = ModelDownloadProgress(
            completedBytes: 1, totalBytes: 2, componentsFinished: 1, componentsTotal: 2)
        let p = IndexStatusPresentation.make(
            from: snapshot(
                coverage(total: 2694, complete: 0, queuedOrRunning: 2693, waiting: 1),
                modelAvailable: false, downloadProgress: coarseUnits))
        #expect(p.phase == .waitingForModel)
        #expect(p.modelDownloadFraction == nil, "coarse unit counts must never render as a real percentage bar")
        #expect(p.detail == "Downloading the sound-search model — 1 of 2 components ready.")
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

    @Test func testWaitingForModelWhenResourcesAbsent() {
        let p = IndexStatusPresentation.make(
            from: snapshot(
                coverage(total: 100, complete: 0, waiting: 100), modelAvailable: false))
        #expect(p.phase == .waitingForModel)
        #expect(p.detail.lowercased().contains("model"))
    }

    /// Reproduces a real production report: bootstrap enqueues every track as
    /// `queuedOrRunning` (only a handful land in the separate `waiting`
    /// bucket), so `queuedOrRunning > 0` was true well before the model ever
    /// resolved — and the generic "Indexing…" branch, checked first, silently
    /// swallowed the model-missing state. Every claimed job re-parks waiting
    /// for the model, so this is permanent, not transient — it must never
    /// read as ordinary progress.
    @Test func testWaitingForModelTakesPrecedenceOverQueuedOrRunning() {
        let p = IndexStatusPresentation.make(
            from: snapshot(
                coverage(total: 2694, complete: 0, queuedOrRunning: 2693, waiting: 1),
                modelAvailable: false))
        #expect(p.phase == .waitingForModel)
        #expect(p.detail.lowercased().contains("model"))
    }

    @Test func testWaitingForPowerIsDistinctFromWaitingForModel() {
        let p = IndexStatusPresentation.make(
            from: snapshot(
                coverage(total: 100, complete: 40, waiting: 60),
                chargingOnly: true, modelAvailable: true))
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
                        code: "embedFailed", message: "Model inference failed."))))
        #expect(p.phase == .needsAttention)
        #expect(p.detail.contains("Model inference failed."), "\(p.detail)")
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
            .playbackActive, .thermalFair, .thermalSerious, .thermalCritical,
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
            coverage(total: 10, complete: 4, waiting: 6), modelAvailable: false, runtime: runtime)
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

    // MARK: - Live per-track progress + ETA (real report: "what track is being indexed, the %
    // progress of the INDIVIDUAL TRACK... ETAs for completing all indexing")

    @Test func testCurrentTrackAndETAShowOnlyWhileActivelyIndexing() {
        let track = IndexJobRepository.RunningTrackSummary(
            id: 1, title: "Some Song", artistName: "Some Artist", completedWindows: 3, totalWindows: 10)
        let p = IndexStatusPresentation.make(
            from: snapshot(
                coverage(total: 50, complete: 10, queuedOrRunning: 40),
                currentlyIndexingTrack: track, recentCompletionRate: 1.0 / 60))
        #expect(p.phase == .indexing)
        #expect(p.currentTrackTitle == "Some Song")
        #expect(p.currentTrackArtist == "Some Artist")
        #expect(p.currentTrackFraction == 0.3)
        #expect(p.estimatedTimeRemainingText != nil)
    }

    /// Real risk this guards against: a job can hold a `running` lease while the scheduler is
    /// genuinely blocked (thermal/battery/playback) — `coverage` alone can't tell that apart from
    /// real progress. Showing "30%" and an ETA for a track that is NOT actually advancing would be
    /// exactly the fabricated-progress CLAUDE.md forbids.
    @Test func testCurrentTrackAndETAAreSuppressedWhenBlockedByPolicyDespiteARunningLease() {
        let track = IndexJobRepository.RunningTrackSummary(
            id: 1, title: "Stuck Song", artistName: nil, completedWindows: 1, totalWindows: 10)
        let p = IndexStatusPresentation.make(
            from: snapshot(
                coverage(total: 50, complete: 10, queuedOrRunning: 40),
                blockReason: .thermalSerious,
                currentlyIndexingTrack: track, recentCompletionRate: 1.0 / 60))
        #expect(p.phase == .blockedByPolicy)
        #expect(p.currentTrackTitle == nil)
        #expect(p.estimatedTimeRemainingText == nil)
    }
}

/// `ModelDownloadProgress.aggregate(_:)` turns the live
/// `NSBundleResourceRequest.progress` objects (Xcode-only,
/// `Sources/App/DiscoveryModelResources.swift`, not reachable from
/// `swift test`) into `RequestSample` values first specifically so this
/// byte-math has a real regression test — the previous version of this
/// logic lived entirely in that untestable file and shipped a bug that
/// only a real device could surface.
@Suite struct ModelDownloadProgressAggregateTests {
    private typealias Sample = ModelDownloadProgress.RequestSample

    /// The exact real-world report this regression test is for: "0%, then
    /// 50%, then 'Downloading the sound-search model...' with no progress
    /// update ever again." The `clap-audio` tag (~137 MB) finishes while
    /// `clap-text` (a few KB) hasn't reported a byte count yet — the old
    /// `aggregate` required at least one sample to still be `!isFinished`
    /// before returning anything, so this combination (one finished, one
    /// not-yet-started) satisfied neither branch and silently produced
    /// `nil`, regressing the status surface from a real percentage back to
    /// a bare "Downloading…" for as long as the second tag took to start.
    @Test func testFinishedTagStillCountsWhileTheOtherHasNotStartedYet() {
        let audioFinished = Sample(
            completedBytes: 137 * 1_048_576, totalBytes: 137 * 1_048_576, isFinished: true)
        let textNotStarted = Sample(completedBytes: 0, totalBytes: 0, isFinished: false)

        let result = ModelDownloadProgress.aggregate([audioFinished, textNotStarted])

        #expect(result != nil, "a finished tag's bytes must not disappear from the total")
        #expect(result?.completedBytes == Int64(137 * 1_048_576))
        #expect(result?.totalBytes == Int64(137 * 1_048_576))
    }

    /// Once the second tag starts reporting its own (small) total, it joins
    /// the running total rather than replacing it.
    @Test func testBothTagsSumOnceTheSecondOneStarts() {
        let audioFinished = Sample(
            completedBytes: 137 * 1_048_576, totalBytes: 137 * 1_048_576, isFinished: true)
        let textInProgress = Sample(
            completedBytes: 1 * 1_048_576, totalBytes: 4 * 1_048_576, isFinished: false)

        let result = ModelDownloadProgress.aggregate([audioFinished, textInProgress])

        #expect(result?.completedBytes == Int64(138 * 1_048_576))
        #expect(result?.totalBytes == Int64(141 * 1_048_576))
    }

    /// Before either tag has reported a byte count at all (both still
    /// `totalBytes == 0`), there is nothing real to show — `nil`, never a
    /// fabricated 0%.
    @Test func testNilBeforeEitherTagReportsAnyBytes() {
        let neitherStarted = [Sample(completedBytes: 0, totalBytes: 0, isFinished: false),
            Sample(completedBytes: 0, totalBytes: 0, isFinished: false)]
        #expect(ModelDownloadProgress.aggregate(neitherStarted) == nil)
    }

    /// Once every tag is finished, both are still summed (100%) — the
    /// caller (`DiscoveryAssembly.statusSnapshot()`) is what stops asking
    /// for this once `modelResourceAvailable` is true, not this function.
    @Test func testBothTagsFinishedStillReportsAFullFraction() {
        let bothDone = [
            Sample(completedBytes: 137 * 1_048_576, totalBytes: 137 * 1_048_576, isFinished: true),
            Sample(completedBytes: 4 * 1_048_576, totalBytes: 4 * 1_048_576, isFinished: true),
        ]
        let result = ModelDownloadProgress.aggregate(bothDone)
        #expect(result?.fractionComplete == 1.0)
    }

    /// The very next real-world report after the fix above shipped: "it
    /// says 'Downloading the sound-search model - 0 of 0 MB (100%)' and
    /// never changes." The small `clap-text` tag finished (or reported a
    /// trivial total under 1 MB) while the ~137 MB `clap-audio` tag never
    /// reported any bytes at all (`totalBytes == 0`) — `aggregate` correctly
    /// summed only the finished sliver, so `completed == total` and
    /// `fractionComplete` legitimately computed to 1.0, but both numbers
    /// round to 0 MB. Displaying that combination ("0 of 0 MB (100%)") is
    /// actively misleading, not just uninformative — it implies the
    /// download is done when the large component hasn't even started.
    /// `isNegligibleTotal` is the guard the presentation layer must check
    /// before trusting this progress for display.
    @Test func testTotalUnderOneMBIsNegligible() {
        let textFinishedAudioNeverStarted = ModelDownloadProgress(
            completedBytes: 400_000, totalBytes: 400_000)
        #expect(textFinishedAudioNeverStarted.isNegligibleTotal)
        #expect(textFinishedAudioNeverStarted.fractionComplete == 1.0,
            "the math itself is correct — isNegligibleTotal is what must gate display, not fractionComplete")
    }

    @Test func testTotalOfSeveralMBIsNotNegligible() {
        let real = ModelDownloadProgress(completedBytes: 42 * 1_048_576, totalBytes: 137 * 1_048_576)
        #expect(!real.isNegligibleTotal)
    }

    // MARK: - Live per-track progress + ETA (real report: "what track is being indexed, the %
    // progress of the INDIVIDUAL TRACK... ETAs for completing all indexing") -- the two tests
    // actually requiring IndexStatusPresentationTests' own coverage()/snapshot() helpers live
    // there instead (this class has no access to another class' private members); these two
    // below are pure IndexStatusPresentation statics, which don't need those helpers at all.

    @Test func testEstimatedTimeRemainingTextIsNeverFabricatedWithoutARealRate() {
        #expect(IndexStatusPresentation.estimatedTimeRemainingText(remaining: 100, rate: nil) == nil)
        #expect(IndexStatusPresentation.estimatedTimeRemainingText(remaining: 0, rate: 1.0 / 60) == nil)
        #expect(IndexStatusPresentation.estimatedTimeRemainingText(remaining: 100, rate: 0) == nil)
    }

    @Test func testEstimatedTimeRemainingTextRoundsToCoarseHonestUnits() {
        // 10 remaining at 1 track/10s = 100s -> minutes bucket, rounds to nearest minute.
        let minutes = IndexStatusPresentation.estimatedTimeRemainingText(remaining: 10, rate: 1.0 / 10)
        #expect(minutes == "About 2 min remaining")

        // 1000 remaining at 1 track/10s = 10,000s (~2.78h) -> hours bucket.
        let hours = IndexStatusPresentation.estimatedTimeRemainingText(remaining: 1000, rate: 1.0 / 10)
        #expect(hours == "About 3 hr remaining")

        // Under a minute remaining -> no false minute-precision, just "finishing up".
        let soon = IndexStatusPresentation.estimatedTimeRemainingText(remaining: 1, rate: 1.0 / 10)
        #expect(soon == "Finishing up…")
    }
}
#endif
