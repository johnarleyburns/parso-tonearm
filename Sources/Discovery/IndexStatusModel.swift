#if !os(watchOS)
import Foundation
import TonearmCore

/// Real, in-progress On-Demand-Resource download bytes for the CLAP model
/// package(s) (plan CLAUDE.md "no silent/magic background work" — a
/// `waitingForModel` state with no size/percentage is indistinguishable from
/// stuck, so this is what lets the status surface say how far along it is
/// and how much is left, not just "downloading"). `nil` when nothing is
/// currently downloading (not yet started, already resolved, or genuinely
/// failed) — never a fabricated fraction.
public struct ModelDownloadProgress: Equatable, Sendable {
    public var completedBytes: Int64
    public var totalBytes: Int64
    /// How many of the ODR tags (`clap-audio`, `clap-text`) have finished,
    /// out of how many are being tracked. `NSBundleResourceRequest.progress`
    /// does NOT guarantee `completedUnitCount`/`totalUnitCount` are real
    /// bytes — Apple documents the unit as implementation-defined, "often
    /// simply 1" (confirmed on a real device: a diagnostics export showed
    /// literally `clap-audio: 1/1 bytes (finished); clap-text: 0/1 bytes (in
    /// progress)` for a real 123 MB and 221 MB package). `completedBytes`/
    /// `totalBytes` above are real when the system happens to report real
    /// byte counts, but `componentsFinished`/`componentsTotal` is the signal
    /// that's ALWAYS meaningful regardless of what unit scheme is active —
    /// it's what lets the status surface say "1 of 2 ready" honestly even
    /// when the byte total is too small to trust (see `isNegligibleTotal`).
    public var componentsFinished: Int
    public var componentsTotal: Int

    public init(
        completedBytes: Int64, totalBytes: Int64,
        componentsFinished: Int = 0, componentsTotal: Int = 0
    ) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.componentsFinished = componentsFinished
        self.componentsTotal = componentsTotal
    }

    /// `nil` when `totalBytes` isn't known yet (the system hasn't reported a
    /// real byte count) — never defaulted to 0 or 1, which would render as a
    /// false 0% or 100%.
    public var fractionComplete: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }

    /// One `NSBundleResourceRequest`'s reported bytes, as a plain value —
    /// the seam that makes `aggregate(_:)` testable under `swift test`
    /// without a real ODR fetch (the request objects themselves live in
    /// `Sources/App/`, Xcode-only, and can't be constructed in a SwiftPM
    /// test target).
    public struct RequestSample: Equatable, Sendable {
        public var completedBytes: Int64
        public var totalBytes: Int64
        public var isFinished: Bool

        public init(completedBytes: Int64, totalBytes: Int64, isFinished: Bool) {
            self.completedBytes = completedBytes
            self.totalBytes = totalBytes
            self.isFinished = isFinished
        }
    }

    /// Sums whatever byte counts the ODR system has reported across every
    /// tag's request, whether or not each individual one has already
    /// finished. A sample with `totalBytes <= 0` is skipped (that tag hasn't
    /// started downloading, or the system hasn't reported a length yet) —
    /// but a *finished* sample is still counted in the sum. Also tallies
    /// `componentsFinished`/`componentsTotal` (see that field's doc) since
    /// the byte counts here are frequently NOT real bytes at all.
    ///
    /// This used to require at least one sample to still be
    /// `!isFinished` ("in flight") before reporting anything, which was
    /// wrong: the two tags (`clap-audio` ~123 MB, `clap-text` ~221 MB —
    /// both real CoreML packages, not "a few KB" as an earlier version of
    /// this comment assumed) resolve independently, so it's normal for one
    /// to finish while the other hasn't even started yet (`totalBytes ==
    /// 0`). That combination made every sample fail the old gate — the
    /// finished one because it was no longer "in flight", the not-yet-started
    /// one because its total was zero — so this returned `nil` and the
    /// status surface silently regressed from a real percentage back to a
    /// bare "Downloading…" with no numbers, for as long as the second tag
    /// took to start (real user report: "0%, then 50%, then 'Downloading
    /// the sound-search model...' with no progress update ever again").
    /// Requiring only `total > 0` (not "and still in flight") fixes it: the
    /// finished tag's bytes still count toward the running total until the
    /// *other* tag also reports one.
    public static func aggregate(_ samples: [RequestSample]) -> ModelDownloadProgress? {
        var completed: Int64 = 0
        var total: Int64 = 0
        for sample in samples where sample.totalBytes > 0 {
            completed += sample.completedBytes
            total += sample.totalBytes
        }
        guard total > 0 else { return nil }
        let finished = samples.filter(\.isFinished).count
        return ModelDownloadProgress(
            completedBytes: completed, totalBytes: total,
            componentsFinished: finished, componentsTotal: samples.count)
    }

    /// True when `totalBytes`, rounded to the nearest MB, is 0. Two real
    /// reports established why this guard exists and what it actually
    /// means: first, one tag finished while the other hadn't reported any
    /// bytes yet, making the summed total a tiny sliver of the true ~344 MB
    /// combined size; then, a device diagnostics export showed the real
    /// mechanism — `NSBundleResourceRequest.progress` doesn't guarantee its
    /// unit is bytes at all (Apple documents it as implementation-defined,
    /// "often simply 1"), and on that device BOTH tags were reporting
    /// literal `totalUnitCount == 1`. That combination made
    /// `completedBytes == totalBytes` legitimately true (`fractionComplete
    /// == 1.0`) while both rounded to 0 MB, rendering as the actively
    /// misleading "Downloading the sound-search model — 0 of 0 MB (100%)."
    /// This is the guard that keeps a total this small from ever being
    /// trusted as real bytes — the presentation layer falls back to
    /// `componentsFinished`/`componentsTotal` instead, which stays honest
    /// no matter which unit scheme the system is actually using.
    public var isNegligibleTotal: Bool {
        // Same MB rounding as the detail text uses, so "negligible" and
        // "what actually gets displayed" never disagree at the boundary.
        Int((Double(totalBytes) / 1_048_576).rounded()) == 0
    }
}

/// A consistent snapshot of the indexing subsystem's persisted state, gathered
/// off the main actor by `DiscoveryAssembly.statusSnapshot()` and mapped to
/// display by `IndexStatusPresentation` (plan §10: the status surface reads
/// real persisted services — `IndexJobRepository.coverage`,
/// `DiscoverySettingsStore`, `discovery_runtime` — never a mock).
public struct IndexStatusSnapshot: Equatable, Sendable {
    public var coverage: IndexJobRepository.Coverage
    public var isPaused: Bool
    public var isChargingOnly: Bool
    public var modelResourceAvailable: Bool
    /// Real ODR download bytes while the model is fetching; `nil` when
    /// nothing is currently downloading.
    public var modelDownloadProgress: ModelDownloadProgress?
    /// The most recent `beginAccessingResources` failure, if any — a stalled
    /// download is not always "still fetching" (no network, low disk space,
    /// an unknown-resource error); this is what tells the difference instead
    /// of leaving the user staring at "Downloading…" forever with no real
    /// information (CLAUDE.md "no silent/magic background work"). The
    /// request retries itself with backoff, so this clears once a retry
    /// succeeds.
    public var modelDownloadError: String?
    /// A per-tag byte breakdown (e.g. "clap-audio: 0/0 bytes (not
    /// started); clap-text: 51200/51200 bytes (finished)"), diagnostics-only
    /// — the combined `modelDownloadProgress` can't tell "one tag finished
    /// while the other is genuinely stuck at zero" apart from "both
    /// progressing normally," which a diagnostics export needs in order to
    /// say which tag isn't moving instead of one ambiguous blended number.
    public var modelDownloadTagDebug: String?
    public var runtime: DiscoveryRuntime
    public var capturedAt: Date
    /// The real `IndexPolicy` gate that most recently kept the scheduler from
    /// claiming/continuing work, or `nil` when nothing is currently blocking
    /// it. A job blocked before it is ever claimed stays `.queued` (plan §6:
    /// most policy gates are scheduler-level, not a per-job state), so
    /// `coverage` alone cannot tell "actively indexing" apart from "wedged
    /// behind thermal/battery/playback/background-grant, zero progress" —
    /// this field is what lets the status surface say which one it is.
    public var schedulerBlockReason: IndexBlockReason?

    public init(
        coverage: IndexJobRepository.Coverage,
        isPaused: Bool,
        isChargingOnly: Bool,
        modelResourceAvailable: Bool,
        modelDownloadProgress: ModelDownloadProgress? = nil,
        modelDownloadError: String? = nil,
        modelDownloadTagDebug: String? = nil,
        runtime: DiscoveryRuntime,
        capturedAt: Date = Date(),
        schedulerBlockReason: IndexBlockReason? = nil
    ) {
        self.coverage = coverage
        self.isPaused = isPaused
        self.isChargingOnly = isChargingOnly
        self.modelResourceAvailable = modelResourceAvailable
        self.modelDownloadProgress = modelDownloadProgress
        self.modelDownloadError = modelDownloadError
        self.modelDownloadTagDebug = modelDownloadTagDebug
        self.runtime = runtime
        self.capturedAt = capturedAt
        self.schedulerBlockReason = schedulerBlockReason
    }
}

/// The distinct response states the status surface must tell apart (plan §9:
/// "A fresh empty library, empty scope, zero indexed tracks, indexing in
/// progress, model missing, model download failed, no matches and source
/// unavailable are distinct response states").
public enum IndexStatusPhase: String, Equatable, Sendable {
    case emptyLibrary
    case upToDate
    case indexing
    case paused
    case waitingForModel
    case waiting
    /// Jobs are queued but the scheduler itself is gated — thermal, battery,
    /// playback, memory pressure or a missing background-processing grant —
    /// so, unlike `.indexing`, there is currently zero real progress and a
    /// specific, real reason to show (never a generic "Indexing…").
    case blockedByPolicy
    case needsAttention
    case idle
}

/// Pure state → display mapping. No formatting of track titles or file paths —
/// this layer only ever sees aggregate counts (plan §10.6 redaction).
public struct IndexStatusPresentation: Equatable, Sendable {
    public var phase: IndexStatusPhase
    public var headline: String
    public var detail: String
    public var fractionComplete: Double
    /// Real ODR download fraction while `.waitingForModel`'s bytes are
    /// known; `nil` otherwise (including "downloading but no byte count
    /// yet") so the view can fall back to an indeterminate spinner instead
    /// of drawing a fabricated 0%.
    public var modelDownloadFraction: Double?
    public var showsBanner: Bool
    public var canPause: Bool
    public var canResume: Bool
    public var canRetryFailed: Bool
    public var failedCount: Int

    public static func make(from snapshot: IndexStatusSnapshot) -> IndexStatusPresentation {
        let c = snapshot.coverage
        let total = c.total
        let done = c.complete
        let fraction = total > 0 ? min(1.0, Double(done) / Double(total)) : 0

        let headline: String
        if total == 0 {
            headline = "Sound index: not started"
        } else {
            headline = "Sound index: \(number(done)) / \(number(total)) tracks"
        }

        let canRetry = c.failed > 0
        var phase: IndexStatusPhase = .idle
        var detail = ""

        if total == 0 {
            phase = .emptyLibrary
            detail = "Add music to start building the sound index."
        } else if snapshot.isPaused {
            phase = .paused
            detail = "Paused. Resume to continue indexing."
        } else if done == total && c.waiting == 0 && c.queuedOrRunning == 0 && c.failed == 0 {
            phase = .upToDate
            detail = "All music is indexed."
        } else if (c.queuedOrRunning > 0 || c.waiting > 0) && !snapshot.modelResourceAvailable {
            // The model resource (ODR download) hasn't resolved yet. Every
            // claimed job immediately re-parks waiting for it, so
            // queuedOrRunning stays permanently nonzero and would otherwise
            // read as "Indexing…" forever — indistinguishable from real
            // progress. This must be checked before the queuedOrRunning
            // branch below, the same reason schedulerBlockReason is:
            // "jobs exist" does not mean "jobs are progressing."
            phase = .waitingForModel
            detail = Self.detail(
                forModelDownload: snapshot.modelDownloadProgress, error: snapshot.modelDownloadError)
        } else if c.queuedOrRunning > 0, let reason = snapshot.schedulerBlockReason,
            reason != .userPaused
        {
            // Jobs exist and are counted as "queued/running", but the
            // scheduler itself is gated and has made zero progress against
            // them — never collapse this into the generic "Indexing…" label
            // (that label implies real progress is happening).
            phase = .blockedByPolicy
            detail = Self.detail(forBlockedBy: reason, chargingOnly: snapshot.isChargingOnly)
        } else if c.queuedOrRunning > 0 {
            phase = .indexing
            detail = "Indexing \(number(c.queuedOrRunning)) track\(c.queuedOrRunning == 1 ? "" : "s")…"
        } else if c.waiting > 0 {
            phase = .waiting
            detail = snapshot.isChargingOnly
                ? "Waiting for power. Indexing resumes while charging."
                : "Waiting to continue. Indexing resumes when conditions allow."
        } else if c.failed > 0 {
            phase = .needsAttention
            detail = "\(number(c.failed)) track\(c.failed == 1 ? "" : "s") could not be indexed."
        } else {
            phase = .idle
            detail = "Indexing is idle."
        }

        return IndexStatusPresentation(
            phase: phase,
            headline: headline,
            detail: detail,
            fractionComplete: fraction,
            modelDownloadFraction: phase == .waitingForModel
                && snapshot.modelDownloadProgress?.isNegligibleTotal != true
                ? snapshot.modelDownloadProgress?.fractionComplete : nil,
            showsBanner: total > 0,
            canPause: !snapshot.isPaused && (c.queuedOrRunning > 0 || c.waiting > 0),
            canResume: snapshot.isPaused,
            canRetryFailed: canRetry,
            failedCount: c.failed)
    }

    /// The user-facing reason text for each real `IndexPolicy` gate (plan
    /// §10: the status screen must say the actual blocking condition —
    /// "downloading", "waiting", a specific reason — never a bare "indexing"
    /// with nothing behind it).
    private static func detail(forBlockedBy reason: IndexBlockReason, chargingOnly: Bool) -> String {
        switch reason {
        case .userPaused:
            return "Paused. Resume to continue indexing."
        case .playbackActive:
            return "Waiting for playback to stop before indexing continues."
        case .thermalFair, .thermalSerious, .thermalCritical:
            return "Waiting for the device to cool down before indexing continues."
        case .memoryWarning:
            return "Waiting for memory pressure to ease before indexing continues."
        case .lowBatteryOrLowPowerMode:
            return "Waiting for more battery, or for Low Power Mode to turn off, "
                + "before indexing continues."
        case .chargingOnlyRequired:
            return chargingOnly
                ? "Waiting for power. Indexing resumes while charging."
                : "Waiting for power before background indexing continues."
        case .backgroundGrantMissing:
            return "Waiting for background processing time from iOS."
        }
    }

    /// Real byte progress when the ODR download is actually in flight; a
    /// plain "downloading" state when it hasn't reported any bytes yet
    /// (queued, not started, or the system hasn't delivered a length) —
    /// still distinct from "indexing" and still honest, never a fabricated
    /// percentage (CLAUDE.md "no silent/magic background work").
    private static func detail(
        forModelDownload progress: ModelDownloadProgress?, error: String?
    ) -> String {
        // A real failure (no network, low disk space, an unknown-resource
        // error) is a distinct, actionable message — not the same
        // indefinite "Downloading…" as a fetch that just hasn't reported
        // bytes yet. The request retries itself, so this is informational,
        // never a dead end.
        if let error {
            return "Couldn't download the sound-search model yet (\(error)). Retrying automatically…"
        }
        guard let progress, progress.totalBytes > 0 else {
            return "Downloading the sound-search model…"
        }
        // `NSBundleResourceRequest.progress` doesn't guarantee real bytes —
        // a real device showed both tags reporting literal totalUnitCount
        // == 1 (Apple documents the unit as implementation-defined, "often
        // simply 1"). When the byte total is too small to trust
        // (`isNegligibleTotal`), fall back to the one signal that stays
        // honest regardless of unit scheme: how many of the tags have
        // actually finished. Real, verifiable partial information — never
        // silence, never a fabricated percentage.
        guard !progress.isNegligibleTotal else {
            guard progress.componentsTotal > 0 else {
                return "Downloading the sound-search model…"
            }
            return "Downloading the sound-search model — "
                + "\(progress.componentsFinished) of \(progress.componentsTotal) components ready."
        }
        let doneMB = bytesToMB(progress.completedBytes)
        let totalMB = bytesToMB(progress.totalBytes)
        if let fraction = progress.fractionComplete {
            let percent = Int((fraction * 100).rounded())
            return "Downloading the sound-search model — \(doneMB) of \(totalMB) MB (\(percent)%)."
        }
        return "Downloading the sound-search model — \(doneMB) of \(totalMB) MB."
    }

    private static func bytesToMB(_ bytes: Int64) -> Int {
        Int((Double(bytes) / 1_048_576).rounded())
    }

    private static func number(_ value: Int) -> String {
        Self.formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()
}

/// Redacted diagnostics for the plan §10.6 share-sheet export: app/build,
/// OS/device family, model/pipeline versions, aggregate counts, pause and
/// background-scheduling reasons, timestamps and the most recent coded stop
/// reason. Never track names, URLs, bookmarks, tokens or audio.
public struct DiscoveryDiagnostics: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var appVersion: String
    public var buildNumber: String
    public var osVersion: String
    public var deviceFamily: String

    public var pipelineVersion: Int
    public var modelVersion: Int
    public var preprocessingVersion: Int
    public var samplingVersion: Int
    public var musicalAnalysisVersion: Int

    public var tracksTotal: Int
    public var tracksIndexed: Int
    public var tracksQueuedOrRunning: Int
    public var tracksWaiting: Int
    public var tracksFailed: Int

    public var isPaused: Bool
    public var isChargingOnly: Bool
    public var modelResourceAvailable: Bool
    public var modelDownloadCompletedBytes: Int64?
    public var modelDownloadTotalBytes: Int64?
    /// The most recent ODR fetch failure, if any (never just an invisible
    /// `NSLog`) — the definitive answer to "why does it say downloading and
    /// never progress."
    public var modelDownloadError: String?
    /// Per-tag byte breakdown (see `IndexStatusSnapshot.modelDownloadTagDebug`).
    public var modelDownloadTagDebug: String?

    public var lastRunAt: Date?
    public var lastStartAt: Date?
    public var lastStopAt: Date?
    public var lastSuccessfulWorkAt: Date?
    public var lastStopReason: String?
    public var lastBackgroundSubmissionAt: Date?
    public var lastBackgroundSubmissionResult: String?

    public static func make(
        snapshot: IndexStatusSnapshot,
        appVersion: String,
        buildNumber: String,
        osVersion: String,
        deviceFamily: String
    ) -> DiscoveryDiagnostics {
        let c = snapshot.coverage
        let r = snapshot.runtime
        return DiscoveryDiagnostics(
            generatedAt: snapshot.capturedAt,
            appVersion: appVersion,
            buildNumber: buildNumber,
            osVersion: osVersion,
            deviceFamily: deviceFamily,
            pipelineVersion: DiscoveryPipelineVersion.pipeline,
            modelVersion: DiscoveryPipelineVersion.model,
            preprocessingVersion: DiscoveryPipelineVersion.preprocessing,
            samplingVersion: DiscoveryPipelineVersion.sampling,
            musicalAnalysisVersion: DiscoveryPipelineVersion.musicalAnalysis,
            tracksTotal: c.total,
            tracksIndexed: c.complete,
            tracksQueuedOrRunning: c.queuedOrRunning,
            tracksWaiting: c.waiting,
            tracksFailed: c.failed,
            isPaused: snapshot.isPaused,
            isChargingOnly: snapshot.isChargingOnly,
            modelResourceAvailable: snapshot.modelResourceAvailable,
            modelDownloadCompletedBytes: snapshot.modelDownloadProgress?.completedBytes,
            modelDownloadTotalBytes: snapshot.modelDownloadProgress?.totalBytes,
            modelDownloadError: snapshot.modelDownloadError,
            modelDownloadTagDebug: snapshot.modelDownloadTagDebug,
            lastRunAt: r.lastRunAt,
            lastStartAt: r.lastStartAt,
            lastStopAt: r.lastStopAt,
            lastSuccessfulWorkAt: r.lastSuccessfulWorkAt,
            lastStopReason: r.lastStopReason,
            lastBackgroundSubmissionAt: r.lastBackgroundSubmissionAt,
            lastBackgroundSubmissionResult: r.lastBackgroundSubmissionResult)
    }

    public func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self),
            let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }

    private var modelDownloadProgressLine: String {
        guard let completed = modelDownloadCompletedBytes,
            let total = modelDownloadTotalBytes, total > 0
        else { return "" }
        let doneMB = Int((Double(completed) / 1_048_576).rounded())
        let totalMB = Int((Double(total) / 1_048_576).rounded())
        return "  Model download: \(doneMB)/\(totalMB) MB"
    }

    private var modelDownloadErrorLine: String {
        guard let modelDownloadError else { return "" }
        return "\nModel download error: \(modelDownloadError)"
    }

    private var modelDownloadTagDebugLine: String {
        guard let modelDownloadTagDebug else { return "" }
        return "\nModel download detail: \(modelDownloadTagDebug)"
    }

    public func plainText() -> String {
        let df = ISO8601DateFormatter()
        func d(_ date: Date?) -> String { date.map { df.string(from: $0) } ?? "—" }
        return """
            Tonearm sound-index diagnostics
            Generated: \(df.string(from: generatedAt))
            App: \(appVersion) (\(buildNumber))   OS: \(osVersion)   Device: \(deviceFamily)

            Pipeline versions: pipeline \(pipelineVersion), model \(modelVersion), \
            preprocessing \(preprocessingVersion), sampling \(samplingVersion), \
            musicalAnalysis \(musicalAnalysisVersion)

            Tracks: \(tracksTotal) total
              indexed:          \(tracksIndexed)
              queued/running:   \(tracksQueuedOrRunning)
              waiting:          \(tracksWaiting)
              failed:           \(tracksFailed)

            Paused: \(isPaused)   Charging-only: \(isChargingOnly)   \
            Model available: \(modelResourceAvailable)\(modelDownloadProgressLine)\(modelDownloadErrorLine)\(modelDownloadTagDebugLine)

            Last run:            \(d(lastRunAt))
            Last start:          \(d(lastStartAt))
            Last stop:           \(d(lastStopAt))  \(lastStopReason ?? "")
            Last successful work: \(d(lastSuccessfulWorkAt))
            Last background submit: \(d(lastBackgroundSubmissionAt))  \
            \(lastBackgroundSubmissionResult ?? "")
            """
    }
}
#endif
