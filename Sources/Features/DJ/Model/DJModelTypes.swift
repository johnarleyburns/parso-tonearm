import SwiftUI
import TonearmCore
import ParsoAudioAnalysis

enum DJDeckID: String, CaseIterable, Identifiable, Hashable, Sendable {
    case a = "A"
    case b = "B"

    var id: String { rawValue }
}

enum DJOutputMode: String, CaseIterable, Hashable, Sendable {
    case stereo = "STEREO"
    case splitLeft = "SPLIT L"
    case splitRight = "SPLIT R"

    var helpText: String {
        switch self {
        case .stereo: return "Stereo program mix"
        case .splitLeft: return "Mono program left · headphone cue right"
        case .splitRight: return "Mono program right · headphone cue left"
        }
    }
}

enum DJLoadPhase: String, Equatable, Sendable {
    case loading
    case decoding
    case analyzing

    var label: String {
        switch self {
        case .loading: return "LOADING"
        case .decoding: return "DECODING"
        case .analyzing: return "ANALYZING"
        }
    }
}

@MainActor
final class DJDeckState: ObservableObject {
    let id: DJDeckID
    @Published var row: TrackRow?
    @Published var isPlaying = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var bpm: Double?
    @Published var key: String?
    @Published var waveform: [WaveformBin] = []
    @Published var beatPositions: [Double] = []
    @Published var downbeatPositions: [Double] = []
    @Published var elapsedTime = false
    @Published var tempo: Double = 120
    @Published var bass = 0.5
    @Published var hotCues: [Int: Double] = [:]
    @Published var hotCueColors: [Int: Int] = [:]
    @Published var hotLoops: [Int: DJHotLoop] = [:]
    @Published var cuePoint: Double?
    @Published var loopIn: Double?
    @Published var loopOut: Double?
    @Published var loopActive = false
    @Published var loopExitPending = false
    @Published var loopSetIndex = 2
    @Published var loopSetApplied = false
    @Published var padMode: DJPadMode = .hotCue
    @Published var echoPad: Double?
    @Published var tempoPercent = 0.0
    @Published var tempoRange = 10.0
    @Published var syncEnabled = false
    @Published var masterTempo = true
    @Published var keySync = false
    @Published var keyShiftSemitones = 0
    @Published var bpmOverride: Double?
    @Published var firstBeatOverride: Double?
    @Published var analyzedBPM: Double?
    @Published var analyzedFirstBeat: Double?
    @Published var previousPadMode: DJPadMode = .hotCue
    @Published var echoOutArmed = false
    @Published var vinyl = true
    @Published var slip = false
    @Published var reverse = false
    @Published var quantize = true
    @Published var eqHigh = 0.5
    @Published var eqMid = 0.5
    @Published var eqLow = 0.5
    @Published var colorFX = 0.5
    @Published var trim = 0.5
    @Published var peakMeter = 0.0
    @Published var peakHold = 0.0
    @Published var channelLevel = 1.0

    init(id: DJDeckID) { self.id = id }

    var title: String { row?.track.title ?? "LOAD TRACK " + id.rawValue }
    var artist: String { row?.artist?.name ?? "" }
    var album: String { row?.album?.title ?? "" }
    var tempoRatio: Double {
        guard let bpm, bpm > 0 else { return 1 }
        return max(0.5, min(2, tempo / bpm))
    }

    var accent: Color { id == .a ? Palette.brass : Color(red: 0.25, green: 0.52, blue: 0.86) }
}
