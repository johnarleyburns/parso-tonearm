import Foundation
import ParsoAudioAnalysis
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

/// Owns the one `DJEngine` for the manual DJ console: real load/play/pause/volume/PFL (Workstream
/// G); split-cue output routing and REC land in later commits. Platter, tempo, EQ and isolator
/// stay purely cosmetic (DJConsoleView/DeckView/MixerView) — nothing here drives them.
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

    let engine = DJEngine()
    private(set) var isRunning = false

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
