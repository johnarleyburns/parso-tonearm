import Foundation
import ParsoAudioAnalysis
import ParsoAudioCore
import ParsoDJEngine
import TonearmCore

/// What a deck's track-info card shows while LOAD is in flight — real, current-step text, never a
/// generic spinner (CLAUDE.md: no silent background work).
enum DeckLoadState: Equatable {
    case empty
    case downloading(Double)
    case decoding
    case analyzing
    case ready
    case failed(String)
}

struct LoadedDeckInfo: Equatable {
    var title: String
    var artist: String
    var bpm: Double
    var camelot: String
}

enum DJDeckSide { case left, right }

/// A finished REC take waiting on a name before it's moved into Mixes — or discarded.
struct PendingMixRecording: Equatable {
    var tempURL: URL
    var durationSec: Double
    var suggestedTitle: String
}

/// Owns the one `DJEngine` for the manual DJ console: real load/play/pause/volume/PFL,
/// single-output split-cue routing (`MasterOutputRoute`, from the engine's 1.5.0 release), and
/// REC → FLAC → Mixes. Platter, tempo, EQ and isolator stay purely cosmetic
/// (DJConsoleView/DeckView/MixerView) — nothing here drives them.
@MainActor
final class DJConsoleModel: ObservableObject {
    @Published private(set) var leftState: DeckLoadState = .empty
    @Published private(set) var rightState: DeckLoadState = .empty
    @Published private(set) var leftInfo: LoadedDeckInfo?
    @Published private(set) var rightInfo: LoadedDeckInfo?
    @Published private(set) var leftPlaying = false
    @Published private(set) var rightPlaying = false
    @Published var leftVolume: Double = 0.75 {
        didSet { engine.mixer.channelA.fader = leftVolume }
    }
    @Published var rightVolume: Double = 0.75 {
        didSet { engine.mixer.channelB.fader = rightVolume }
    }
    @Published private(set) var leftPFL = false
    @Published private(set) var rightPFL = false
    @Published private(set) var isRecording = false
    @Published var pendingRecording: PendingMixRecording?
    @Published var recordingError: String?

    let engine = DJEngine()
    private(set) var isRunning = false
    private var recorder: MixRecorder?
    private var recordingTempURL: URL?

    /// Starts the engine's own `AVAudioEngine` graph. The caller (DJConsoleView) is responsible
    /// for pausing ordinary playback first — this is a second, independent audio engine, and
    /// running two at once is an unnecessary risk this console does not need to take.
    func start() {
        guard !isRunning else { return }
        do {
            try engine.start()
            isRunning = true
            engine.mixer.channelA.fader = leftVolume
            engine.mixer.channelB.fader = rightVolume
        } catch {
            // Nothing plays, but the console still opens — load() will fail cleanly per-deck too.
            isRunning = false
        }
    }

    func stop() {
        guard isRunning else { return }
        // Closing the console mid-recording discards the take rather than finalizing it: there's
        // no naming prompt to show once this model is torn down, and leaving the native record
        // tap running past engine teardown is not safe.
        if isRecording {
            isRecording = false
            try? engine.stopRecording()
            if let tempURL = recordingTempURL { try? FileManager.default.removeItem(at: tempURL) }
            recorder = nil
            recordingTempURL = nil
        }
        engine.stop()
        isRunning = false
    }

    func load(_ row: TrackRow, onto side: DJDeckSide) async {
        setState(.downloading(0), side: side)
        guard let asset = row.asset, let source = AudioPlayer.shared.mixTrackSource(for: asset) else {
            setState(.failed("No playable source for this track"), side: side)
            return
        }
        do {
            let loaded = try await MixTrackLoader.load(
                trackID: row.track.id ?? -1, source: source, approximateBPM: nil,
                sampleRate: engine.sampleRate
            ) { [weak self] stage in
                Task { @MainActor [weak self] in
                    switch stage {
                    case .downloading(let fraction): self?.setState(.downloading(fraction), side: side)
                    case .analyzing: self?.setState(.decoding, side: side)
                    }
                }
            }
            setState(.analyzing, side: side)
            let buffer = loaded.audio
            let analysis = await Task.detached { TrackAnalyzer().analyze(buffer) }.value
            let deck = side == .left ? engine.deckA : engine.deckB
            deck.load(analysis, buffer: buffer)
            setInfo(LoadedDeckInfo(title: row.track.title, artist: row.artist?.name ?? "",
                                   bpm: analysis.tempo.bpm, camelot: analysis.key.camelot), side: side)
            setState(.ready, side: side)
        } catch {
            setState(.failed(error.localizedDescription), side: side)
        }
    }

    func togglePlay(_ side: DJDeckSide) {
        let deck = side == .left ? engine.deckA : engine.deckB
        let playing = side == .left ? leftPlaying : rightPlaying
        if playing { deck.pause() } else { deck.play() }
        setPlaying(!playing, side: side)
    }

    /// Mutually exclusive, like a real mixer's PFL cluster — selecting one clears the other.
    /// Clearing the only engaged PFL while a split is selected resets the route to `.stereo`:
    /// `.splitLeft`/`.splitRight` only mean something with a PFL-selected deck feeding them, so
    /// this never leaves the output silently routing an undefined cue signal.
    func togglePFL(_ side: DJDeckSide) {
        switch side {
        case .left:
            leftPFL.toggle()
            if leftPFL { rightPFL = false }
            engine.mixer.channelA.cuePFL = leftPFL
            engine.mixer.channelB.cuePFL = rightPFL
        case .right:
            rightPFL.toggle()
            if rightPFL { leftPFL = false }
            engine.mixer.channelB.cuePFL = rightPFL
            engine.mixer.channelA.cuePFL = leftPFL
        }
        if !leftPFL && !rightPFL { outputRoute = .stereo }
    }

    /// Single-output "split cue": `.splitLeft`/`.splitRight` only make sense once a channel's
    /// PFL is engaged (there would otherwise be no cue signal to route) — the UI disables those
    /// two options until then rather than silently producing an undefined mix.
    @Published var outputRoute: MasterOutputRoute = .stereo {
        didSet { engine.masterOutputRoute = outputRoute }
    }
    var hasPFLSelection: Bool { leftPFL || rightPFL }

    /// REC: tap to start (the button turns into a red dot), tap again to stop. Stopping always
    /// finalizes to a temp FLAC file and hands off via `pendingRecording` so the caller can show a
    /// naming prompt — nothing is saved into Mixes until the user confirms a title.
    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tonearm-mix-\(UUID().uuidString)")
            .appendingPathExtension("flac")
        guard let recorder = try? MixRecorder(codec: .flacDelivery(bitDepth: 24, compression: 5, tags: []),
                                               url: tempURL) else {
            recordingError = "Couldn't start recording."
            return
        }
        self.recorder = recorder
        recordingTempURL = tempURL
        engine.startRecording(recorder)
        isRecording = true
    }

    private func stopRecording() {
        guard isRecording, let tempURL = recordingTempURL else { return }
        isRecording = false
        recordingTempURL = nil
        defer { recorder = nil }
        do {
            try engine.stopRecording()
        } catch {
            recordingError = "Couldn't save the recording: \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: tempURL)
            return
        }
        // Honest "nothing recorded" check (CLAUDE.md: no silent background work) — a near-empty
        // take is never saved as if it were a real mix.
        guard let metadata = try? FLACHeaderProbe.probe(url: tempURL), metadata.durationSeconds >= 1 else {
            recordingError = "Nothing was recorded — play something on at least one deck, then try REC again."
            try? FileManager.default.removeItem(at: tempURL)
            return
        }
        let suggestedTitle = leftInfo?.title ?? rightInfo?.title
            ?? "Mix \(Date().formatted(date: .abbreviated, time: .shortened))"
        pendingRecording = PendingMixRecording(tempURL: tempURL, durationSec: metadata.durationSeconds,
                                                suggestedTitle: suggestedTitle)
    }

    /// Moves the finished take into Mixes and indexes it. `pendingRecording` is cleared
    /// synchronously here (not inside the `Task`) so the naming alert's dismissal can never race a
    /// second, redundant discard of the same temp file.
    func savePendingRecording(title: String, into repository: MixRecordingRepository) {
        guard let pending = pendingRecording else { return }
        pendingRecording = nil
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = trimmed.isEmpty ? pending.suggestedTitle : trimmed
        Task { @MainActor [weak self] in
            do {
                let directory = AppState.mixesDirectoryURL
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let fileName = "\(UUID().uuidString).flac"
                try FileManager.default.moveItem(at: pending.tempURL, to: directory.appendingPathComponent(fileName))
                let document = MixRecordingDocument(title: resolvedTitle, durationSec: pending.durationSec,
                                                     fileRelPath: fileName)
                try await repository.save(document)
            } catch {
                self?.recordingError = "Couldn't save the mix: \(error.localizedDescription)"
            }
        }
    }

    func discardPendingRecording() {
        guard let pending = pendingRecording else { return }
        pendingRecording = nil
        try? FileManager.default.removeItem(at: pending.tempURL)
    }

    func state(_ side: DJDeckSide) -> DeckLoadState { side == .left ? leftState : rightState }
    func info(_ side: DJDeckSide) -> LoadedDeckInfo? { side == .left ? leftInfo : rightInfo }
    func isPlaying(_ side: DJDeckSide) -> Bool { side == .left ? leftPlaying : rightPlaying }
    func isPFL(_ side: DJDeckSide) -> Bool { side == .left ? leftPFL : rightPFL }

    private func setState(_ state: DeckLoadState, side: DJDeckSide) {
        switch side {
        case .left: leftState = state
        case .right: rightState = state
        }
    }

    private func setInfo(_ info: LoadedDeckInfo, side: DJDeckSide) {
        switch side {
        case .left: leftInfo = info
        case .right: rightInfo = info
        }
    }

    private func setPlaying(_ playing: Bool, side: DJDeckSide) {
        switch side {
        case .left: leftPlaying = playing
        case .right: rightPlaying = playing
        }
    }
}
