#if !os(watchOS)
import Foundation
import TonearmCore

/// A consistent snapshot of the indexing subsystem's persisted state, gathered
/// off the main actor by `DiscoveryAssembly.statusSnapshot()` and mapped to
/// display by `IndexStatusPresentation` (plan §10: the status surface reads
/// real persisted services — `IndexJobRepository.coverage`,
/// `DiscoverySettingsStore`, `discovery_runtime` — never a mock).
public struct IndexStatusSnapshot: Equatable, Sendable {
    public var coverage: IndexJobRepository.Coverage
    public var isPaused: Bool
    public var isChargingOnly: Bool
    /// Master switch for indexing tracks that only exist on a remote
    /// library (on by default, at the owner's explicit request — the
    /// Wi-Fi-only setting below is the actual data-cost guard; see
    /// `DiscoverySettingsStore`).
    public var isRemoteIndexingEnabled: Bool
    /// Whether remote sampling is currently restricted to Wi-Fi (on by
    /// default; irrelevant while `isRemoteIndexingEnabled` is false).
    public var isRemoteIndexingWiFiOnly: Bool
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
    /// Real numbers behind `schedulerBlockReason` when it is a thermal reason — see
    /// `ThermalDiagnostic`'s doc for why this must not be collapsed into the reason alone.
    public var thermalDiagnostic: ThermalDiagnostic?
    /// The one track actively being worked on right now, with its own progress — real report:
    /// "what track is being indexed, the % progress of the INDIVIDUAL TRACK, not just all
    /// tracks." `nil` whenever nothing currently holds a running lease (idle, paused, or every
    /// eligible job is parked waiting).
    public var currentlyIndexingTrack: IndexJobRepository.RunningTrackSummary?
    /// Tracks completed per second over a real trailing wall-clock window — `nil` when nothing
    /// has completed recently enough to measure a rate (just started, paused, or blocked). The
    /// presentation layer only turns this into an ETA while genuinely `.indexing` (see
    /// `IndexStatusPresentation`) — never while paused/blocked, where no numeric estimate would
    /// be honest.
    public var recentCompletionRate: Double?

    public init(
        coverage: IndexJobRepository.Coverage,
        isPaused: Bool,
        isChargingOnly: Bool,
        isRemoteIndexingEnabled: Bool = true,
        isRemoteIndexingWiFiOnly: Bool = true,
        runtime: DiscoveryRuntime,
        capturedAt: Date = Date(),
        schedulerBlockReason: IndexBlockReason? = nil,
        thermalDiagnostic: ThermalDiagnostic? = nil,
        currentlyIndexingTrack: IndexJobRepository.RunningTrackSummary? = nil,
        recentCompletionRate: Double? = nil
    ) {
        self.coverage = coverage
        self.isPaused = isPaused
        self.isChargingOnly = isChargingOnly
        self.isRemoteIndexingEnabled = isRemoteIndexingEnabled
        self.isRemoteIndexingWiFiOnly = isRemoteIndexingWiFiOnly
        self.runtime = runtime
        self.capturedAt = capturedAt
        self.schedulerBlockReason = schedulerBlockReason
        self.thermalDiagnostic = thermalDiagnostic
        self.currentlyIndexingTrack = currentlyIndexingTrack
        self.recentCompletionRate = recentCompletionRate
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
    public var showsBanner: Bool
    public var canPause: Bool
    public var canResume: Bool
    public var canRetryFailed: Bool
    public var failedCount: Int
    /// A rough, honestly-labeled estimate — never shown as a precise countdown. `nil` whenever an
    /// estimate wouldn't be honest: not actively `.indexing`, or no track has finished recently
    /// enough to measure a real rate yet.
    public var estimatedTimeRemainingText: String?

    public static func make(from snapshot: IndexStatusSnapshot) -> IndexStatusPresentation {
        let c = snapshot.coverage
        let total = c.total
        let done = c.complete
        let fraction = total > 0 ? min(1.0, Double(done) / Double(total)) : 0

        let headline: String
        if total == 0 {
            headline = String(localized: "Sound index: not started", bundle: .module)
        } else {
            headline = String(localized: "Sound index: \(number(done)) / \(number(total)) tracks", bundle: .module)
        }

        let canRetry = c.failed > 0
        var phase: IndexStatusPhase = .idle
        var detail = ""

        if total == 0 {
            phase = .emptyLibrary
            detail = String(localized: "Add music to start building the sound index.", bundle: .module)
        } else if snapshot.isPaused {
            phase = .paused
            detail = String(localized: "Paused. Resume to continue indexing.", bundle: .module)
        } else if done == total && c.waiting == 0 && c.queuedOrRunning == 0 && c.failed == 0 {
            phase = .upToDate
            detail = String(localized: "All music is indexed.", bundle: .module)
        } else if c.queuedOrRunning > 0, let reason = snapshot.schedulerBlockReason,
            reason != .userPaused
        {
            // Jobs exist and are counted as "queued/running", but the
            // scheduler itself is gated and has made zero progress against
            // them — never collapse this into the generic "Indexing…" label
            // (that label implies real progress is happening).
            phase = .blockedByPolicy
            detail = Self.detail(forBlockedBy: reason, chargingOnly: snapshot.isChargingOnly,
                                 thermal: snapshot.thermalDiagnostic)
        } else if c.queuedOrRunning > 0 {
            phase = .indexing
            detail = String(localized: "Indexing \(c.queuedOrRunning) tracks…", bundle: .module)
        } else if c.waiting > 0 {
            phase = .waiting
            detail = Self.detail(
                forWaiting: c.waitingBreakdown, chargingOnly: snapshot.isChargingOnly,
                failureError: c.mostRecentFailureError, thermal: snapshot.thermalDiagnostic)
        } else if c.failed > 0 {
            phase = .needsAttention
            detail = String(localized: "\(c.failed) tracks could not be indexed.", bundle: .module)
                + Self.errorSuffix(c.mostRecentFailureError)
        } else {
            phase = .idle
            detail = String(localized: "Indexing is idle.", bundle: .module)
        }

        let currentTrack = phase == .indexing ? snapshot.currentlyIndexingTrack : nil
        let remaining = c.queuedOrRunning + c.waiting
        let eta = phase == .indexing
            ? Self.estimatedTimeRemainingText(remaining: remaining, rate: snapshot.recentCompletionRate)
            : nil

        return IndexStatusPresentation(
            phase: phase,
            headline: headline,
            detail: detail,
            fractionComplete: fraction,
            showsBanner: total > 0,
            canPause: !snapshot.isPaused && (c.queuedOrRunning > 0 || c.waiting > 0),
            canResume: snapshot.isPaused,
            canRetryFailed: canRetry,
            failedCount: c.failed,
            currentTrackTitle: currentTrack?.title,
            currentTrackArtist: currentTrack?.artistName,
            estimatedTimeRemainingText: eta)
    }

    /// Real report this answers: "Waiting to continue. Indexing resumes
    /// when conditions allow." was shown for every `waiting` job regardless
    /// of WHY, because `DiscoveryAssembly.drainQueue` discarded the actual
    /// per-job `DiscoveryJobState` reason on every tick. `waitingBreakdown`
    /// is the real, persisted state distribution instead — pick the largest
    /// bucket (the reason affecting the most tracks) and say what it
    /// actually is; a `.retryScheduled` majority also surfaces the real
    /// error from the most recent attempt, since "will retry" alone doesn't
    /// explain "retrying also fails."
    private static func detail(
        forWaiting breakdown: [DiscoveryJobState: Int], chargingOnly: Bool,
        failureError: IndexJobRepository.JobErrorSample?, thermal: ThermalDiagnostic? = nil
    ) -> String {
        guard let (reason, count) = breakdown.max(by: { $0.value < $1.value }) else {
            // No breakdown available (e.g. an older/synthetic snapshot) —
            // fall back to the previous charging-only-aware generic text
            // rather than claiming a reason we don't actually have.
            return chargingOnly
                ? String(localized: "Waiting for power. Indexing resumes while charging.", bundle: .module)
                : String(localized: "Waiting to continue. Indexing resumes when conditions allow.", bundle: .module)
        }
        switch reason {
        case .waitingForAsset:
            return String(
                localized: "\(count) tracks waiting on their audio file — moved, deleted, or not fully downloaded from cloud storage.",
                bundle: .module)
        case .waitingForNetwork:
            return String(localized: "Waiting for a network connection to reach \(count) tracks.", bundle: .module)
        case .waitingForPower:
            return chargingOnly
                ? String(localized: "Waiting for power. Indexing resumes while charging.", bundle: .module)
                : String(localized: "Waiting for more battery before indexing continues.", bundle: .module)
        case .waitingForCooling:
            return Self.thermalDetail(thermal)
        case .retryScheduled:
            guard let failureError else {
                return String(
                    localized: "\(count) tracks hit a temporary error and will retry automatically.",
                    bundle: .module)
            }
            let message = failureError.message ?? failureError.code
            return String(
                localized: "\(count) tracks hit a temporary error and will retry automatically. Last error: \(message).",
                bundle: .module)
        case .queued, .running, .failed, .complete, .unsupported:
            // Not real waiting states — coverage() never buckets these into
            // waitingBreakdown, but the switch must stay exhaustive.
            return String(localized: "Waiting to continue. Indexing resumes when conditions allow.", bundle: .module)
        }
    }

    /// A real, actionable failure detail (never a bare "N tracks could not
    /// be indexed" when we actually know why) — same
    /// `mostRecentFailureError` the `.retryScheduled` waiting text above
    /// uses, since a `.failed` job's error is exactly the one that ran out
    /// of retry attempts.
    private static func errorSuffix(_ error: IndexJobRepository.JobErrorSample?) -> String {
        guard let error else { return "" }
        let message = error.message ?? error.code
        return " " + String(localized: "Most recent error: \(message).", bundle: .module)
    }

    /// The user-facing reason text for each real `IndexPolicy` gate (plan
    /// §10: the status screen must say the actual blocking condition —
    /// "downloading", "waiting", a specific reason — never a bare "indexing"
    /// with nothing behind it).
    private static func detail(forBlockedBy reason: IndexBlockReason, chargingOnly: Bool,
                               thermal: ThermalDiagnostic? = nil) -> String {
        switch reason {
        case .userPaused:
            return String(localized: "Paused. Resume to continue indexing.", bundle: .module)
        case .thermalFair, .thermalSerious, .thermalCritical:
            return Self.thermalDetail(thermal)
        case .memoryWarning:
            return String(localized: "Waiting for memory pressure to ease before indexing continues.", bundle: .module)
        case .lowBatteryOrLowPowerMode:
            return String(
                localized: "Waiting for more battery, or for Low Power Mode to turn off, before indexing continues.",
                bundle: .module)
        case .chargingOnlyRequired:
            return chargingOnly
                ? String(localized: "Waiting for power. Indexing resumes while charging.", bundle: .module)
                : String(localized: "Waiting for power before background indexing continues.", bundle: .module)
        case .backgroundGrantMissing:
            return String(localized: "Waiting for background processing time from iOS.", bundle: .module)
        case .remoteSamplingRequiresWiFi:
            return String(localized: "Waiting for Wi-Fi before indexing this remote track.", bundle: .module)
        }
    }

    /// The real thermal reason, distinguishing a device that is *currently* elevated from one
    /// that has already returned to normal and is only waiting out the recovery debounce (plan
    /// §6: "wait until nominal continuously for 60 seconds") — collapsing both into one "cool
    /// down" message is exactly the confusing, generic label CLAUDE.md's "no silent/magic
    /// background work" rule forbids ("never collapse a real blocked/waiting state into a
    /// generic in-progress label"). `nil` only for an older/synthetic snapshot with no captured
    /// diagnostic — falls back to the previous generic text rather than claiming numbers we
    /// don't have.
    private static func thermalDetail(_ thermal: ThermalDiagnostic?) -> String {
        guard let thermal else {
            return String(localized: "Waiting for the device to cool down before indexing continues.", bundle: .module)
        }
        switch thermal.state {
        case .critical:
            return String(localized: "The device is very hot (thermal state: Critical). Indexing is paused until it cools.", bundle: .module)
        case .serious:
            return String(localized: "The device is running hot (thermal state: Serious). Indexing is paused until it cools.", bundle: .module)
        case .fair:
            return String(
                localized: "The device's thermal state is elevated (Fair). Indexing pauses until it's back to normal for a full minute.",
                bundle: .module)
        case .nominal:
            // The confusing real-world case this exists for: the device is NOT hot right now —
            // it already returned to normal — but indexing hasn't resumed yet because the
            // recovery rule requires it to stay normal for a full continuous minute first.
            let remaining = Int(thermal.secondsUntilRecovered.rounded(.up))
            if remaining <= 0 {
                return String(localized: "Device temperature is back to normal. Resuming indexing…", bundle: .module)
            }
            return String(
                localized: "Device temperature is back to normal. Resuming in \(remaining)s (confirming it stays cool).",
                bundle: .module)
        }
    }

    /// Rough, honestly-labeled remaining-time text from a trailing-window completion rate — real
    /// report: "ETAs for completing all indexing." Deliberately never a precise countdown: the
    /// rate is a trailing average, not a guarantee, so this always reads "about" and rounds to
    /// the nearest coarse unit rather than implying second-level precision CLAUDE.md's "no
    /// silent/magic background work" principle would call overstated confidence.
    static func estimatedTimeRemainingText(remaining: Int, rate: Double?) -> String? {
        guard remaining > 0, let rate, rate > 0 else { return nil }
        let seconds = Double(remaining) / rate
        if seconds < 60 {
            return String(localized: "Finishing up…", bundle: .module)
        }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 {
            return String(localized: "About \(minutes) min remaining", bundle: .module)
        }
        let hours = Int((Double(minutes) / 60).rounded())
        return String(localized: "About \(hours) hr remaining", bundle: .module)
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
    public var musicalAnalysisVersion: Int

    public var tracksTotal: Int
    public var tracksIndexed: Int
    public var tracksQueuedOrRunning: Int
    public var tracksWaiting: Int
    public var tracksFailed: Int

    public var isPaused: Bool
    public var isChargingOnly: Bool
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
            musicalAnalysisVersion: DiscoveryPipelineVersion.musicalAnalysis,
            tracksTotal: c.total,
            tracksIndexed: c.complete,
            tracksQueuedOrRunning: c.queuedOrRunning,
            tracksWaiting: c.waiting,
            tracksFailed: c.failed,
            isPaused: snapshot.isPaused,
            isChargingOnly: snapshot.isChargingOnly,
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

    public func plainText() -> String {
        let df = ISO8601DateFormatter()
        func d(_ date: Date?) -> String { date.map { df.string(from: $0) } ?? "—" }
        return """
            Tonearm sound-index diagnostics
            Generated: \(df.string(from: generatedAt))
            App: \(appVersion) (\(buildNumber))   OS: \(osVersion)   Device: \(deviceFamily)

            Pipeline versions: pipeline \(pipelineVersion), \
            musicalAnalysis \(musicalAnalysisVersion)

            Tracks: \(tracksTotal) total
              indexed:          \(tracksIndexed)
              queued/running:   \(tracksQueuedOrRunning)
              waiting:          \(tracksWaiting)
              failed:           \(tracksFailed)

            Paused: \(isPaused)   Charging-only: \(isChargingOnly)

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
