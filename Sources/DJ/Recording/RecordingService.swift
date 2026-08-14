import AVFoundation
import Foundation

/// The §37.3 recording journal's contract — what the workspace's record toggle
/// drives (plan 5.11, FR-REC-1/3, NFR-REL-2, FR-ENG-8). `RecordingService`
/// conforms; tests inject a fake so the model's recording wiring is exercised
/// deterministically. The interruption flush/open-segment path is NOT here — it
/// lives on the engine seam (`WorkspaceModel` consumes the §34A.4 responses).
public protocol RecordingJournaling: AnyObject, Sendable {
    /// Open the in-progress journal row (`localState = recording`) for a
    /// recording whose encoder writes into `outputDirectory`.
    func begin(outputDirectory: URL) async throws
    /// Join the recording's segments into the single `mix.m4a`, write the
    /// `mix`/`mix_asset` rows to `complete`, and (under the regression harness)
    /// export the self-describing `mix-journal.json`.
    func finalize(output: RecordingEncoder.RecordingOutput,
                  journal: RecordingJournalConfiguration?) async throws
    /// Recover every stale `recording` row left by a crash/interrupted stop —
    /// join the flushed segments into `complete`, or mark `corrupt`.
    func reconcile() async throws -> [RecoveredMix]
}

/// The engine configuration a recording was made under — what the regression
/// suite's `mix-journal.json` exports beside the M4A so the recording is
/// self-describing (dj-regression-suite §7, hook 5.11): the analyzer cannot
/// import the limiter's ceiling, so the app writes the value it really used.
public struct RecordingJournalConfiguration: Sendable, Equatable, Codable {
    public let sampleRate: Double
    /// The master limiter's ceiling, nil when the limiter is out of the path.
    public let limiterCeiling: Float?
    /// The master clock's effective BPM at stop.
    public let masterBPM: Double
    /// The §35A echo division in force per deck (beats).
    public let echoBeatsA: Double
    public let echoBeatsB: Double

    public init(sampleRate: Double,
                limiterCeiling: Float?,
                masterBPM: Double,
                echoBeatsA: Double,
                echoBeatsB: Double) {
        self.sampleRate = sampleRate
        self.limiterCeiling = limiterCeiling
        self.masterBPM = masterBPM
        self.echoBeatsA = echoBeatsA
        self.echoBeatsB = echoBeatsB
    }
}

/// One stale journal row's fate after `reconcile()` (plan 5.11, §37.3): the
/// flushed segments were joined into a playable `mix.m4a` (`salvaged`), or
/// nothing recoverable was on disk (`corrupt`).
public enum RecoveredMix: Sendable, Equatable {
    case salvaged(DJMix)
    case corrupt(DJMix)
}

/// The §37.3 recording journal + recovery service (plan 5.11, FR-REC-1/3,
/// NFR-REL-2, FR-ENG-8).
///
/// This actor owns the `mix`/`mix_asset` journal rows and the crash/interruption
/// recovery, and nothing else — the tap, the encoder, the drain and the
/// interruption segment-flush all live on the engine. It is the "same
/// encoder/side-car actor" §37.4 names, but for the journal rather than the
/// timeline (that is 5.12's `MixTimeline`).
///
/// - `begin(outputDirectory:)` writes the in-progress journal
///   (`localState = recording`) the moment recording starts, so a crash leaves
///   a recoverable row behind.
/// - `finalize(output:journal:)` joins the encoder's segments into the single
///   `mix.m4a` (§37.5 step 1), promotes the rows to `complete` with the real
///   duration/size, deletes the intermediate segments, and — only under the
///   `-uiRegression` harness — exports `mix-journal.json` beside the M4A.
/// - `reconcile()` runs on launch: every stale `recording` row whose segments
///   join is salvaged to `complete`; one with nothing recoverable is marked
///   `corrupt` (never silently dropped, §46.2). **A crash loses at most the
///   in-flight segment** (NFR-REL-2, §37.3).
public actor RecordingService: RecordingJournaling {

    public enum ServiceError: Error, LocalizedError, Equatable {
        case noActiveRecording

        public var errorDescription: String? {
            switch self {
            case .noActiveRecording: return "No recording is in flight."
            }
        }
    }

    private let store: DJLibraryStore
    /// The root `mix_asset.localRelPath` is relative to. Production is
    /// `DJDatabase.mixesDirectory`; tests inject a temp root so the engine and
    /// the service agree on where a recording lives.
    private let mixesRoot: URL
    /// The regression harness hook (hook 5.11): export `mix-journal.json`
    /// beside the M4A **only** under `-uiRegression`.
    private let exportJournalMetadata: Bool
    /// The in-flight journal row (nil while idle). `finalize` clears it.
    private var activeMixID: Int64?

    public init(store: DJLibraryStore = .shared,
                mixesRoot: URL = DJDatabase.mixesDirectory,
                exportJournalMetadata: Bool = false) {
        self.store = store
        self.mixesRoot = mixesRoot
        self.exportJournalMetadata = exportJournalMetadata
    }

    // MARK: - Journal lifecycle

    public func begin(outputDirectory: URL) async throws {
        guard activeMixID == nil else { return }
        let now = Date()
        let mixID = try await store.beginRecordingMix(
            syncID: UUID().uuidString,
            title: Self.defaultTitle(now),
            format: RecordingEncoder.formatName,
            bitrateKbps: RecordingEncoder.bitRateKbps,
            localRelPath: outputDirectory.lastPathComponent + "/mix.m4a",
            recordedAt: now)
        activeMixID = mixID
    }

    public func finalize(output: RecordingEncoder.RecordingOutput,
                         journal: RecordingJournalConfiguration?) async throws {
        guard let mixID = activeMixID else { throw ServiceError.noActiveRecording }
        defer { activeMixID = nil }
        let finalURL = output.outputDirectory.appendingPathComponent("mix.m4a")
        do {
            let frames = try M4AJoiner.join(segmentURLs: output.segmentURLs,
                                            to: finalURL,
                                            sampleRate: output.sampleRate,
                                            channelCount: output.channelCount)
            let size = Self.fileSize(finalURL)
            try await store.finalizeRecordingMix(mixID: mixID,
                                                 durationSec: Double(frames) / output.sampleRate,
                                                 sizeBytes: size,
                                                 trackCount: 0)
            // The segments are intermediate artifacts of this recording — the
            // joined mix.m4a is the user content (§43.6 protects the mix, not
            // the segments). Removed only after the rows committed.
            Self.removeSegments(output.segmentURLs)
            if exportJournalMetadata, let journal {
                try Self.writeJournalJSON(journal, format: output.format,
                                          into: output.outputDirectory)
            }
        } catch {
            try? await store.markRecordingMixCorrupt(mixID: mixID)
            throw error
        }
    }

    public func reconcile() async throws -> [RecoveredMix] {
        let stale = try await store.staleRecordingMixes()
        var recovered: [RecoveredMix] = []
        for mix in stale {
            guard let mixID = mix.id else { continue }
            guard let asset = try await store.mixAsset(mixID: mixID) else {
                try await store.markRecordingMixCorrupt(mixID: mixID)
                recovered.append(.corrupt(mix))
                continue
            }
            let fileURL = mixesRoot.appendingPathComponent(asset.localRelPath)
            let directory = fileURL.deletingLastPathComponent()
            var saved = mix
            if Self.fileExists(fileURL) {
                // Finalize crashed after joining but before the rows committed —
                // salvage the finished M4A directly.
                saved = Self.salvaged(saved, url: fileURL)
            } else if let format = M4AJoiner.probeFormat(of: Self.segmentFiles(in: directory)) {
                do {
                    let frames = try M4AJoiner.join(segmentURLs: Self.segmentFiles(in: directory),
                                                    to: fileURL,
                                                    sampleRate: format.sampleRate,
                                                    channelCount: format.channelCount)
                    saved.durationSec = Double(frames) / format.sampleRate
                    saved.sizeBytes = Self.fileSize(fileURL)
                    saved.localState = MixLocalState.complete.rawValue
                    Self.removeSegments(Self.segmentFiles(in: directory))
                } catch {
                    try await store.markRecordingMixCorrupt(mixID: mixID)
                    recovered.append(.corrupt(mix))
                    continue
                }
            } else {
                try await store.markRecordingMixCorrupt(mixID: mixID)
                recovered.append(.corrupt(mix))
                continue
            }
            try await store.finalizeRecordingMix(mixID: mixID,
                                                 durationSec: saved.durationSec,
                                                 sizeBytes: saved.sizeBytes ?? 0,
                                                 trackCount: 0)
            recovered.append(.salvaged(saved))
        }
        return recovered
    }

    // MARK: - Helpers

    private static func salvaged(_ mix: DJMix, url: URL) -> DJMix {
        var saved = mix
        saved.durationSec = Self.duration(of: url)
        saved.sizeBytes = Self.fileSize(url)
        saved.localState = MixLocalState.complete.rawValue
        return saved
    }

    /// The session directory's `segment-NNN.m4a` files, in order.
    private static func segmentFiles(in directory: URL) -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: directory.path) else { return [] }
        return names
            .filter { $0.hasPrefix("segment-") && $0.hasSuffix(".m4a") }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }

    private static func duration(of url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0
    }

    private static func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private static func removeSegments(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func defaultTitle(_ date: Date) -> String {
        "Recording \(Self.titleFormatter.string(from: date))"
    }

    private static let titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private struct JournalPayload: Codable {
        let format: String
        let sampleRate: Double
        let limiterCeiling: Double?
        let masterBPM: Double
        let echoBeatsA: Double
        let echoBeatsB: Double
    }

    private static func writeJournalJSON(_ config: RecordingJournalConfiguration,
                                         format: String,
                                         into directory: URL) throws {
        let payload = JournalPayload(format: format,
                                     sampleRate: config.sampleRate,
                                     limiterCeiling: config.limiterCeiling.map(Double.init),
                                     masterBPM: config.masterBPM,
                                     echoBeatsA: config.echoBeatsA,
                                     echoBeatsB: config.echoBeatsB)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: directory.appendingPathComponent("mix-journal.json"),
                       options: .atomic)
    }
}
