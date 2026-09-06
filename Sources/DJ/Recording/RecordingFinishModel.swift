import AVFoundation
import Combine
import Foundation

// MARK: - Cue sheet (FR-REC-4's optional tracklist export)

/// The cue-sheet / tracklist text the finish screen can export beside the M4A
/// (FR-REC-4, mockup `ipad/09`'s "Include tracklist / cue sheet"). Pure — no
/// I/O, fully testable. Names the format it describes (FR-REC-7 honesty: M4A,
/// never MP3).
public enum CueSheetBuilder {
    /// The one-line licence stated for genre-library material (§18A.5,
    /// plan 5.12): the exact string 5.6 records on every jamendo `Source`
    /// (`AppState.addGenreLibrary`), carried to the mix's credits because the
    /// DJ schema carries licence at the source level (the 5.6 deviation).
    public static let attributionLine = "Creative Commons — attribution kept"

    public static func text(title: String,
                            recordedAtText: String,
                            duration: TimeInterval,
                            formatLabel: String,
                            events: [DJMixTrackEvent],
                            attribution: [String]) -> String {
        var lines: [String] = []
        lines.append(title)
        lines.append("Recorded \(recordedAtText) · \(Self.timestamp(duration)) · \(formatLabel)")
        lines.append("")
        lines.append("Tracklist:")
        for event in events {
            let credit = attribution.isEmpty
                ? "\(event.artist.map { "\($0) — " } ?? "")\(event.title)"
                : attribution[max(0, min(attribution.count - 1, event.position - 1))]
            lines.append("\(Self.timestamp(event.startOffsetSec))\t\(credit)")
        }
        if !attribution.isEmpty {
            lines.append("")
            lines.append("Attribution:")
            lines.append(Self.attributionLine)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

// MARK: - The finish screen model (§41.11, plan 5.12)

/// The recording-finish screen's view model (mockup `ipad/09`): title/notes,
/// the §37.4 timeline, the **review listen** (FR-REC-6 — the finished mix is
/// playable in place, the moment it finalises, with a seekable waveform and
/// tappable transition markers), attribution (§18A.5), and export (FR-REC-4).
///
/// `begin()` loads the timeline, decodes the review-listen waveform and
/// prepares the player. The transport (`play`/`pause`/`seek`/`jump(to:)`) is
/// forwarded to the injected `MixPlayback`; `tick()` mirrors the player's
/// position for the playhead (the view drives it at ~10 Hz).
@MainActor
public final class RecordingFinishModel: ObservableObject {

    /// The mix this screen shows — the journal's finished row.
    @Published public private(set) var mix: DJMix
    /// The §37.4 timeline — the tracklist table and the waveform's transition
    /// markers (mockup `ipad/09`).
    @Published public private(set) var timeline: [DJMixTrackEvent] = []
    /// The review-listen waveform (decoded from the mix's own audio).
    @Published public private(set) var waveform: MixWaveformModel?
    @Published public private(set) var isLoaded = false
    @Published public private(set) var loadError: String?
    /// The review-listen transport state, mirrored from the player in `tick()`.
    @Published public private(set) var isPlaying = false
    @Published public private(set) var currentTime: TimeInterval = 0
    /// FR-REC-1's editable title/notes.
    @Published public var title: String
    @Published public var notes: String
    /// The export card's "Include tracklist / cue sheet" toggle (FR-REC-4).
    @Published public var includeCueSheet = true
    /// Phase 9 (docs/GPL-BACKENDS.md): an additional "also export MP3"
    /// toggle. The mix itself always stays recorded as M4A/AAC (FR-REC-7
    /// honesty, `formatLabel`) — this re-encodes a copy via LAME for the
    /// share sheet only, never replaces the recording.
    @Published public var includeMP3Export = false {
        didSet {
            guard includeMP3Export, !oldValue else { return }
            Task { await prepareMP3Export() }
        }
    }
    @Published public private(set) var isPreparingMP3Export = false
    @Published public private(set) var mp3ExportError: String?
    private var mp3ExportURL: URL?
    /// The container path the `-uiRegression` export was written to (hook 5.12),
    /// nil until the harness share action runs. The runner reads it via
    /// `simctl get_app_container`; the finish screen publishes it on
    /// `dj.export.path`.
    @Published public private(set) var regressionExportPath: String?

    /// FR-REC-7 honesty: the mix's real format label — "M4A · AAC 256 kbps".
    public var formatLabel: String {
        switch mix.format {
        case RecordingEncoder.formatName: return "M4A · AAC 256 kbps"
        default: return mix.format.uppercased()
        }
    }

    public var duration: TimeInterval { mix.durationSec }
    public var trackCount: Int { mix.trackCount }
    public var sizeBytes: Int64? { mix.sizeBytes }
    public var sampleRate: Double? { waveform?.sampleRate }
    public var channelCount: Int? { waveform?.channelCount }

    /// The mix's audio URL — playback and export. Nil when the file is gone
    /// (the honest absence state, §46.2).
    public var assetURLForExport: URL? { assetURL }

    /// "1:12:04" — the finish screen's duration pill.
    public var durationText: String {
        CueSheetBuilder.timestamp(duration)
    }

    /// "00:16:03" — the review-listen playhead readout.
    public var timeText: String {
        CueSheetBuilder.timestamp(currentTime)
    }

    public func sizeText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// A filesystem-safe default filename for the export ("Friday set.m4a").
    public var sanitizedFilename: String {
        let base = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "\(base.isEmpty ? "mix" : base).m4a"
    }

    /// The mix is honest-`corrupt` — the finish screen shows the state and a
    /// delete, never a dead player (§46.2).
    public var isCorrupt: Bool { mix.state == .corrupt }

    /// The §37.4 markers the review-listen waveform draws — one per timeline
    /// row, tappable to jump (FR-REC-6).
    public var markers: [TimeInterval] { timeline.map(\.startOffsetSec) }

    private let repository: any MixServicing
    private let player: any MixPlayback
    private let waveformLoader: any MixWaveformLoading
    private let recordedAtText: String
    private var assetURL: URL?
    private var cueSheetCache: (url: URL, text: String)?
    /// The engine's config, kept so a deleted-but-open mix still behaves.
    private var didDelete = false

    public init(mix: DJMix,
                repository: any MixServicing,
                player: any MixPlayback,
                waveformLoader: any MixWaveformLoading,
                recordedAtText: String? = nil) {
        self.mix = mix
        self.repository = repository
        self.player = player
        self.waveformLoader = waveformLoader
        self.title = mix.title
        self.notes = mix.notes ?? ""
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        self.recordedAtText = recordedAtText ?? formatter.string(from: mix.recordedAt)
    }

    /// Load the review listen: the timeline, the mix's audio URL, the waveform
    /// and the player. The screen is usable (title/notes/timeline) the moment
    /// the rows finalise; playback and the waveform follow.
    public func begin() async {
        guard !isLoaded, !didDelete else { return }
        guard let mixID = mix.id else {
            loadError = "This mix is missing its record."
            isLoaded = true
            return
        }
        do {
            timeline = try await repository.mixTrackEvents(mixID: mixID)
            if let url = try await repository.mixAssetURL(mixID: mixID) {
                assetURL = url
                waveform = try? await waveformLoader.loadWaveform(url: url)
                try? player.load(url: url)
            } else if !isCorrupt {
                // A complete mix whose file is gone — the honest absence state
                // (§46.2), never a silent no-op.
                loadError = "The audio for this mix is no longer on this device."
            }
        } catch {
            loadError = error.localizedDescription
        }
        isLoaded = true
    }

    // MARK: - Review-listen transport (FR-REC-6)

    public func togglePlayback() {
        isPlaying ? pause() : play()
    }

    public func play() {
        guard assetURL != nil, !isCorrupt else { return }
        player.play()
        isPlaying = true
    }

    public func pause() {
        player.pause()
        isPlaying = false
    }

    /// Seek the playhead (a scrub on the waveform).
    public func seek(to time: TimeInterval) {
        player.seek(to: time)
        currentTime = max(0, min(time, duration))
    }

    /// Jump to a transition marker — seek AND play ("tap one to jump straight
    /// to it", mockup `ipad/09`).
    public func jump(to offset: TimeInterval) {
        seek(to: offset)
        play()
    }

    /// Mirror the player's position — the view calls this at ~10 Hz.
    public func tick() {
        currentTime = player.currentTime
        if !player.isPlaying, isPlaying {
            isPlaying = false
        }
    }

    // MARK: - Title / notes (FR-REC-1)

    public func save() async {
        guard let mixID = mix.id else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? await repository.updateMix(mixID: mixID,
                                        title: trimmed,
                                        notes: notes.isEmpty ? nil : notes)
        mix.title = trimmed
        mix.notes = notes.isEmpty ? nil : notes
    }

    /// Delete the mix (row + user-content file). The view dismisses after.
    public func delete() async {
        player.pause()
        guard let mixID = mix.id else { return }
        try? await repository.deleteMix(mixID: mixID)
        didDelete = true
    }

    // MARK: - Attribution (§18A.5, plan 5.12)

    /// Per-track "Artist — Title" credits for every timeline row, plus the
    /// licence line — carried to the finish screen and the exported cue-sheet.
    public var attributionLines: [String] {
        timeline.map { event in
            let artist = event.artist.map { "\($0) — " } ?? ""
            return "\(artist)\(event.title)"
        }
    }

    public var attributionNote: String {
        CueSheetBuilder.attributionLine
    }

    // MARK: - Export (FR-REC-4, FR-REC-7)

    public func cueSheetText() -> String {
        CueSheetBuilder.text(title: title,
                             recordedAtText: recordedAtText,
                             duration: duration,
                             formatLabel: formatLabel,
                             events: timeline,
                             attribution: attributionLines)
    }

    /// The files a share sheet carries: the mix M4A plus — when the cue-sheet
    /// toggle is on — a freshly written cue-sheet. The M4A is copied nowhere:
    /// sharing hands the recorded file itself (FR-REC-4, no re-encode).
    public var shareItems: [URL] {
        var items: [URL] = []
        if let assetURL { items.append(assetURL) }
        if includeCueSheet, let cueSheet = cueSheetURL() {
            items.append(cueSheet)
        }
        if includeMP3Export, let mp3ExportURL {
            items.append(mp3ExportURL)
        }
        return items
    }

    /// Transcodes the mix to MP3 (LAME, 256 kbps CBR) into a temp file and
    /// publishes it for `shareItems`. Runs off the main actor — a long mix
    /// takes real wall-clock time to decode + re-encode.
    private func prepareMP3Export() async {
        guard let assetURL else { return }
        isPreparingMP3Export = true
        mp3ExportError = nil
        let base = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(base.isEmpty ? "mix" : base).mp3")
        FileManager.default.removeItemIfPresent(destination)
        do {
            try await Task.detached(priority: .userInitiated) {
                try MP3MixExporter.export(assetURL: assetURL, bitrateKbps: 256, to: destination)
            }.value
            mp3ExportURL = destination
        } catch {
            mp3ExportURL = nil
            mp3ExportError = "Couldn't prepare the MP3 export: \(error.localizedDescription)"
            includeMP3Export = false
        }
        isPreparingMP3Export = false
    }

    private func cueSheetURL() -> URL? {
        let text = cueSheetText()
        if let cache = cueSheetCache, cache.text == text {
            return cache.url
        }
        let base = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(base.isEmpty ? "mix" : base)-cue-sheet.txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        cueSheetCache = (url, text)
        return url
    }

    /// The `-uiRegression` export (dj-regression-suite hook 5.12): the share
    /// action is unautomatable, so under the harness it writes the M4A (plus the
    /// cue sheet and the session's `mix-journal.json`) to the app's
    /// `Documents/uiRegression/export/` container path and publishes it on
    /// `dj.export.path`. The runner pulls it with `simctl get_app_container`.
    public func exportForRegression() async {
        guard regressionExportPath == nil, let assetURL else { return }
        let fm = FileManager.default
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let exportDirectory = documents
            .appendingPathComponent("uiRegression", isDirectory: true)
            .appendingPathComponent("export", isDirectory: true)
        do {
            try fm.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
            let mixDestination = exportDirectory.appendingPathComponent("dj-mix.m4a")
            fm.removeItemIfPresent(mixDestination)
            try fm.copyItem(at: assetURL, to: mixDestination)

            // The journal the engine wrote beside the M4A (hook 5.11) travels
            // with the export so the host-side analyzer can cross-check it.
            let journalSource = assetURL.deletingLastPathComponent()
                .appendingPathComponent("mix-journal.json")
            if fm.fileExists(atPath: journalSource.path) {
                let journalDestination = exportDirectory.appendingPathComponent("mix-journal.json")
                fm.removeItemIfPresent(journalDestination)
                try fm.copyItem(at: journalSource, to: journalDestination)
            }

            if includeCueSheet, let cueSheet = cueSheetURL() {
                let destination = exportDirectory.appendingPathComponent(cueSheet.lastPathComponent)
                fm.removeItemIfPresent(destination)
                try fm.copyItem(at: cueSheet, to: destination)
            }
            regressionExportPath = mixDestination.path
        } catch {
            // An export failure is honest, not fatal — the path stays nil and
            // the runner reports the missing artifact rather than a false pass.
        }
    }

    // MARK: - Assembly

    /// The real finish-screen stack: the single-writer mixes data layer and an
    /// `AVAudioPlayer`-backed transport. Views build their model through this;
    /// tests inject fakes directly.
    public static func makeModel(mix: DJMix,
                                 repository: (any MixServicing)? = nil,
                                 player: (any MixPlayback)? = nil,
                                 waveformLoader: (any MixWaveformLoading)? = nil) -> RecordingFinishModel {
        RecordingFinishModel(
            mix: mix,
            repository: repository ?? MixRepository(),
            player: player ?? AVAudioPlayerMixPlayer(),
            waveformLoader: waveformLoader ?? MixWaveformBuilder())
    }
}

private extension FileManager {
    func removeItemIfPresent(_ url: URL) {
        try? removeItem(at: url)
    }
}
