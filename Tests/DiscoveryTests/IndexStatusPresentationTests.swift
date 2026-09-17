#if !os(watchOS)
import XCTest

@testable import TonearmCore
@testable import TonearmDiscovery

/// C07 status-surface view-model mapping (IMPLEMENT_CLAP_PLAN.md §10): the
/// distinct response states must map to distinct display, and diagnostics
/// export must stay redacted (aggregate counts only, no track identity).
final class IndexStatusPresentationTests: XCTestCase {
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
        thermal: ThermalDiagnostic? = nil
    ) -> IndexStatusSnapshot {
        IndexStatusSnapshot(
            coverage: coverage, isPaused: paused, isChargingOnly: chargingOnly,
            modelResourceAvailable: modelAvailable, modelDownloadProgress: downloadProgress,
            runtime: runtime,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            schedulerBlockReason: blockReason,
            thermalDiagnostic: thermal)
    }

    /// Reproduces the user's actual follow-up request: "downloading" with no
    /// size/percentage gives no way to know when it will finish. Real ODR
    /// bytes must flow through to both the detail text and a real progress
    /// fraction — never a fabricated one.
    func testWaitingForModelShowsRealByteProgress() {
        let progress = ModelDownloadProgress(completedBytes: 42 * 1_048_576, totalBytes: 137 * 1_048_576)
        let p = IndexStatusPresentation.make(
            from: snapshot(
                coverage(total: 2694, complete: 0, queuedOrRunning: 2693, waiting: 1),
                modelAvailable: false, downloadProgress: progress))
        XCTAssertEqual(p.phase, .waitingForModel)
        XCTAssertEqual(p.modelDownloadFraction ?? -1, 42.0 / 137.0, accuracy: 0.001)
        XCTAssertTrue(p.detail.contains("42"))
        XCTAssertTrue(p.detail.contains("137"))
        XCTAssertTrue(p.detail.contains("%"))
    }

    /// Before the system has reported any real byte count, the detail stays
    /// honest ("Downloading…", no fabricated 0/0 or 0%) and the fraction is
    /// nil so the view falls back to an indeterminate spinner.
    func testWaitingForModelWithNoByteCountYetShowsNoFabricatedPercentage() {
        let p = IndexStatusPresentation.make(
            from: snapshot(
                coverage(total: 100, complete: 0, waiting: 100),
                modelAvailable: false, downloadProgress: nil))
        XCTAssertEqual(p.phase, .waitingForModel)
        XCTAssertNil(p.modelDownloadFraction)
        XCTAssertFalse(p.detail.contains("%"))
    }

    /// Real-world regression: "it says 'Downloading the sound-search model
    /// - 0 of 0 MB (100%)' and never changes." A negligible total (one tiny
    /// tag finished, the ~137 MB tag never started) must fall back to the
    /// plain "Downloading…" text and a nil progress fraction — never a
    /// nonsensical, actively misleading "0 of 0 MB (100%)."
    func testNegligibleTotalNeverRendersAsFalseCompletion() {
        let negligible = ModelDownloadProgress(completedBytes: 400_000, totalBytes: 400_000)
        let p = IndexStatusPresentation.make(
            from: snapshot(
                coverage(total: 2694, complete: 0, queuedOrRunning: 2693, waiting: 1),
                modelAvailable: false, downloadProgress: negligible))
        XCTAssertEqual(p.phase, .waitingForModel)
        XCTAssertNil(p.modelDownloadFraction, "a negligible total must never render as a real percentage")
        XCTAssertFalse(p.detail.contains("100%"))
        XCTAssertFalse(p.detail.contains("0 of 0"))
        XCTAssertEqual(p.detail, "Downloading the sound-search model…")
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
    func testNegligibleTotalFallsBackToComponentCountNotSilence() {
        let coarseUnits = ModelDownloadProgress(
            completedBytes: 1, totalBytes: 2, componentsFinished: 1, componentsTotal: 2)
        let p = IndexStatusPresentation.make(
            from: snapshot(
                coverage(total: 2694, complete: 0, queuedOrRunning: 2693, waiting: 1),
                modelAvailable: false, downloadProgress: coarseUnits))
        XCTAssertEqual(p.phase, .waitingForModel)
        XCTAssertNil(p.modelDownloadFraction, "coarse unit counts must never render as a real percentage bar")
        XCTAssertEqual(p.detail, "Downloading the sound-search model — 1 of 2 components ready.")
    }

    func testEmptyLibrary() {
        let p = IndexStatusPresentation.make(from: snapshot(coverage(total: 0)))
        XCTAssertEqual(p.phase, .emptyLibrary)
        XCTAssertEqual(p.headline, "Sound index: not started")
        XCTAssertFalse(p.showsBanner)
        XCTAssertFalse(p.canPause)
        XCTAssertFalse(p.canResume)
    }

    func testUpToDate() {
        let p = IndexStatusPresentation.make(from: snapshot(coverage(total: 1042, complete: 1042)))
        XCTAssertEqual(p.phase, .upToDate)
        XCTAssertEqual(p.headline, "Sound index: 1,042 / 1,042 tracks")
        XCTAssertEqual(p.fractionComplete, 1.0)
        XCTAssertTrue(p.showsBanner)
        XCTAssertFalse(p.canPause)
    }

    func testIndexingInProgress() {
        let p = IndexStatusPresentation.make(
            from: snapshot(coverage(total: 1042, complete: 238, queuedOrRunning: 804)))
        XCTAssertEqual(p.phase, .indexing)
        XCTAssertEqual(p.headline, "Sound index: 238 / 1,042 tracks")
        XCTAssertEqual(p.fractionComplete, 238.0 / 1042.0, accuracy: 0.0001)
        XCTAssertTrue(p.canPause)
        XCTAssertFalse(p.canResume)
    }

    func testPausedTakesPrecedenceOverQueuedWork() {
        let p = IndexStatusPresentation.make(
            from: snapshot(coverage(total: 100, complete: 10, queuedOrRunning: 90), paused: true))
        XCTAssertEqual(p.phase, .paused)
        XCTAssertTrue(p.canResume)
        XCTAssertFalse(p.canPause)
    }

    func testWaitingForModelWhenResourcesAbsent() {
        let p = IndexStatusPresentation.make(
            from: snapshot(
                coverage(total: 100, complete: 0, waiting: 100), modelAvailable: false))
        XCTAssertEqual(p.phase, .waitingForModel)
        XCTAssertTrue(p.detail.lowercased().contains("model"))
    }

    /// Reproduces a real production report: bootstrap enqueues every track as
    /// `queuedOrRunning` (only a handful land in the separate `waiting`
    /// bucket), so `queuedOrRunning > 0` was true well before the model ever
    /// resolved — and the generic "Indexing…" branch, checked first, silently
    /// swallowed the model-missing state. Every claimed job re-parks waiting
    /// for the model, so this is permanent, not transient — it must never
    /// read as ordinary progress.
    func testWaitingForModelTakesPrecedenceOverQueuedOrRunning() {
        let p = IndexStatusPresentation.make(
            from: snapshot(
                coverage(total: 2694, complete: 0, queuedOrRunning: 2693, waiting: 1),
                modelAvailable: false))
        XCTAssertEqual(p.phase, .waitingForModel)
        XCTAssertTrue(p.detail.lowercased().contains("model"))
    }

    func testWaitingForPowerIsDistinctFromWaitingForModel() {
        let p = IndexStatusPresentation.make(
            from: snapshot(
                coverage(total: 100, complete: 40, waiting: 60),
                chargingOnly: true, modelAvailable: true))
        XCTAssertEqual(p.phase, .waiting)
        XCTAssertTrue(p.detail.lowercased().contains("power"))
    }

    /// Real user report: "Waiting to continue. Indexing resumes when
    /// conditions allow. That is as much of a non-statement as I've ever
    /// heard." Root cause was `waitingBreakdown` never reaching the
    /// presentation layer at all (`DiscoveryAssembly.drainQueue` discarded
    /// the real per-job reason on every tick). With a real breakdown, the
    /// dominant reason must be named, not the generic text.
    func testWaitingDetailNamesTheDominantRealReason() {
        let p = IndexStatusPresentation.make(
            from: snapshot(
                coverage(
                    total: 100, complete: 90, waiting: 10,
                    waitingBreakdown: [.waitingForAsset: 10])))
        XCTAssertEqual(p.phase, .waiting)
        XCTAssertTrue(p.detail.contains("audio file"), p.detail)
        XCTAssertFalse(p.detail.contains("conditions allow"), p.detail)
    }

    /// The user's other real complaint: "sometimes I see failures but
    /// retrying also fails" — a `.retryScheduled` majority must surface the
    /// actual last error, not just "will retry automatically" with no
    /// explanation of what keeps going wrong.
    func testWaitingDetailForRetrySchedulesSurfacesTheLastError() {
        let p = IndexStatusPresentation.make(
            from: snapshot(
                coverage(
                    total: 100, complete: 90, waiting: 10,
                    waitingBreakdown: [.retryScheduled: 10],
                    mostRecentFailureError: IndexJobRepository.JobErrorSample(
                        code: "windowReadFailed",
                        message: "Could not read audio window from the source file."))))
        XCTAssertEqual(p.phase, .waiting)
        XCTAssertTrue(p.detail.contains("retry automatically"), p.detail)
        XCTAssertTrue(
            p.detail.contains("Could not read audio window from the source file."), p.detail)
    }

    /// A `.waiting` snapshot with no breakdown at all (an older/synthetic
    /// caller) must still fall back to the previous, still-honest generic
    /// text rather than crash or show nothing.
    func testWaitingDetailFallsBackWithoutABreakdown() {
        let p = IndexStatusPresentation.make(
            from: snapshot(coverage(total: 100, complete: 90, waiting: 10)))
        XCTAssertEqual(p.phase, .waiting)
        XCTAssertTrue(p.detail.contains("conditions allow"), p.detail)
    }

    /// The `.needsAttention` (all-failed) detail must also surface the real
    /// last error when one is known — the same non-statement problem
    /// applied to `.failed` jobs, not just `.waiting` ones.
    func testNeedsAttentionSurfacesTheLastRealErrorWhenKnown() {
        let p = IndexStatusPresentation.make(
            from: snapshot(
                coverage(
                    total: 100, complete: 95, failed: 5,
                    mostRecentFailureError: IndexJobRepository.JobErrorSample(
                        code: "embedFailed", message: "Model inference failed."))))
        XCTAssertEqual(p.phase, .needsAttention)
        XCTAssertTrue(p.detail.contains("Model inference failed."), p.detail)
    }

    func testNeedsAttentionWhenOnlyFailures() {
        let p = IndexStatusPresentation.make(
            from: snapshot(coverage(total: 100, complete: 95, failed: 5)))
        XCTAssertEqual(p.phase, .needsAttention)
        XCTAssertTrue(p.canRetryFailed)
        XCTAssertEqual(p.failedCount, 5)
    }

    func testRetryOfferedEvenWhileIndexingContinues() {
        let p = IndexStatusPresentation.make(
            from: snapshot(coverage(total: 100, complete: 50, queuedOrRunning: 45, failed: 5)))
        XCTAssertEqual(p.phase, .indexing)
        XCTAssertTrue(p.canRetryFailed)
    }

    /// The regression this fix is for: real user report was "Sound Index
    /// says 0/2364 tracks... after 5+ minutes, not a single track has been
    /// indexed... [status screen] just says indexing, nothing about
    /// downloading, waiting, no progress ever evident." Before the fix,
    /// `schedulerBlockReason` did not exist and this exact
    /// coverage (all jobs queued, zero complete) produced `.indexing` with a
    /// generic "Indexing N tracks…" detail no matter what was actually
    /// blocking the scheduler underneath.
    func testBlockedSchedulerNeverShownAsGenericIndexing() {
        let p = IndexStatusPresentation.make(
            from: snapshot(
                coverage(total: 2364, complete: 0, queuedOrRunning: 2364),
                blockReason: .thermalFair))
        XCTAssertEqual(p.phase, .blockedByPolicy)
        XCTAssertNotEqual(p.phase, .indexing)
        XCTAssertFalse(
            p.detail.lowercased().hasPrefix("indexing"),
            "must surface the real reason, not the generic indexing label")
        XCTAssertTrue(p.detail.lowercased().contains("cool down"))
        // The headline (raw counts) is unaffected — only `detail`/`phase`
        // change; "0 / 2,364" must still read exactly as reported.
        XCTAssertEqual(p.headline, "Sound index: 0 / 2,364 tracks")
    }

    /// The actual bug report this answers: "it always says waiting for the device to cool down,
    /// but the device is NOT hot." Root cause was `IndexPolicy`'s `.fair` recovery rule blocking
    /// on `continuousNominalSeconds < 60` even while the device had already returned to
    /// `.nominal` — collapsed into the same "cool down" text as an actually-hot device. With a
    /// real `ThermalDiagnostic`, a currently-`.nominal` block must read as genuinely different
    /// from a currently-`.serious`/`.critical` one, and must say real numbers, not just a label.
    func testThermalDetailDistinguishesRecoveringFromActuallyHot() {
        let recovering = IndexStatusPresentation.make(
            from: snapshot(
                coverage(total: 10, complete: 0, queuedOrRunning: 10), blockReason: .thermalFair,
                thermal: ThermalDiagnostic(state: .nominal, continuousNominalSeconds: 37)))
        XCTAssertTrue(recovering.detail.lowercased().contains("normal"),
                      "a currently-nominal device must not read as hot: \(recovering.detail)")
        XCTAssertTrue(recovering.detail.contains("23"),
                      "must show the real seconds remaining (60 - 37 = 23): \(recovering.detail)")

        let actuallyHot = IndexStatusPresentation.make(
            from: snapshot(
                coverage(total: 10, complete: 0, queuedOrRunning: 10), blockReason: .thermalSerious,
                thermal: ThermalDiagnostic(state: .serious, continuousNominalSeconds: 0)))
        XCTAssertTrue(actuallyHot.detail.lowercased().contains("hot"),
                      "a genuinely serious/critical state must say so: \(actuallyHot.detail)")

        XCTAssertNotEqual(recovering.detail, actuallyHot.detail)
    }

    func testEachPolicyBlockReasonHasADistinctNonGenericDetail() {
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
            XCTAssertEqual(p.phase, .blockedByPolicy, "\(reason)")
            XCTAssertFalse(p.detail.isEmpty, "\(reason)")
            seenDetails.insert(p.detail)
        }
        // Thermal variants intentionally share one user-facing message;
        // otherwise every reason should read distinctly.
        XCTAssertGreaterThanOrEqual(seenDetails.count, reasons.count - 2)
    }

    /// `userPaused` already has its own dedicated, higher-priority phase
    /// (`.paused`, checked via `snapshot.isPaused`) — a leftover
    /// `schedulerBlockReason == .userPaused` from a stale tick must not
    /// create a second, redundant "blocked" phase.
    func testStaleUserPausedBlockReasonDoesNotOverrideNormalIndexing() {
        let p = IndexStatusPresentation.make(
            from: snapshot(
                coverage(total: 10, complete: 2, queuedOrRunning: 8),
                blockReason: .userPaused))
        XCTAssertEqual(p.phase, .indexing)
    }

    func testDiagnosticsAreRedactedAggregatesOnly() {
        let runtime = DiscoveryRuntime(
            id: 1, lastRunAt: Date(timeIntervalSince1970: 1_700_000_100),
            lastStopReason: "background: 3 completed")
        let snap = snapshot(
            coverage(total: 10, complete: 4, waiting: 6), modelAvailable: false, runtime: runtime)
        let diag = DiscoveryDiagnostics.make(
            snapshot: snap, appVersion: "1.2.3", buildNumber: "456",
            osVersion: "iOS 18.5", deviceFamily: "iPhone")

        let json = diag.jsonString()
        XCTAssertTrue(json.contains("\"tracksTotal\" : 10"))
        XCTAssertTrue(json.contains("\"tracksFailed\" : 0"))
        XCTAssertTrue(json.contains("background: 3 completed"))
        // No identity leakage vectors.
        XCTAssertFalse(json.lowercased().contains("http"))
        XCTAssertFalse(json.lowercased().contains("file://"))
        XCTAssertFalse(json.lowercased().contains("token"))
        XCTAssertFalse(json.lowercased().contains("bookmark"))

        let text = diag.plainText()
        XCTAssertTrue(text.contains("10 total"))
        XCTAssertTrue(text.contains("1.2.3 (456)"))
    }
}

/// `ModelDownloadProgress.aggregate(_:)` turns the live
/// `NSBundleResourceRequest.progress` objects (Xcode-only,
/// `Sources/App/DiscoveryModelResources.swift`, not reachable from
/// `swift test`) into `RequestSample` values first specifically so this
/// byte-math has a real regression test — the previous version of this
/// logic lived entirely in that untestable file and shipped a bug that
/// only a real device could surface.
final class ModelDownloadProgressAggregateTests: XCTestCase {
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
    func testFinishedTagStillCountsWhileTheOtherHasNotStartedYet() {
        let audioFinished = Sample(
            completedBytes: 137 * 1_048_576, totalBytes: 137 * 1_048_576, isFinished: true)
        let textNotStarted = Sample(completedBytes: 0, totalBytes: 0, isFinished: false)

        let result = ModelDownloadProgress.aggregate([audioFinished, textNotStarted])

        XCTAssertNotNil(result, "a finished tag's bytes must not disappear from the total")
        XCTAssertEqual(result?.completedBytes, 137 * 1_048_576)
        XCTAssertEqual(result?.totalBytes, 137 * 1_048_576)
    }

    /// Once the second tag starts reporting its own (small) total, it joins
    /// the running total rather than replacing it.
    func testBothTagsSumOnceTheSecondOneStarts() {
        let audioFinished = Sample(
            completedBytes: 137 * 1_048_576, totalBytes: 137 * 1_048_576, isFinished: true)
        let textInProgress = Sample(
            completedBytes: 1 * 1_048_576, totalBytes: 4 * 1_048_576, isFinished: false)

        let result = ModelDownloadProgress.aggregate([audioFinished, textInProgress])

        XCTAssertEqual(result?.completedBytes, 138 * 1_048_576)
        XCTAssertEqual(result?.totalBytes, 141 * 1_048_576)
    }

    /// Before either tag has reported a byte count at all (both still
    /// `totalBytes == 0`), there is nothing real to show — `nil`, never a
    /// fabricated 0%.
    func testNilBeforeEitherTagReportsAnyBytes() {
        let neitherStarted = [Sample(completedBytes: 0, totalBytes: 0, isFinished: false),
            Sample(completedBytes: 0, totalBytes: 0, isFinished: false)]
        XCTAssertNil(ModelDownloadProgress.aggregate(neitherStarted))
    }

    /// Once every tag is finished, both are still summed (100%) — the
    /// caller (`DiscoveryAssembly.statusSnapshot()`) is what stops asking
    /// for this once `modelResourceAvailable` is true, not this function.
    func testBothTagsFinishedStillReportsAFullFraction() {
        let bothDone = [
            Sample(completedBytes: 137 * 1_048_576, totalBytes: 137 * 1_048_576, isFinished: true),
            Sample(completedBytes: 4 * 1_048_576, totalBytes: 4 * 1_048_576, isFinished: true),
        ]
        let result = ModelDownloadProgress.aggregate(bothDone)
        XCTAssertEqual(result?.fractionComplete, 1.0)
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
    func testTotalUnderOneMBIsNegligible() {
        let textFinishedAudioNeverStarted = ModelDownloadProgress(
            completedBytes: 400_000, totalBytes: 400_000)
        XCTAssertTrue(textFinishedAudioNeverStarted.isNegligibleTotal)
        XCTAssertEqual(textFinishedAudioNeverStarted.fractionComplete, 1.0,
            "the math itself is correct — isNegligibleTotal is what must gate display, not fractionComplete")
    }

    func testTotalOfSeveralMBIsNotNegligible() {
        let real = ModelDownloadProgress(completedBytes: 42 * 1_048_576, totalBytes: 137 * 1_048_576)
        XCTAssertFalse(real.isNegligibleTotal)
    }
}
#endif
