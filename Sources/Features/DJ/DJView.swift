import AVFoundation
import Combine
import ParsoAudioCore
import ParsoAudioAnalysis
import ParsoDJEngine
import SwiftUI
import TonearmCore
import TonearmDiscovery

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

@MainActor
final class DJPerformanceModel: ObservableObject {
    @Published var deckA = DJDeckState(id: .a)
    @Published var deckB = DJDeckState(id: .b)
    @Published var outputMode: DJOutputMode = .stereo
    @Published var cueA = false
    @Published var cueB = false
    @Published var bassFader = 0.5
    @Published var crossfader = 0.5
    @Published var activeDeck: DJDeckID = .a
    @Published private(set) var masterDeck: DJDeckID?
    @Published var headphoneLevel = 0.7
    @Published var cueMasterMix = 0.5
    @Published var isolatorLow = 0.5
    @Published var isolatorMid = 0.5
    @Published var isolatorHigh = 0.5
    @Published var beatFXDepth = 0.5
    @Published var beatFXOn = false
    @Published var beatFXAssignment = "A"
    @Published var beatFXKind = 1
    @Published var beatFXBeatIndex = 3
    @Published var autoGain = true
    @Published var recording = false
    @Published var recordingStartedAt: Date?
    @Published var masterLevel = UserDefaults.standard.object(forKey: "dj.masterLevel") as? Double ?? 0.8
    @Published var loadError: String?
    @Published private(set) var loadingDecks: Set<DJDeckID> = []
    @Published private(set) var loadPhases: [DJDeckID: DJLoadPhase] = [:]

    private let store: LibraryStore
    private var loadGeneration: [DJDeckID: Int] = [.a: 0, .b: 0]
    private var tickTask: Task<Void, Never>?
    private var glideTasks: [DJDeckID: Task<Void, Never>] = [:]
    private var audio = DJAudioBacker()
    private var scratching: Set<DJDeckID> = []
    private var tapTimes: [DJDeckID: [Date]] = [:]
    private var deckCancellables = Set<AnyCancellable>()

    init(store: LibraryStore = .shared) {
        self.store = store
        deckA.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &deckCancellables)
        deckB.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &deckCancellables)
        audio.setBassBlend(0.5)
        audio.setCrossfader(0.5)
        audio.setMasterLevel(masterLevel)
        audio.setChannelLevel(deck: .a, value: deckA.channelLevel)
        audio.setChannelLevel(deck: .b, value: deckB.channelLevel)
        if #available(iOS 17.0, macOS 14.0, *) {
            CloudSyncEngine.shared.onDJTrackPrepApplied = { [weak self] trackID in
                self?.refreshPrepIfLoaded(trackID: trackID)
            }
        }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                let active = await MainActor.run { [weak self] in
                    self?.deckA.isPlaying == true || self?.deckB.isPlaying == true || self?.scratching.isEmpty == false
                }
                // PAE's event stream is polled on the main/display actor, but
                // 60 Hz ObservableObject writes make the whole DJ surface
                // participate in every audio tick. Thirty FPS is enough for a
                // centered playhead and keeps Canvas/layout work bounded.
                try? await Task.sleep(for: .milliseconds(active ? 16 : 100))
                guard let self else { return }
                self.tick()
            }
        }
    }

    deinit {
        tickTask?.cancel()
        glideTasks.values.forEach { $0.cancel() }
    }

    private func refreshPrepIfLoaded(trackID: Int64) {
        guard let id = DJDeckID.allCases.first(where: { deck($0).row?.id == trackID }) else { return }
        let state = deck(id)
        Task { [store] in
            guard let prep = try? await store.djTrackPrep(trackId: trackID) else { return }
            state.hotCues = prep.markings.hotCues
            state.hotCueColors = prep.markings.hotCueColors
            state.hotLoops = prep.markings.hotLoops
            state.cuePoint = prep.cuePointSeconds
            state.loopIn = prep.loopInSeconds
            state.loopOut = prep.loopOutSeconds
            state.keyShiftSemitones = prep.keyShiftSemitones
            state.bpmOverride = prep.bpmOverride
            state.firstBeatOverride = prep.firstBeatOverride
            if let data = prep.analysisPayload,
               let payload = try? DJTrackPrepPayload.decoded(data) {
                state.duration = payload.duration
                state.bpm = prep.bpmOverride ?? payload.bpm
                state.key = payload.key.camelot
                state.beatPositions = payload.beatPositions
                state.downbeatPositions = payload.downbeatPositions
                state.waveform = payload.waveform.map { WaveformBin(min: $0.min, max: $0.max, rms: $0.rms, bandRMS: $0.bandRMS) }
            }
            guard state.row?.id == trackID else { return }
            audio.restoreHotCues(state.hotCues, deck: id)
            if let cue = state.cuePoint { audio.setCue(deck: id, position: cue) }
            if let start = state.loopIn, let end = state.loopOut {
                audio.setLoop(deck: id, start: start, end: end, active: state.loopActive)
            }
            audio.setPitchShift(deck: id, semitones: state.keyShiftSemitones)
        }
    }

    func deck(_ id: DJDeckID) -> DJDeckState { id == .a ? deckA : deckB }

    func load(
        _ row: TrackRow,
        into id: DJDeckID,
        resolve: @escaping (TrackRow) async throws -> URL,
        requestIndex: @escaping (Int64) async -> Void
    ) {
        cancelGlide(id)
        loadGeneration[id, default: 0] += 1
        let generation = loadGeneration[id] ?? 0
        let deck = deck(id)
        loadingDecks.insert(id)
        loadPhases[id] = .loading
        deck.isPlaying = false
        deck.position = 0
        deck.row = row
        deck.duration = row.track.durationSec ?? 0
        deck.bpm = nil
        deck.key = nil
        deck.waveform = []
        deck.beatPositions = []
        deck.downbeatPositions = []
        deck.hotCues = [:]
        deck.hotCueColors = [:]
        deck.hotLoops = [:]
        deck.cuePoint = nil
        deck.loopIn = nil
        deck.loopOut = nil
        deck.loopActive = false
        deck.loopExitPending = false
        deck.loopSetIndex = 2
        deck.loopSetApplied = false
        deck.padMode = .hotCue
        deck.echoPad = nil
        deck.tempoPercent = 0
        deck.syncEnabled = false
        deck.masterTempo = true
        deck.keySync = false
        deck.keyShiftSemitones = 0
        deck.bpmOverride = nil
        deck.firstBeatOverride = nil
        deck.analyzedBPM = nil
        deck.analyzedFirstBeat = nil
        deck.previousPadMode = .hotCue
        deck.echoOutArmed = false
        deck.vinyl = true
        deck.slip = false
        deck.reverse = false
        deck.quantize = true
        deck.tempo = 120
        loadError = nil

        Task { [weak self, store] in
            do {
                let prep = try await store.djTrackPrep(trackId: row.id)
                var cachedAnalysis: TrackAnalysis?
                if let prep {
                    deck.hotCues = prep.markings.hotCues
                    deck.hotCueColors = prep.markings.hotCueColors
                    deck.hotLoops = prep.markings.hotLoops
                    deck.cuePoint = prep.cuePointSeconds
                    deck.loopIn = prep.loopInSeconds
                    deck.loopOut = prep.loopOutSeconds
                    deck.keyShiftSemitones = prep.keyShiftSemitones
                    deck.bpmOverride = prep.bpmOverride
                    deck.firstBeatOverride = prep.firstBeatOverride
                    if let payloadData = prep.analysisPayload,
                       let payload = try? DJTrackPrepPayload.decoded(payloadData) {
                        cachedAnalysis = payload.trackAnalysis()
                        deck.duration = payload.duration
                        deck.bpm = prep.bpmOverride ?? payload.bpm
                        deck.key = payload.key.camelot
                        deck.beatPositions = payload.beatPositions
                        deck.downbeatPositions = payload.downbeatPositions
                        deck.waveform = payload.waveform.map {
                            WaveformBin(min: $0.min, max: $0.max, rms: $0.rms, bandRMS: $0.bandRMS)
                        }
                        self?.loadPhases[id] = .decoding
                    }
                }
                // Resolution may download a remote asset into the local cache.
                // It is part of loading, so a track that was not pre-indexed or
                // pre-downloaded remains a valid DJ selection.
                let url = try await resolve(row)
                guard let self else { return }
                guard self.loadGeneration[id] == generation else { return }
                if cachedAnalysis == nil { self.loadPhases[id] = .analyzing }
                let sourceURL = url
                let sourceCodec = row.track.codec
                let sourceBookmark = row.asset?.bookmark
                let cachedTrackAnalysis = cachedAnalysis
                let cachedSourceFrameCount = prep?.sourceFrameCount
                let prepared = try await Task.detached(priority: .userInitiated) {
                    if let bookmark = sourceBookmark {
                        guard let prepared = try BookmarkVault.withAccess(bookmark, {
                            try DJAudioBacker.prepare(url: $0, codec: sourceCodec,
                                                      cachedAnalysis: cachedTrackAnalysis,
                                                      cachedFrameCount: cachedSourceFrameCount)
                        }) else { throw DJAudioError.unavailable }
                        return prepared
                    }
                    return try DJAudioBacker.prepare(url: sourceURL, codec: sourceCodec,
                                                     cachedAnalysis: cachedTrackAnalysis,
                                                     cachedFrameCount: cachedSourceFrameCount)
                }.value
                guard self.loadGeneration[id] == generation,
                      self.deck(id).row?.id == row.id else { return }
                if cachedAnalysis != nil && !prepared.usedCached {
                    self.loadPhases[id] = .analyzing
                }
                let analyzedBPM = prepared.analysis.tempo.bpm
                let analyzedFirstBeat = prepared.analysis.tempo.beatPositions.first ?? 0
                var analysis = prepared.analysis
                if let bpmOverride = prep?.bpmOverride, bpmOverride > 0 {
                    analysis.tempo.bpm = bpmOverride
                    let first = max(0, prep?.firstBeatOverride ?? 0)
                    let beat = 60 / bpmOverride
                    analysis.tempo.beatPositions = stride(from: first, through: analysis.duration, by: beat).map { $0 }
                    analysis.tempo.downbeatPositions = stride(from: first, through: analysis.duration, by: beat * 4).map { $0 }
                }
                try self.audio.load(prepared, analysis: analysis, deck: id)
                self.audio.setChannelLevel(deck: id, value: deck.channelLevel)
                self.audio.setCrossfader(self.crossfader)
                self.audio.setMasterLevel(self.masterLevel)
                self.audio.setReverse(deck: id, enabled: deck.reverse)
                self.audio.restoreHotCues(deck.hotCues, deck: id)
                self.audio.setPitchShift(deck: id, semitones: deck.keyShiftSemitones)
                self.audio.setKeyLock(deck: id, enabled: deck.masterTempo)
                if let cue = deck.cuePoint { self.audio.setCue(deck: id, position: cue) }
                if let start = deck.loopIn, let end = deck.loopOut { self.audio.setLoop(deck: id, start: start, end: end, active: false) }
                self.loadingDecks.remove(id)
                self.loadPhases[id] = nil
                deck.duration = analysis.duration
                deck.analyzedBPM = analyzedBPM
                deck.analyzedFirstBeat = analyzedFirstBeat
                deck.waveform = self.audio.waveform(for: id)
                deck.beatPositions = analysis.tempo.beatPositions
                deck.downbeatPositions = analysis.tempo.downbeatPositions
                let indexed = try? await store.discoveryTrackAnalysis(trackId: row.id)
                deck.bpm = indexed?.bpm ?? prep?.bpmOverride ?? analysis.tempo.bpm
                deck.key = indexed?.key ?? analysis.key.camelot
                if let bpm = deck.bpm { deck.tempo = bpm }
                let gain = analysis.loudness.gainToTargetDB
                if autoGain, gain.isFinite {
                    deck.trim = max(0, min(1, 0.5 + gain / 12))
                    self.audio.setTrim(deck: id, value: deck.trim)
                }
                if !prepared.usedCached, row.id >= 0 {
                    let payload = DJTrackPrepPayload(analysis: analysis, sourceFrameCount: Int64(prepared.buffer.frameCount))
                    let data = try payload.encoded()
                    try? await store.saveDJAnalysis(data,
                                                    meta: (DJTrackPrepPayload.currentAlgorithmID,
                                                           DJTrackPrepPayload.currentVersion,
                                                           prepared.buffer.format.sampleRate,
                                                           Int64(prepared.buffer.frameCount),
                                                           analysis.tempo.bpm,
                                                           analysis.key.camelot),
                                                    trackId: row.id)
                    await CloudSyncEngine.shared.enqueueDJTrackPrep(trackId: row.id)
                }
                if indexed == nil, row.id >= 0 {
                    // Queue the durable library index as soon as the track has
                    // been made playable. The DJ's local analysis above keeps
                    // the deck useful immediately while the shared indexer
                    // finishes in the background.
                    await requestIndex(row.id)
                }
            } catch {
                guard let self, self.loadGeneration[id] == generation else { return }
                self.loadingDecks.remove(id)
                self.loadPhases[id] = nil
                deck.duration = 0
        deck.waveform = []
                self.loadError = "This track could not be prepared for DJ playback. Check the file or connection and try again."
            }
        }
    }

    func toggle(_ id: DJDeckID) {
        let deck = deck(id)
        guard deck.row != nil else { return }
        deck.isPlaying.toggle()
        if deck.isPlaying {
            audio.setReverse(deck: id, enabled: deck.reverse)
            audio.play(deck: id, position: deck.position, rate: deck.tempoRatio)
        }
        else { stop(deck: id) }
    }

    func selectDeck(_ id: DJDeckID) { activeDeck = id }

    func deckIsOnAir(_ id: DJDeckID) -> Bool {
        let channel = id == .a ? deckA.channelLevel : deckB.channelLevel
        let crossGain = id == .a ? (crossfader <= 0.5 ? 1 : (1 - crossfader) * 2)
                                 : (crossfader >= 0.5 ? 1 : crossfader * 2)
        return deck(id).isPlaying && channel > 0.05 && crossGain > 0.05
    }

    func setPlaying(_ playing: Bool, deck id: DJDeckID) {
        let deck = deck(id)
        guard deck.row != nil else { return }
        deck.isPlaying = playing
        if playing { audio.play(deck: id, position: deck.position, rate: deck.tempoRatio) }
        else { stop(deck: id) }
    }

    func nudge(_ id: DJDeckID, direction: Double) {
        cancelGlide(id)
        seek(id, by: direction / 75)
    }

    /// Maps the platter's outer ring and top plate to the same transport
    /// vocabulary used by the hardware handoff: outer-ring nudge while
    /// playing, vinyl scratch on the top plate, and frame/beat search while
    /// paused.
    func jog(_ id: DJDeckID, angle: Double, outerRing: Bool) {
        let state = deck(id)
        if !state.isPlaying {
            // A stopped jog must update the model position as well as the
            // engine position. Calling transient PAE frameSearch here leaves
            // the model at the old beat, so the release-time quantize pass
            // snaps the track back by several seconds.
            seek(id, by: DJJogMapper.pausedSeekSeconds(angle: angle,
                                                       outerRing: outerRing,
                                                       bpm: state.tempo))
            return
        }
        let action = DJJogMapper.action(angle: angle, isPlaying: state.isPlaying,
                                        vinyl: state.vinyl, bpm: state.tempo)
        switch action {
        case .nudge(let amount):
            nudge(id, direction: outerRing ? amount : amount * 0.35)
        case .scratch(let samples):
            guard !outerRing else { nudge(id, direction: samples / 48_000); return }
            if !scratching.contains(id) { scratching.insert(id); audio.beginScratch(deck: id) }
            audio.scratch(deck: id, seconds: -samples / 48_000)
        case .frameSearch(let seconds):
            audio.frameSearch(deck: id, seconds: outerRing ? seconds * 2 : seconds)
        case .seek(let seconds):
            seek(id, by: seconds * (outerRing ? 2 : 1))
        }
    }

    func movePaused(_ id: DJDeckID, by pixels: CGFloat, width: CGFloat) {
        let deck = deck(id)
        guard !deck.isPlaying, deck.duration > 0, width > 0 else { return }
        cancelGlide(id)
        seek(id, by: DJWaveformSeekMapping.seconds(translation: pixels,
                                                    width: width,
                                                    duration: deck.duration))
    }

    func snapIfQuantized(_ id: DJDeckID) {
        let state = deck(id)
        guard state.quantize else { return }
        seek(id, to: quantizedPosition(state, state.position))
    }

    func scratch(_ id: DJDeckID, by pixels: CGFloat, width: CGFloat) {
        let deck = deck(id)
        guard deck.isPlaying, deck.duration > 0, width > 0 else { return }
        if !scratching.contains(id) {
            scratching.insert(id)
            audio.beginScratch(deck: id)
        }
        audio.scratch(deck: id, seconds: -Double(pixels / width) * min(deck.duration, 2))
    }

    func endScratch(_ id: DJDeckID) {
        guard scratching.remove(id) != nil else { return }
        audio.endScratch(deck: id)
    }

    func beginScratch(_ id: DJDeckID) {
        guard deck(id).isPlaying else { return }
        scratching.insert(id)
        audio.beginScratch(deck: id)
    }

    func flick(_ id: DJDeckID, translation: CGFloat, predictedTranslation: CGFloat, width: CGFloat) {
        let deck = deck(id)
        guard !deck.isPlaying, deck.duration > 0, width > 0 else { return }
        cancelGlide(id)
        let remaining = predictedTranslation - translation
        let seconds = -Double(remaining / width) * min(deck.duration, 3)
        guard seconds.isFinite, abs(seconds) > 0.005 else { return }

        glideTasks[id] = Task { @MainActor [weak self] in
            var velocity = seconds / 0.35
            while abs(velocity) > 0.01 {
                do { try await Task.sleep(for: .milliseconds(16)) }
                catch { return }
                guard let self, !Task.isCancelled, !self.deck(id).isPlaying else { return }
                self.seek(id, by: velocity * 0.016)
                velocity *= 0.90
            }
            self?.glideTasks[id] = nil
        }
    }

    func changeTempo(_ id: DJDeckID, zoom: CGFloat) {
        let deck = deck(id)
        guard deck.row != nil else { return }
        let step = zoom > 1 ? -0.1 : 0.1
        deck.tempo = max(20, min(300, (deck.tempo + step).rounded(toPlaces: 1)))
        audio.setRate(deck: id, rate: deck.tempoRatio)
    }

    func setTempoPercent(_ id: DJDeckID, value: Double) {
        let deck = deck(id)
        guard !deck.syncEnabled else { return }
        deck.tempoPercent = max(-deck.tempoRange, min(deck.tempoRange, (value * 10).rounded() / 10))
        if let bpm = deck.bpm { deck.tempo = bpm * (1 + deck.tempoPercent / 100) }
        audio.setRate(deck: id, rate: deck.tempoRatio)
    }

    func cycleTempoRange(_ id: DJDeckID) {
        let values = [6.0, 10.0, 16.0, 100.0]
        let index = values.firstIndex(of: deck(id).tempoRange) ?? 1
        deck(id).tempoRange = values[(index + 1) % values.count]
    }

    func resetTempo(_ id: DJDeckID) {
        deck(id).tempoPercent = 0
        if let bpm = deck(id).bpm { deck(id).tempo = bpm }
        deck(id).syncEnabled = false
        audio.setRate(deck: id, rate: 1)
    }

    func toggleSync(_ id: DJDeckID) {
        let deck = deck(id)
        deck.syncEnabled.toggle()
        if deck.syncEnabled {
            audio.sync(deck: id)
            masterDeck = id == .a ? .b : .a
        }
    }

    func toggleKeySync(_ id: DJDeckID) {
        let state = deck(id)
        state.keySync.toggle()
        if state.keySync {
            audio.keySync(deck: id, to: id == .a ? .b : .a)
        }
    }

    func toggleMasterTempo(_ id: DJDeckID) {
        let state = deck(id)
        state.masterTempo.toggle()
        audio.setKeyLock(deck: id, enabled: state.masterTempo)
    }

    func makeMaster(_ id: DJDeckID) { audio.setAsMaster(deck: id); masterDeck = id; deck(id).syncEnabled = false }

    func isMaster(_ id: DJDeckID) -> Bool { masterDeck == id }

    func activateCue(_ number: Int, deck id: DJDeckID) {
        let deck = deck(id)
        guard deck.row != nil, (1...8).contains(number) else { return }
        cancelGlide(id)
        if let hotLoop = deck.hotLoops[number] {
            deck.loopIn = hotLoop.loopIn
            deck.loopOut = hotLoop.loopOut
            deck.loopActive = true
            seek(id, to: hotLoop.position)
            audio.setLoop(deck: id, start: hotLoop.loopIn, end: hotLoop.loopOut, active: true)
            if !deck.isPlaying { deck.isPlaying = true; audio.play(deck: id, position: hotLoop.position, rate: deck.tempoRatio) }
            return
        }
        if let position = deck.hotCues[number] {
            seek(id, to: position)
            audio.jumpHotCue(number, deck: id)
        } else {
            if deck.loopActive, let start = deck.loopIn, let end = deck.loopOut, end > start {
                deck.hotLoops[number] = DJHotLoop(position: deck.position, loopIn: start, loopOut: end,
                                                  color: deck.hotCueColors[number] ?? (number - 1) % 8)
            } else {
                deck.hotCues[number] = quantizedPosition(deck, deck.position)
                deck.hotCueColors[number] = (number - 1) % 8
                audio.setHotCue(number, deck: id, position: deck.position)
            }
            saveMarkings(deck)
        }
    }

    func deleteCue(_ number: Int, deck id: DJDeckID) {
        let deck = deck(id)
        guard (1...8).contains(number) else { return }
        deck.hotCues[number] = nil
        deck.hotLoops[number] = nil
        deck.hotCueColors[number] = nil
        audio.deleteHotCue(number, deck: id)
        saveMarkings(deck)
    }

    func clearHotCues(_ id: DJDeckID) {
        let deck = deck(id)
        deck.hotCues.removeAll()
        deck.hotCueColors.removeAll()
        deck.hotLoops.removeAll()
        for slot in 1...8 { audio.deleteHotCue(slot, deck: id) }
        saveMarkings(deck)
    }

    func cueDown(_ id: DJDeckID) {
        let deck = deck(id)
        guard deck.row != nil else { return }
        if deck.isPlaying {
            audio.jumpToCue(deck: id); stop(deck: id)
        } else if let cue = deck.cuePoint, abs(deck.position - cue) <= 0.01 {
            audio.cuePlayPress(deck: id)
        } else {
            deck.cuePoint = quantizedPosition(deck, deck.position); audio.setCue(deck: id, position: deck.cuePoint ?? deck.position); audio.cuePlayPress(deck: id); saveMarkings(deck)
        }
    }

    func cueUp(_ id: DJDeckID) { audio.cuePlayRelease(deck: id); deck(id).position = audio.position(for: id) }

    func clearCue(_ id: DJDeckID) {
        deck(id).cuePoint = nil
        saveMarkings(deck(id))
    }

    func clearLoop(_ id: DJDeckID) {
        let state = deck(id)
        if state.loopActive || state.loopExitPending { audio.reloopExit(deck: id) }
        state.loopIn = nil
        state.loopOut = nil
        state.loopActive = false
        state.loopExitPending = false
        state.loopSetApplied = false
        saveMarkings(state)
    }

    func minimapSeek(_ id: DJDeckID, x: CGFloat, width: CGFloat) {
        let deck = deck(id)
        guard !deck.isPlaying, width > 0, deck.duration > 0 else { return }
        seek(id, to: deck.duration * Double(max(0, min(width, x)) / width))
    }

    func toggleEcho(_ id: DJDeckID) {
        let deck = deck(id)
        deck.echoOutArmed.toggle()
        if deck.echoOutArmed { audio.armEchoOut(deck: id) }
        else { audio.disarmEchoOut(deck: id) }
    }

    func toggleLoop(_ id: DJDeckID) {
        let deck = deck(id)
        if deck.padMode == .loop {
            deck.padMode = .hotCue
            if deck.loopActive || deck.loopExitPending { audio.reloopExit(deck: id) }
            deck.loopActive = false
            deck.loopExitPending = false
        } else {
            if deck.padMode == .fx || deck.padMode == .beatFX { audio.disarmEchoOut(deck: id) }
            deck.padMode = .loop
        }
    }

    func echoPad(_ value: Double, deck id: DJDeckID, pressed: Bool) {
        let deck = deck(id); guard deck.padMode == .fx else { return }
        deck.echoPad = pressed ? value : nil
        if pressed { audio.setEcho(deck: id, enabled: true, beats: value) }
        else { audio.setEcho(deck: id, enabled: false, beats: value) }
    }

    func loopPad(_ pad: Int, deck id: DJDeckID) {
        let deck = deck(id); guard deck.padMode == .loop else { return }
        switch pad {
        case 0:
            deck.loopIn = quantizedPosition(deck, deck.position)
            deck.loopOut = nil
            deck.loopActive = false
            deck.loopExitPending = false
            deck.loopSetApplied = false
            audio.loopIn(deck: id)
            if deck.isPlaying {
                deck.cuePoint = deck.loopIn
                audio.setCue(deck: id, position: deck.loopIn ?? deck.position)
            }
            saveMarkings(deck)
        case 1:
            guard let start = deck.loopIn, deck.position > start else { return }
            deck.loopOut = quantizedPosition(deck, deck.position); deck.loopActive = false; audio.setLoop(deck: id, start: start, end: deck.loopOut ?? deck.position, active: false); saveMarkings(deck)
        case 2:
            guard let start = deck.loopIn, deck.tempo > 0 else { return }
            let lengths = DJLoopState.lengths
            if deck.loopSetApplied { deck.loopSetIndex = (deck.loopSetIndex + 1) % lengths.count }
            let end = min(deck.duration, start + lengths[deck.loopSetIndex] * 60 / deck.tempo)
            deck.loopSetApplied = true
            deck.loopOut = end; audio.setLoop(deck: id, start: start, end: end, active: false); saveMarkings(deck)
        case 3:
            guard deck.loopIn != nil, deck.loopOut != nil else { return }
            if deck.loopExitPending {
                audio.cancelLoopExit(deck: id)
                deck.loopExitPending = false
            } else if deck.loopActive {
                audio.exitLoopAtEnd(deck: id)
                deck.loopExitPending = true
            }
            else { audio.setLoopActive(deck: id, active: true); deck.loopActive = true; deck.loopExitPending = false }
        case 4:
            loopResize(id, factor: 0.5)
        case 5:
            loopResize(id, factor: 2)
        case 6:
            beatJump(id, direction: -1)
        case 7:
            beatJump(id, direction: 1)
        default:
            break
        }
    }

    private func stop(deck id: DJDeckID) {
        let state = deck(id)
        state.isPlaying = false
        audio.stop(deck: id, echoOut: state.echoOutArmed)
    }

    private func saveMarkings(_ deck: DJDeckState) {
        guard let id = deck.row?.id, id >= 0 else { return }
        let markings = DJMarkings(hotCues: deck.hotCues, hotCueColors: deck.hotCueColors,
                                  hotLoops: deck.hotLoops, cuePointSeconds: deck.cuePoint,
                                  loopInSeconds: deck.loopIn, loopOutSeconds: deck.loopOut)
        Task { try? await store.saveDJMarkings(markings, trackId: id) }
        Task { await CloudSyncEngine.shared.enqueueDJTrackPrep(trackId: id) }
    }

    func setBass(_ value: Double) {
        bassFader = value
        audio.setBassBlend(value)
    }

    func setCrossfader(_ value: Double) {
        crossfader = value
        audio.setCrossfader(value)
    }

    func setChannelLevel(_ id: DJDeckID, value: Double) {
        if id == .a { deckA.channelLevel = value } else { deckB.channelLevel = value }
        audio.setChannelLevel(deck: id, value: value)
    }

    func setEQ(_ id: DJDeckID, high: Double? = nil, mid: Double? = nil, low: Double? = nil) {
        let deck = deck(id)
        if let high { deck.eqHigh = high }
        if let mid { deck.eqMid = mid }
        if let low { deck.eqLow = low }
        audio.setEQ(deck: id, high: deck.eqHigh, mid: deck.eqMid, low: deck.eqLow)
    }

    func setColorFX(_ id: DJDeckID, value: Double) { deck(id).colorFX = value; audio.setColorFX(deck: id, value: value) }

    func setTrim(_ id: DJDeckID, value: Double) {
        deck(id).trim = DJFaderMapping.snapped(value)
        audio.setTrim(deck: id, value: deck(id).trim)
    }

    func flatMix() {
        deckA.eqHigh = 0.5; deckA.eqMid = 0.5; deckA.eqLow = 0.5; deckA.colorFX = 0.5
        deckB.eqHigh = 0.5; deckB.eqMid = 0.5; deckB.eqLow = 0.5; deckB.colorFX = 0.5
        isolatorLow = 0.5; isolatorMid = 0.5; isolatorHigh = 0.5
        audio.setEQ(deck: .a, high: 0.5, mid: 0.5, low: 0.5)
        audio.setEQ(deck: .b, high: 0.5, mid: 0.5, low: 0.5)
        audio.setColorFX(deck: .a, value: 0.5); audio.setColorFX(deck: .b, value: 0.5)
        audio.setIsolator(low: 0.5, mid: 0.5, high: 0.5)
    }

    func setHeadphoneLevel(_ value: Double) { headphoneLevel = value; audio.setHeadphoneLevel(value) }
    func setCueMasterMix(_ value: Double) { cueMasterMix = value; audio.setCueMasterMix(value) }
    func setIsolator(_ which: Int, value: Double) {
        switch which { case 0: isolatorLow = value; case 1: isolatorMid = value; default: isolatorHigh = value }
        audio.setIsolator(low: isolatorLow, mid: isolatorMid, high: isolatorHigh)
    }

    func toggleRecording() {
        recording.toggle(); recordingStartedAt = recording ? Date() : nil
        audio.setRecording(recording)
    }

    func setPadMode(_ id: DJDeckID, mode: DJPadMode) {
        let deck = deck(id)
        if mode == .keyShift || mode == .grid {
            deck.previousPadMode = deck.padMode
            deck.padMode = mode
            return
        }
        if mode == .fx {
            if deck.padMode == .fx {
                deck.padMode = .beatFX
            } else {
                deck.padMode = .fx
            }
        } else if mode == .loop && deck.padMode == .loop {
            toggleLoop(id)
        } else {
            if deck.padMode == .loop, deck.loopActive {
                audio.reloopExit(deck: id)
                deck.loopActive = false
                deck.loopExitPending = false
            }
            if deck.padMode == .fx || deck.padMode == .beatFX { audio.disarmEchoOut(deck: id); deck.echoOutArmed = false }
            deck.padMode = mode
        }
    }

    func toggleDeckMode(_ id: DJDeckID, _ mode: DJDeckMode) {
        let deck = deck(id)
        switch mode {
        case .vinyl: deck.vinyl.toggle(); audio.setVinyl(deck: id, enabled: deck.vinyl)
        case .slip: deck.slip.toggle(); audio.setSlip(deck: id, enabled: deck.slip)
        case .reverse:
            deck.reverse.toggle()
            audio.setReverse(deck: id, enabled: deck.reverse)
            let start = DJReversePlaybackPolicy.startPosition(enabled: deck.reverse,
                                                               isPlaying: deck.isPlaying,
                                                               current: deck.position,
                                                               duration: deck.duration)
            if start != deck.position { seek(id, to: start) }
        case .quantize: deck.quantize.toggle(); audio.setQuantize(deck: id, enabled: deck.quantize)
        }
    }

    func setPadAction(_ id: DJDeckID, index: Int, pressed: Bool = false) {
        let deck = deck(id)
        switch deck.padMode {
        case .hotCue:
            guard (0..<8).contains(index) else { return }
            activateCue(index + 1, deck: id)
        case .loop:
            if index < 8 { loopPad(index, deck: id) }
        case .fx:
            let beats = [0.25, 0.5, 1.0, 2.0]
            if index < 4 { echoPad(beats[index], deck: id, pressed: pressed) }
            else if index == 4, pressed { toggleEcho(id) }
            else if index == 5, pressed { audio.loopRoll(deck: id, beats: 0.5) }
            else if index == 6, pressed { audio.setReverb(deck: id, enabled: true) }
            else if index == 7, pressed { audio.brake(deck: id) }
        case .beatFX:
            switch index {
            case 0: setBeatFX(action: .nextKind)
            case 1: setBeatFX(action: .previousBeat)
            case 2: setBeatFX(action: .nextBeat)
            case 3: setBeatFX(action: .toggle)
            case 4: setBeatFX(action: .assign("A"))
            case 5: setBeatFX(action: .assign("B"))
            case 6: setBeatFX(action: .assign("M"))
            case 7: setBeatFX(action: .depth(min(1, beatFXDepth + 0.1)))
            default: break
            }
        case .mix:
            switch index {
            case 0: setTrim(.a, value: deckA.trim + 0.05)
            case 1: setTrim(.b, value: deckB.trim + 0.05)
            case 2: autoGain.toggle()
            case 3: toggleRecording()
            case 4: setIsolator(0, value: DJFaderMapping.snapped(isolatorLow + 0.05))
            case 5: setIsolator(1, value: DJFaderMapping.snapped(isolatorMid + 0.05))
            case 6: setIsolator(2, value: DJFaderMapping.snapped(isolatorHigh + 0.05))
            case 7: flatMix()
            default: break
            }
        case .keyShift:
            switch index {
            case 0: shiftKey(id, by: -1)
            case 1: shiftKey(id, by: 1)
            case 2: shiftKey(id, by: -2)
            case 3: shiftKey(id, by: 2)
            case 4: toggleKeySync(id)
            case 5: shiftKey(id, by: -deck.keyShiftSemitones)
            case 6: toggleMasterTempo(id)
            case 7: doneTool(id)
            default: break
            }
        case .grid:
            switch index {
            case 0: adjustGrid(id, by: -0.01)
            case 1: adjustGrid(id, by: 0.01)
            case 2: setGridHere(id)
            case 3: tapTempo(id)
            case 4: setBPMOverride(id, value: (deck.bpmOverride ?? deck.bpm ?? 120) / 2)
            case 5: setBPMOverride(id, value: (deck.bpmOverride ?? deck.bpm ?? 120) * 2)
            case 6: resetGrid(id)
            case 7: doneTool(id)
            default: break
            }
        case .echo:
            break
        }
    }

    func setBeatFX(action: DJBeatFXAction) {
        switch action {
        case .nextKind: beatFXKind = (beatFXKind + 1) % 12
        case .previousBeat: beatFXBeatIndex = max(0, beatFXBeatIndex - 1)
        case .nextBeat: beatFXBeatIndex = min(7, beatFXBeatIndex + 1)
        case .toggle: beatFXOn.toggle()
        case .assign(let value): beatFXAssignment = value
        case .depth(let value): beatFXDepth = value
        }
        audio.setBeatFX(kind: beatFXKind, beat: beatFXBeatIndex, depth: beatFXDepth,
                        assignment: beatFXAssignment, enabled: beatFXOn)
    }

    func loopResize(_ id: DJDeckID, factor: Double) {
        guard let start = deck(id).loopIn, let end = deck(id).loopOut else { return }
        let newEnd = min(deck(id).duration, start + (end - start) * factor)
        deck(id).loopOut = newEnd
        audio.setLoop(deck: id, start: start, end: newEnd, active: deck(id).loopActive)
        saveMarkings(deck(id))
    }

    func beatJump(_ id: DJDeckID, direction: Double) {
        let beats = deck(id).loopOut.flatMap { out in
            deck(id).loopIn.map { max(1, Int(((out - $0) * (deck(id).bpm ?? 120) / 60).rounded())) }
        } ?? 4
        seek(id, by: direction * Double(beats) * 60 / max(1, deck(id).bpm ?? 120))
    }

    func loopLengthLabel(_ id: DJDeckID) -> String {
        let index = max(0, min(DJLoopState.lengths.count - 1, deck(id).loopSetIndex))
        return String(Int(DJLoopState.lengths[index]))
    }

    func tapTempo(_ id: DJDeckID) {
        let now = Date()
        var taps = tapTimes[id, default: []].filter { now.timeIntervalSince($0) < 2.5 }
        taps.append(now)
        tapTimes[id] = Array(taps.suffix(8))
        guard taps.count >= 4 else { return }
        let intervals = zip(taps.dropFirst(), taps).map { $0.timeIntervalSince($1) }
        let average = intervals.reduce(0, +) / Double(intervals.count)
        guard average > 0 else { return }
        setBPMOverride(id, value: 60 / average)
    }

    private func shiftKey(_ id: DJDeckID, by amount: Int) {
        deck(id).keyShiftSemitones = max(-12, min(12, deck(id).keyShiftSemitones + amount))
        audio.setPitchShift(deck: id, semitones: deck(id).keyShiftSemitones)
        saveGrid(deck(id))
    }

    private func setBPMOverride(_ id: DJDeckID, value: Double) {
        let deck = deck(id)
        guard value.isFinite, value > 20 else { return }
        deck.bpmOverride = min(300, max(20, value))
        deck.bpm = deck.bpmOverride
        deck.tempo = deck.bpmOverride ?? deck.tempo
        applyGridToAudio(deck)
        saveGrid(deck)
    }

    private func adjustGrid(_ id: DJDeckID, by seconds: Double) {
        let deck = deck(id)
        deck.firstBeatOverride = (deck.firstBeatOverride ?? deck.beatPositions.first ?? 0) + seconds
        applyGridToAudio(deck)
        saveGrid(deck)
    }

    private func setGridHere(_ id: DJDeckID) {
        let deck = deck(id)
        let bpm = deck.bpm ?? 120
        let beat = 60 / bpm
        let snapped = deck.quantize ? (deck.position / beat).rounded() * beat : deck.position
        let delta = max(0, snapped) - (deck.beatPositions.first ?? 0)
        adjustGrid(id, by: delta)
    }

    private func resetGrid(_ id: DJDeckID) {
        let deck = deck(id)
        deck.bpmOverride = nil; deck.firstBeatOverride = nil
        if let bpm = deck.analyzedBPM, let firstBeat = deck.analyzedFirstBeat {
            deck.bpm = bpm
            deck.tempo = bpm * (1 + deck.tempoPercent / 100)
            audio.setBeatGrid(deck: id, bpm: bpm, firstBeat: firstBeat)
            deck.beatPositions = makeBeatPositions(bpm: bpm, firstBeat: firstBeat, duration: deck.duration)
            deck.downbeatPositions = makeBeatPositions(bpm: bpm, firstBeat: firstBeat, duration: deck.duration, beatsPerBar: 4)
        }
        saveGrid(deck)
    }

    private func applyGridToAudio(_ deck: DJDeckState) {
        guard let bpm = deck.bpm ?? deck.bpmOverride, bpm > 0 else { return }
        let firstBeat = deck.firstBeatOverride ?? deck.beatPositions.first ?? 0
        audio.setBeatGrid(deck: deck.id, bpm: bpm, firstBeat: firstBeat)
        deck.beatPositions = makeBeatPositions(bpm: bpm, firstBeat: firstBeat, duration: deck.duration)
        deck.downbeatPositions = makeBeatPositions(bpm: bpm, firstBeat: firstBeat, duration: deck.duration, beatsPerBar: 4)
    }

    private func makeBeatPositions(bpm: Double, firstBeat: Double, duration: Double, beatsPerBar: Int = 1) -> [Double] {
        DJGridOverride.positions(bpm: bpm, firstBeat: firstBeat, duration: duration, beatsPerBar: beatsPerBar)
    }

    private func doneTool(_ id: DJDeckID) { deck(id).padMode = deck(id).previousPadMode }

    private func saveGrid(_ deck: DJDeckState) {
        guard let id = deck.row?.id, id >= 0 else { return }
        Task {
            try? await store.saveDJGrid(bpmOverride: deck.bpmOverride,
                                        firstBeatOverride: deck.firstBeatOverride,
                                        keyShiftSemitones: deck.keyShiftSemitones,
                                        trackId: id)
            await CloudSyncEngine.shared.enqueueDJTrackPrep(trackId: id)
        }
    }

    func setMasterLevel(_ value: Double) {
        masterLevel = max(0, min(1, value))
        UserDefaults.standard.set(masterLevel, forKey: "dj.masterLevel")
        audio.setMasterLevel(masterLevel)
    }

    func setOutputMode(_ mode: DJOutputMode) {
        outputMode = mode
        audio.setOutputMode(mode, cueA: cueA, cueB: cueB)
    }

    func toggleCue(_ id: DJDeckID) {
        if id == .a { cueA.toggle() } else { cueB.toggle() }
        audio.setCue(deck: id, enabled: id == .a ? cueA : cueB,
                     outputMode: outputMode,
                     cueA: cueA,
                     cueB: cueB)
    }

    func stopAll() {
        glideTasks.values.forEach { $0.cancel() }
        glideTasks.removeAll()
        for id in scratching { audio.endScratch(deck: id) }
        scratching.removeAll()
        for id in DJDeckID.allCases {
            deck(id).isPlaying = false
            audio.pause(deck: id)
        }
        audio.stop()
    }

    private func seek(_ id: DJDeckID, by amount: Double) {
        seek(id, to: deck(id).position + amount)
    }

    private func seek(_ id: DJDeckID, to value: Double) {
        let deck = deck(id)
        let position = max(0, min(deck.duration, value))
        deck.position = position
        audio.seek(deck: id, position: position)
    }

    private func quantizedPosition(_ deck: DJDeckState, _ position: Double) -> Double {
        guard deck.quantize else { return max(0, min(deck.duration, position)) }
        var grid = deck.beatPositions
        if grid.isEmpty, let bpm = deck.bpm, bpm > 0 {
            let spacing = 60 / bpm
            let count = max(0, Int((deck.duration / spacing).rounded()))
            grid = (0...count).map { Double($0) * spacing }
        }
        guard let nearest = grid.min(by: { abs($0 - position) < abs($1 - position) }) else { return position }
        return max(0, min(deck.duration, nearest))
    }

    private func tick() {
        audio.pollEvents()
        for id in DJDeckID.allCases {
            let deck = deck(id)
            let position = min(deck.duration, audio.position(for: id))
            if abs(deck.position - position) >= 0.005 {
                deck.position = position
            }
            if !scratching.contains(id) {
                let isPlaying = audio.isPlaying(for: id)
                if deck.isPlaying != isPlaying { deck.isPlaying = isPlaying }
            }
            if deck.duration > 0, deck.position >= deck.duration - 0.05, !audio.isPlaying(for: id) {
                deck.position = deck.duration
                deck.isPlaying = false
            }
            let loopActive = audio.isLoopActive(for: id)
            if deck.loopActive != loopActive { deck.loopActive = loopActive }
            if deck.loopExitPending && !loopActive { deck.loopExitPending = false }
            deck.peakMeter = Double(audio.peakMeter(for: id))
            deck.peakHold = Double(audio.peakHold(for: id))
        }
    }

    private func cancelGlide(_ id: DJDeckID) {
        glideTasks[id]?.cancel()
        glideTasks[id] = nil
    }
}

@MainActor
private final class DJAudioBacker {
    private let engine = DJEngine(sampleRate: 48_000, maxFramesPerRender: 512,
                                  deckCount: 2, profile: .full)
    private let splitLeftRouter = DJMasterOutputRouter(mode: .splitLeft)
    private let splitRightRouter = DJMasterOutputRouter(mode: .splitRight)
    private var prepared: [DJDeckID: PreparedDJTrack] = [:]
    private var recorder: MixRecorder?
    private var bassBlend = 0.5
    private var lowEQ: [DJDeckID: Double] = [.a: 0.5, .b: 0.5]

    struct PreparedDJTrack: Sendable {
        let buffer: PCMBuffer
        let analysis: TrackAnalysis
        let usedCached: Bool
    }

    nonisolated static func prepare(url: URL, codec: String?,
                                    cachedAnalysis: TrackAnalysis? = nil,
                                    cachedFrameCount: Int64? = nil) throws -> PreparedDJTrack {
        let buffer = try AudioFileReader(url: url, container: container(codec: codec, url: url)).readAll()
        let cacheMatches = cachedAnalysis != nil
            && cachedFrameCount == Int64(buffer.frameCount)
            && abs(cachedAnalysis!.format.sampleRate - buffer.format.sampleRate) < 0.5
        let analysis = cacheMatches ? cachedAnalysis! : TrackAnalyzer().analyze(buffer)
        return PreparedDJTrack(buffer: buffer, analysis: analysis, usedCached: cacheMatches)
    }

    private nonisolated static func container(codec: String?, url: URL) -> AudioContainer {
        let queryFormat = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { ["format", "audioformat", "audiodlformat"].contains($0.name.lowercased()) })?.value
        let value = (codec ?? queryFormat ?? url.pathExtension).lowercased()
        if value.contains("flac") { return .flac }
        if value.contains("opus") { return .opus }
        if value.contains("ogg") { return .oggVorbis }
        if value.contains("mp3") || value.contains("mpeg") { return .mp3 }
        if value.contains("aac") { return .aac }
        if value.contains("m4b") { return .m4b }
        if value.contains("m4a") || value.contains("alac") || value.contains("mp4") { return .m4a }
        if value.contains("aiff") || value == "aif" { return .aiff }
        if value.contains("caf") { return .caf }
        if value.contains("wav") { return .wav }
        return .auto
    }

    func load(_ track: PreparedDJTrack, analysis: TrackAnalysis? = nil, deck: DJDeckID) throws {
        if !engine.isRunning { try start() }
        let index = deck == .a ? 0 : 1
        let selectedAnalysis = analysis ?? track.analysis
        engine.decks[index].load(selectedAnalysis, buffer: track.buffer)
        engine.decks[index].tempoRange = .wide
        prepared[deck] = PreparedDJTrack(buffer: track.buffer, analysis: selectedAnalysis,
                                         usedCached: track.usedCached)
        restoreHotCues(deck)
    }

    func waveform(for deck: DJDeckID) -> [WaveformBin] {
        guard let waveform = prepared[deck]?.analysis.waveform else { return [] }
        return waveform.overviewMinMax.indices.map { index in
            let bands = waveform.bandEnergy.indices.contains(index) ? waveform.bandEnergy[index] : .zero
            let rms = waveform.detailRMS.indices.contains(index) ? waveform.detailRMS[index] : 0
            return WaveformBin(min: waveform.overviewMinMax[index].x,
                               max: waveform.overviewMinMax[index].y,
                               rms: rms,
                               bandRMS: [bands.x, bands.y, bands.z])
        }
    }

    func play(deck: DJDeckID, position: Double, rate: Double) {
        if !engine.isRunning { try? start() }
        let player = engine.decks[index(for: deck)]
        setRate(deck: deck, rate: rate)
        if abs(player.playhead - position) > 0.02 { seek(deck: deck, position: position) }
        player.play()
    }

    func pause(deck: DJDeckID) { engine.decks[index(for: deck)].pause() }

    func pollEvents() { engine.pollEvents() }

    func setBeatGrid(deck: DJDeckID, bpm: Double, firstBeat: Double) {
        guard let track = prepared[deck], bpm.isFinite, bpm > 0, firstBeat.isFinite else { return }
        engine.decks[index(for: deck)].setBeatGrid(bpm: bpm, firstBeat: firstBeat)
        prepared[deck] = PreparedDJTrack(buffer: track.buffer,
                                         analysis: gridAdjustedAnalysis(track.analysis,
                                                                        bpm: bpm,
                                                                        firstBeat: firstBeat),
                                         usedCached: track.usedCached)
    }

    private func gridAdjustedAnalysis(_ analysis: TrackAnalysis, bpm: Double, firstBeat: Double) -> TrackAnalysis {
        var adjusted = analysis
        let first = max(0, min(adjusted.duration, firstBeat))
        let beat = 60 / bpm
        adjusted.tempo.bpm = bpm
        adjusted.tempo.beatPositions = stride(from: first, through: adjusted.duration, by: beat).map { $0 }
        adjusted.tempo.downbeatPositions = stride(from: first, through: adjusted.duration, by: beat * 4).map { $0 }
        return adjusted
    }

    func setMasterLevel(_ value: Double) {
        engine.mixer.master.level = max(0, min(1, value))
    }

    func seek(deck: DJDeckID, position: Double) {
        guard let track = prepared[deck] else { return }
        let frame = Int64(max(0, min(Double(track.buffer.frameCount),
                                     position * track.buffer.format.sampleRate)).rounded())
        engine.decks[index(for: deck)].seek(toSample: frame, quantized: false)
    }

    func position(for deck: DJDeckID) -> Double {
        engine.decks[index(for: deck)].playhead
    }

    func isPlaying(for deck: DJDeckID) -> Bool {
        engine.decks[index(for: deck)].isPlaying
    }

    func isLoopActive(for deck: DJDeckID) -> Bool {
        engine.decks[index(for: deck)].isLoopActive
    }

    func setRate(deck: DJDeckID, rate: Double) {
        let player = engine.decks[index(for: deck)]
        player.tempoRange = .wide
        player.tempoPercent = (max(0.25, min(4, rate)) - 1) * 100
    }

    func sync(deck: DJDeckID) { engine.decks[index(for: deck)].sync() }
    func setAsMaster(deck: DJDeckID) { engine.decks[index(for: deck)].setAsMaster() }
    func keySync(deck: DJDeckID, to reference: DJDeckID) {
        _ = engine.decks[index(for: deck)].keySync(to: engine.decks[index(for: reference)])
    }
    func setKeyLock(deck: DJDeckID, enabled: Bool) { engine.decks[index(for: deck)].keyLock = enabled }
    func setPitchShift(deck: DJDeckID, semitones: Int) {
        engine.decks[index(for: deck)].pitchSemitones = Double(max(-12, min(12, semitones)))
    }
    func setVinyl(deck: DJDeckID, enabled: Bool) { engine.decks[index(for: deck)].vinylMode = enabled }
    func setSlip(deck: DJDeckID, enabled: Bool) { engine.decks[index(for: deck)].slip = enabled }
    func setReverse(deck: DJDeckID, enabled: Bool) { engine.decks[index(for: deck)].reverse = enabled }
    func setQuantize(deck: DJDeckID, enabled: Bool) { engine.decks[index(for: deck)].quantize = enabled }
    func loopRoll(deck: DJDeckID, beats: Double) { engine.decks[index(for: deck)].loopRoll(beats: beats) }
    func setReverb(deck: DJDeckID, enabled: Bool) {
        engine.mixer.beatFX.kind = .reverb
        engine.mixer.beatFX.assign = deck == .a ? .chA : .chB
        engine.mixer.beatFX.isOn = enabled
    }
    func brake(deck: DJDeckID) {
        engine.mixer.beatFX.kind = .vinylBrake
        engine.mixer.beatFX.assign = deck == .a ? .chA : .chB
        engine.mixer.beatFX.isOn = true
    }
    func setBeatFX(kind: Int, beat: Int, depth: Double, assignment: String, enabled: Bool) {
        let unit = engine.mixer.beatFX
        let kinds = BeatFXUnit.Kind.allCases
        if kinds.indices.contains(kind) { unit.kind = kinds[kind] }
        unit.beats = [0.25, 0.5, 0.75, 1, 2, 4, 8, 16][max(0, min(7, beat))]
        unit.depth = max(0, min(1, depth))
        unit.assign = assignment == "B" ? .chB : assignment == "M" ? .master : .chA
        unit.isOn = enabled
    }

    func setChannelLevel(deck: DJDeckID, value: Double) {
        channel(deck).fader = max(0, min(1, value))
    }

    func setTrim(deck: DJDeckID, value: Double) {
        channel(deck).trim = max(0, min(1, value))
    }

    func setEQ(deck: DJDeckID, high: Double, mid: Double, low: Double) {
        let target = channel(deck)
        lowEQ[deck] = low
        target.eqHigh = DJKnobMapping.isolatorDB(high) ?? -.infinity
        target.eqMid = DJKnobMapping.isolatorDB(mid) ?? -.infinity
        applyCombinedLowEQ(deck)
    }

    func setColorFX(deck: DJDeckID, value: Double) {
        let target = channel(deck)
        target.colorFX = .filter
        target.colorAmount = (max(0, min(1, value)) - 0.5) * 2
    }

    func setHeadphoneLevel(_ value: Double) { engine.monitoring.headphoneLevel = max(0, min(1, value)) }
    func setCueMasterMix(_ value: Double) { engine.monitoring.cueMasterMix = max(0, min(1, value)) }
    func setIsolator(low: Double, mid: Double, high: Double) {
        engine.mixer.master.isolatorLow = DJKnobMapping.isolatorDB(low) ?? -.infinity
        engine.mixer.master.isolatorMid = DJKnobMapping.isolatorDB(mid) ?? -.infinity
        engine.mixer.master.isolatorHigh = DJKnobMapping.isolatorDB(high) ?? -.infinity
    }

    func setRecording(_ enabled: Bool) {
        if enabled {
            guard recorder == nil,
                  let documents = try? FileManager.default.url(for: .documentDirectory,
                                                               in: .userDomainMask, appropriateFor: nil, create: true) else { return }
            let url = documents.appendingPathComponent("Mix-\(Int(Date().timeIntervalSince1970)).m4a")
            recorder = try? MixRecorder(url: url)
            if let recorder { engine.startRecording(recorder) }
        } else {
            try? engine.stopRecording()
            recorder = nil
        }
    }

    func peakMeter(for deck: DJDeckID) -> Float { channel(deck).peakMeter }
    func peakHold(for deck: DJDeckID) -> Float { channel(deck).peakHold }

    func restoreHotCues(_ cues: [Int: Double], deck: DJDeckID) {
        guard let track = prepared[deck] else { return }
        let player = engine.decks[index(for: deck)]
        for bank in 0..<2 {
            player.hotCueBank = bank
            for slot in 0..<4 { player.deleteHotCue(slot) }
        }
        for (slot, position) in cues {
            guard let mapped = DJHotCueMapping.slot(slot) else { continue }
            player.hotCueBank = mapped.bank
            let frame = Int64(max(0, min(Double(track.buffer.frameCount),
                                         position * track.buffer.format.sampleRate)).rounded())
            player.triggerHotCue(mapped.index, atSample: frame)
        }
        player.hotCueBank = 0
    }

    func setHotCue(_ slot: Int, deck: DJDeckID, position: Double) {
        guard let track = prepared[deck], let mapped = DJHotCueMapping.slot(slot) else { return }
        let frame = Int64(max(0, min(Double(track.buffer.frameCount),
                                     position * track.buffer.format.sampleRate)).rounded())
        let player = engine.decks[index(for: deck)]
        player.hotCueBank = mapped.bank
        player.triggerHotCue(mapped.index, atSample: frame)
        player.hotCueBank = 0
    }

    func setCue(deck: DJDeckID, position: Double) {
        guard let track = prepared[deck] else { return }
        let frame = Int64(max(0, min(Double(track.buffer.frameCount),
                                     position * track.buffer.format.sampleRate)).rounded())
        engine.decks[index(for: deck)].setCue(atSample: frame)
    }

    func jumpToCue(deck: DJDeckID) { engine.decks[index(for: deck)].jumpToCue() }
    func cuePlayPress(deck: DJDeckID) { engine.decks[index(for: deck)].cuePlayPress() }
    func cuePlayRelease(deck: DJDeckID) { engine.decks[index(for: deck)].cuePlayRelease() }

    func setLoop(deck: DJDeckID, start: Double, end: Double, active: Bool) {
        guard let track = prepared[deck] else { return }
        let rate = track.buffer.format.sampleRate
        let maxFrame = Double(track.buffer.frameCount)
        let startFrame = Int64(max(0, min(maxFrame, start * rate)).rounded())
        let endFrame = Int64(max(0, min(maxFrame, end * rate)).rounded())
        let player = engine.decks[index(for: deck)]
        player.setLoop(startSample: startFrame, endSample: endFrame)
        player.setActiveLoop(active)
    }

    func loopIn(deck: DJDeckID) { engine.decks[index(for: deck)].loopIn() }
    func setLoopActive(deck: DJDeckID, active: Bool) { engine.decks[index(for: deck)].setActiveLoop(active) }
    func exitLoopAtEnd(deck: DJDeckID) { engine.decks[index(for: deck)].exitLoopAtEnd() }
    func cancelLoopExit(deck: DJDeckID) { engine.decks[index(for: deck)].cancelLoopExit() }
    func reloopExit(deck: DJDeckID) { engine.decks[index(for: deck)].reloopExit() }

    func armEchoOut(deck: DJDeckID) { engine.decks[index(for: deck)].armEchoOut() }
    func disarmEchoOut(deck: DJDeckID) { engine.decks[index(for: deck)].disarmEchoOut() }
    func setEcho(deck: DJDeckID, enabled: Bool, beats: Double) {
        engine.decks[index(for: deck)].setEcho(enabled: enabled, beats: beats)
    }
    func stop(deck: DJDeckID, echoOut: Bool) {
        if echoOut { engine.decks[index(for: deck)].echoOutStop() }
        else { engine.decks[index(for: deck)].pause() }
    }

    func jumpHotCue(_ slot: Int, deck: DJDeckID) {
        guard let mapped = DJHotCueMapping.slot(slot) else { return }
        let player = engine.decks[index(for: deck)]
        player.hotCueBank = mapped.bank
        player.jumpHotCue(mapped.index)
        player.hotCueBank = 0
    }

    func deleteHotCue(_ slot: Int, deck: DJDeckID) {
        guard let mapped = DJHotCueMapping.slot(slot) else { return }
        let player = engine.decks[index(for: deck)]
        player.hotCueBank = mapped.bank
        player.deleteHotCue(mapped.index)
        player.hotCueBank = 0
    }

    func beginScratch(deck: DJDeckID) {
        engine.decks[index(for: deck)].jogTouchBegan()
    }

    func scratch(deck: DJDeckID, seconds: Double) {
        engine.decks[index(for: deck)].fastSearch(seconds: seconds)
    }

    func frameSearch(deck: DJDeckID, seconds: Double) {
        engine.decks[index(for: deck)].fastSearch(seconds: seconds)
    }

    func endScratch(deck: DJDeckID) {
        engine.decks[index(for: deck)].jogTouchEnded()
    }

    func setBassBlend(_ value: Double) {
        bassBlend = max(0, min(1, value))
        applyCombinedLowEQ(.a)
        applyCombinedLowEQ(.b)
    }

    private func applyCombinedLowEQ(_ deck: DJDeckID) {
        guard let value = DJBassEQMapping.combined(lowKnob: lowEQ[deck] ?? 0.5,
                                                   bassBlend: bassBlend, deckA: deck == .a) else {
            channel(deck).eqLow = -.infinity
            return
        }
        channel(deck).eqLow = value
    }

    func setCrossfader(_ value: Double) {
        engine.mixer.crossfader = (max(0, min(1, value)) * 2) - 1
    }

    func setOutputMode(_ mode: DJOutputMode, cueA: Bool, cueB: Bool) {
        switch mode {
        case .stereo: engine.mixer.setInsert(nil, at: .master)
        case .splitLeft: engine.mixer.setInsert(splitLeftRouter, at: .master)
        case .splitRight: engine.mixer.setInsert(splitRightRouter, at: .master)
        }
        setCueRouting(outputMode: mode, cueA: cueA, cueB: cueB)
    }

    func setCue(deck: DJDeckID, enabled: Bool, outputMode: DJOutputMode,
                cueA: Bool, cueB: Bool) {
        if deck == .a { engine.mixer.channelA.cuePFL = enabled }
        else { engine.mixer.channelB.cuePFL = enabled }
        setCueRouting(outputMode: outputMode, cueA: cueA, cueB: cueB)
    }

    private func setCueRouting(outputMode: DJOutputMode, cueA: Bool, cueB: Bool) {
        engine.mixer.channelA.cuePFL = cueA
        engine.mixer.channelB.cuePFL = cueB
        engine.monitoring.masterCue = cueA || cueB
        engine.monitoring.cueMasterMix = 0
        engine.monitoring.cueMode = (cueA || cueB)
            ? (outputMode == .stereo ? .cueInPlace : .splitOutput)
            : .off
    }

    func stop() {
        for deck in DJDeckID.allCases { engine.decks[index(for: deck)].pause() }
        if engine.isRunning { engine.stop() }
    }

    private func start() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        try session.setActive(true)
        #endif
        try engine.start()
    }

    func resolve(_ asset: Asset?) -> URL? {
        guard let asset else { return nil }
        if asset.kind == .builtIn, let channel = asset.relPath {
            return BuiltInContentProvider.bundledAudioURL(forChannelId: channel)
        }
        if let bookmark = asset.bookmark, let resolved = BookmarkVault.resolve(bookmark) {
            return resolved.url
        }
        if let remote = asset.remoteURL.flatMap(URL.init(string:)), remote.isFileURL { return remote }
        if let path = asset.relPath,
           let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask,
                                                    appropriateFor: nil, create: false) {
            let url = base.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private func index(for deck: DJDeckID) -> Int { deck == .a ? 0 : 1 }
    private func channel(_ deck: DJDeckID) -> Channel { deck == .a ? engine.mixer.channelA : engine.mixer.channelB }

    private func restoreHotCues(_ deck: DJDeckID) {
        // Hot-cue positions are restored by DJPerformanceModel's persisted
        // state; PAE receives the exact sample address when the user jumps.
    }
}

private extension DJTrackPrepPayload {
    init(analysis: TrackAnalysis, sourceFrameCount: Int64) {
        self.init(
            sampleRate: analysis.format.sampleRate,
            channels: analysis.format.channelCount,
            sourceFrameCount: sourceFrameCount,
            duration: analysis.duration,
            bpm: analysis.tempo.bpm,
            tempoConfidence: analysis.tempo.confidence,
            beatPositions: analysis.tempo.beatPositions,
            downbeatPositions: analysis.tempo.downbeatPositions,
            isConstantTempo: analysis.tempo.isConstantTempo,
            key: .init(tonic: analysis.key.tonic,
                       mode: analysis.key.mode == .minor ? "minor" : "major",
                       camelot: analysis.key.camelot,
                       openKey: analysis.key.openKey,
                       confidence: analysis.key.confidence),
            sections: analysis.sections.map {
                .init(start: $0.start, kind: String(describing: $0.kind), bar: $0.bar)
            },
            waveform: analysis.waveform.overviewMinMax.indices.map { index in
                let pair = analysis.waveform.overviewMinMax[index]
                let bands = analysis.waveform.bandEnergy.indices.contains(index)
                    ? analysis.waveform.bandEnergy[index]
                    : .zero
                let rms = analysis.waveform.detailRMS.indices.contains(index)
                    ? analysis.waveform.detailRMS[index] : 0
                return .init(min: pair.x, max: pair.y, rms: rms,
                             bandRMS: [bands.x, bands.y, bands.z])
            },
            loudness: [analysis.loudness.integratedLUFS,
                       analysis.loudness.truePeakDBTP,
                       analysis.loudness.gainToTargetDB,
                       analysis.loudness.loudnessRangeLU])
    }

    func trackAnalysis() -> TrackAnalysis {
        let kind: (String) -> ParsoAudioAnalysis.Section.Kind = { raw in
            switch raw {
            case "intro": return .intro
            case "buildup": return .buildup
            case "drop": return .drop
            case "verse": return .verse
            case "chorus": return .chorus
            case "breakdown": return .breakdown
            case "outro": return .outro
            default: return .unknown
            }
        }
        let bins = waveform.map { SIMD2<Float>($0.min, $0.max) }
        let rms = waveform.map(\.rms)
        let bands = waveform.map { value in
            let padded = value.bandRMS + [0, 0, 0]
            return SIMD3<Float>(padded[0], padded[1], padded[2])
        }
        let loud = loudness + [0, 0, 0, 0]
        return TrackAnalysis(
            format: AudioFormat(sampleRate: sampleRate, channelCount: channels),
            duration: duration,
            tempo: TempoResult(bpm: bpm, confidence: tempoConfidence,
                               beatPositions: beatPositions,
                               downbeatPositions: downbeatPositions,
                               isConstantTempo: isConstantTempo),
            key: KeyResult(tonic: key.tonic,
                           mode: key.mode == "minor" ? .minor : .major,
                           camelot: key.camelot, openKey: key.openKey,
                           confidence: key.confidence),
            sections: sections.map { ParsoAudioAnalysis.Section(start: $0.start, kind: kind($0.kind), bar: $0.bar) },
            waveform: Waveform(overviewMinMax: bins, detailRMS: rms,
                               bandEnergy: bands),
            loudness: LoudnessResult(integratedLUFS: loud[0], truePeakDBTP: loud[1],
                                     gainToTargetDB: loud[2], loudnessRangeLU: loud[3]))
    }
}

private enum DJAudioError: Error { case unavailable }

private final class DJMasterOutputRouter: RealtimeInsert {
    private let mode: DJOutputMode

    init(mode: DJOutputMode) { self.mode = mode }

    nonisolated func process(left: UnsafeMutablePointer<Float>,
                             right: UnsafeMutablePointer<Float>,
                             frames: Int) {
        guard mode != .stereo else { return }
        for frame in 0..<frames {
            let mono = (left[frame] + right[frame]) * 0.5
            switch mode {
            case .stereo: break
            case .splitLeft:
                left[frame] = mono
                right[frame] = 0
            case .splitRight:
                left[frame] = 0
                right[frame] = mono
            }
        }
    }
}

private final class DJHotCueStore {
    private let defaults = UserDefaults.standard

    func load(trackID: Int64) -> [Int: Double] {
        guard let values = defaults.dictionary(forKey: key(trackID)) as? [String: Double] else { return [:] }
        return values.reduce(into: [:]) { $0[Int($1.key) ?? 0] = $1.value }
    }

    func save(_ cues: [Int: Double], trackID: Int64) {
        defaults.set(cues.reduce(into: [:]) { $0[String($1.key)] = $1.value }, forKey: key(trackID))
    }

    private func key(_ trackID: Int64) -> String { "dj.hotCues.v1.\(trackID)" }
}

struct DJView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = DJPerformanceModel()
    @State private var loadTarget: DJDeckID?
    @State private var showHelp = false

    var body: some View {
        VStack(spacing: 0) {
            DJV2Surface(model: model, onBack: {
                appState.isPerformanceSurfaceFullScreen = false
                appState.tab = .listen
            }, onInfo: { showHelp = true }, onLoad: { loadTarget = $0 }, onReanalyze: { reanalyze($0) })
        }
        // Keep the top safe area owned by SwiftUI so the iPhone's Dynamic
        // Island/notch cannot cover the back button. The DJ surface still
        // owns the bottom edge and horizontal space for the mixer.
        .ignoresSafeArea(edges: [.bottom])
        .onAppear {
            appState.isPerformanceSurfaceFullScreen = true
        }
        .onDisappear {
            model.stopAll()
            appState.isPerformanceSurfaceFullScreen = false
        }
        .sheet(item: $loadTarget) { deck in
            DJLoadSheet(deck: deck,
                        tracks: modelTracks,
                        playlists: appState.playlists,
                        store: appState.store,
                        onLoad: { row in
                model.load(row, into: deck,
                           resolve: { row in try await appState.djPlayableURL(for: row) },
                           requestIndex: { trackID in
                               await DiscoveryRuntimeController.shared.analyzeTrack(trackID)
                           })
                loadTarget = nil
            })
        }
        .sheet(isPresented: $showHelp) {
            DJHelpSheet { topic in
                showHelp = false
                if topic.controls.contains(.loop) { model.setPadMode(model.activeDeck, mode: .loop) }
                else if topic.controls.contains(.hotCue) { model.setPadMode(model.activeDeck, mode: .hotCue) }
                else if topic.controls.contains(.beatFX) { model.setPadMode(model.activeDeck, mode: .fx); model.setPadMode(model.activeDeck, mode: .fx) }
                else if topic.controls.contains(.mix) { model.setPadMode(model.activeDeck, mode: .mix) }
                else if topic.controls.contains(.keyShift) { model.setPadMode(model.activeDeck, mode: .keyShift) }
                else if topic.controls.contains(.grid) { model.setPadMode(model.activeDeck, mode: .grid) }
            }
        }
        .alert("DJ Audio", isPresented: Binding(get: { model.loadError != nil },
                                                 set: { if !$0 { model.loadError = nil } })) {
            Button("OK", role: .cancel) { model.loadError = nil }
        } message: { Text(model.loadError ?? "") }
    }

    private var modelTracks: [TrackRow] { appState.allTracks }

    private func reanalyze(_ id: DJDeckID) {
        guard let row = model.deck(id).row else { return }
        Task { @MainActor in
            try? await appState.store.clearDJAnalysis(trackId: row.id)
            model.load(row, into: id,
                       resolve: { row in try await appState.djPlayableURL(for: row) },
                       requestIndex: { trackID in
                           await DiscoveryRuntimeController.shared.analyzeTrack(trackID)
                       })
        }
    }

}

private struct DJTitleBar: View {
    let onBack: () -> Void
    let onInfo: () -> Void

    var body: some View {
        HStack {
            Button(action: onBack) {
                Label("Platterhead DJ", systemImage: "chevron.down")
                    .font(.system(size: 15, weight: .bold))
            }
            .accessibilityLabel("Close DJ")
            Spacer()
            Button("(i)", action: onInfo)
                .font(.system(size: 17, weight: .semibold))
                .accessibilityLabel("DJ gestures and help")
        }
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(.ultraThinMaterial)
    }
}

private struct DJGridCell<Content: View>: View {
    let frame: CGRect
    let content: () -> Content

    init(frame: CGRect, @ViewBuilder content: @escaping () -> Content) {
        self.frame = frame
        self.content = content
    }

    var body: some View {
        content()
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
    }
}

private struct DJEightRowSurface: View {
    @ObservedObject var model: DJPerformanceModel
    let onLoad: (DJDeckID) -> Void

    var body: some View {
        GeometryReader { proxy in
            let layout = DJGridLayout(size: proxy.size, gap: 5)
            ZStack(alignment: .topLeading) {
                DJGridCell(frame: layout.frame(col: 0, row: 0)) { DJSmallInfoButton() }
                DJGridCell(frame: layout.frame(col: 1, row: 0, span: 3)) {
                    Text("LIVE MIX")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Palette.ink3)
                }
                DJGridCell(frame: layout.frame(col: 4, row: 0)) {
                    DJOutputButton(mode: model.outputMode, action: cycleOutput)
                }
                DJGridCell(frame: layout.frame(col: 5, row: 0)) {
                    DJVolumeButton(level: model.masterLevel, onChange: model.setMasterLevel)
                }
                DJGridCell(frame: layout.frame(col: 6, row: 0)) {
                    DJCueButton(deck: "A", isOn: model.cueA, action: { model.toggleCue(.a) })
                }
                DJGridCell(frame: layout.frame(col: 7, row: 0)) {
                    DJCueButton(deck: "B", isOn: model.cueB, action: { model.toggleCue(.b) })
                }

                DJGridCell(frame: layout.frame(col: 0, row: 1, span: 4)) {
                    DJDeckTrackCell(deck: model.deckA,
                                    loadPhase: model.loadPhases[.a],
                                    onLoad: onLoad)
                }
                DJGridCell(frame: layout.frame(col: 0, row: 6, span: 4)) {
                    DJDeckTrackCell(deck: model.deckB,
                                    loadPhase: model.loadPhases[.b],
                                    onLoad: onLoad)
                }

                DJGridCell(frame: layout.frame(col: 4, row: 1, span: 4)) {
                    DJDeckTransport(deck: model.deckA, model: model)
                }
                DJGridCell(frame: layout.frame(col: 4, row: 6, span: 4)) {
                    DJDeckTransport(deck: model.deckB, model: model)
                }
                DJGridCell(frame: layout.frame(col: 0, row: 2, span: 4)) {
                    DJDeckMinimap(deck: model.deckA, model: model)
                }
                DJGridCell(frame: layout.frame(col: 0, row: 5, span: 4)) {
                    DJDeckMinimap(deck: model.deckB, model: model)
                }
                DJGridCell(frame: layout.frame(col: 4, row: 2, span: 4)) {
                    DJPerformancePads(deck: model.deckA, model: model)
                }
                DJGridCell(frame: layout.frame(col: 4, row: 5, span: 4)) {
                    DJPerformancePads(deck: model.deckB, model: model)
                }
                DJGridCell(frame: layout.frame(col: 0, row: 3, span: 8)) {
                    DJDeckWaveform(deck: model.deckA,
                                   loadPhase: model.loadPhases[.a])
                }
                DJGridCell(frame: layout.frame(col: 0, row: 4, span: 8)) {
                    DJDeckWaveform(deck: model.deckB,
                                   loadPhase: model.loadPhases[.b])
                }

                DJGridCell(frame: layout.frame(col: 0, row: 7, span: 4)) {
                    DJFader(title: "BASS", value: model.bassFader, onChange: model.setBass)
                }
                DJGridCell(frame: layout.frame(col: 4, row: 7, span: 4)) {
                    DJFader(title: "CROSSFADER", value: model.crossfader, onChange: model.setCrossfader)
                }
            }
            .padding(7)
            .background(Palette.bg)
        }
        .clipped()
    }

    private func cycleOutput() {
        let modes = DJOutputMode.allCases
        let next = (modes.firstIndex(of: model.outputMode).map { ($0 + 1) % modes.count }) ?? 0
        model.setOutputMode(modes[next])
    }
}

private struct DJLoadBadge: View {
    let phase: DJLoadPhase

    var body: some View {
        HStack(spacing: 5) {
            ProgressView().controlSize(.small)
            Text(phase.label)
        }
        .font(.system(size: 9, weight: .black, design: .monospaced))
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(.black.opacity(0.82), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14)))
        .accessibilityLabel(phase == .analyzing ? "Analyzing track" : "Loading track")
    }
}

private struct DJDeckTrackCell: View {
    @ObservedObject var deck: DJDeckState
    let loadPhase: DJLoadPhase?
    let onLoad: (DJDeckID) -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button { onLoad(deck.id) } label: {
                HStack(spacing: 8) {
                    Text(deck.id.rawValue)
                        .font(.system(size: 12, weight: .black, design: .monospaced))
                        .foregroundStyle(deck.id == .a ? Palette.brass : Color.blue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(deck.title).font(.system(size: 13, weight: .bold)).lineLimit(1)
                        Text(deck.artist.isEmpty ? "Tap to load" : deck.artist)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Palette.ink2)
                            .lineLimit(1)
                        Text(deck.album.isEmpty ? "" : deck.album)
                            .font(.system(size: 9))
                            .foregroundStyle(Palette.ink3)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 2)
                }
                .padding(.horizontal, 8)
                .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Load deck \(deck.id.rawValue)")

            if let loadPhase {
                DJLoadBadge(phase: loadPhase)
                    .padding(5)
            }
        }
    }
}

private struct DJDeckTransport: View {
    @ObservedObject var deck: DJDeckState
    let model: DJPerformanceModel

    var body: some View {
        HStack(spacing: 5) {
            DJTransportButton(title: "CUE", active: deck.cuePoint != nil,
                              gesture: cueGesture)
            DJTransportButton(title: deck.isPlaying ? "PAUSE" : "PLAY", active: deck.isPlaying) {
                model.toggle(deck.id)
            }
            DJTransportButton(title: "ECHO", active: deck.padMode == .echo) {
                model.toggleEcho(deck.id)
            }
            DJTransportButton(title: "LOOP", active: deck.padMode == .loop) {
                model.toggleLoop(deck.id)
            }
        }
        .padding(2)
    }

    private var cueGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in model.cueDown(deck.id) }
            .onEnded { _ in model.cueUp(deck.id) }
    }
}

private struct DJDeckMinimap: View {
    @ObservedObject var deck: DJDeckState
    let model: DJPerformanceModel

    var body: some View {
        MiniMap(bins: deck.waveform, position: deck.position, duration: deck.duration,
                hotCues: deck.hotCues, accent: deck.id == .a ? Palette.brass : Color.blue)
            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                model.minimapSeek(deck.id, x: value.location.x,
                                  width: max(1, value.translation.width + value.location.x))
            })
    }
}

private struct DJDeckWaveform: View {
    @ObservedObject var deck: DJDeckState
    let loadPhase: DJLoadPhase?

    var body: some View {
        ZStack {
            WaveformCanvas(bins: deck.waveform, position: deck.position, duration: deck.duration,
                           hotCues: deck.hotCues, isPlaying: deck.isPlaying,
                           accent: deck.id == .a ? Palette.brass : Color.blue)
            Rectangle()
                .fill(deck.id == .a ? Palette.brass : Color.blue)
                .frame(width: 1.5)
                .allowsHitTesting(false)
            HStack {
                Text("\(deck.bpm.map { String(format: "%.1f", $0) } ?? "—") BPM")
                Spacer()
                Text(DJKeyFormatter.format(deck.key))
                Spacer()
                Text(formatTime(deck.position))
            }
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(Palette.ink2)
            .padding(6)
            .allowsHitTesting(false)

            if let loadPhase {
                Rectangle().fill(.black.opacity(0.42))
                DJLoadBadge(phase: loadPhase)
            }
        }
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
    }

    private func formatTime(_ value: Double) -> String {
        let seconds = max(0, Int(value.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct DJSmallInfoButton: View {
    var body: some View {
        Text("(i)").font(.system(size: 14, weight: .bold, design: .monospaced))
            .foregroundStyle(Palette.ink2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct DJOutputButton: View {
    let mode: DJOutputMode
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(mode == .stereo ? "OUT" : "SPLIT")
                Text(mode == .stereo ? "STEREO" : mode.rawValue.replacingOccurrences(of: "SPLIT ", with: ""))
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
            }
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(Palette.ink2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Output \(mode.rawValue)")
    }
}

private struct DJVolumeButton: View {
    let level: Double
    let onChange: (Double) -> Void
    @State private var presented = false
    var body: some View {
        Button { presented = true } label: {
            VStack(spacing: 1) {
                Image(systemName: "speaker.wave.2.fill")
                Text("VOL")
            }
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(Palette.ink2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $presented) {
            VStack {
                Text("MASTER").font(.caption.monospaced())
                Slider(value: Binding(get: { level }, set: onChange))
            }
            .padding()
            .presentationCompactAdaptation(.popover)
        }
    }
}

private struct DJTransportButton: View {
    let title: String
    let active: Bool
    var gesture: AnyGesture<Void>? = nil
    let action: (() -> Void)?

    init(title: String, active: Bool, gesture: some Gesture, action: (() -> Void)? = nil) {
        self.title = title; self.active = active; self.gesture = AnyGesture(gesture.map { _ in () }); self.action = action
    }
    init(title: String, active: Bool, action: @escaping () -> Void) {
        self.title = title; self.active = active; self.action = action
    }
    var body: some View {
        button
    }

    @ViewBuilder
    private var button: some View {
        let button = Button(action: action ?? {}) {
            Text(title).font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundStyle(active ? Palette.bg : Palette.ink2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(active ? Palette.brass : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        // Grid rows are intentionally taller than a phone's eight-column cell
        // width. Keep the control itself square instead of stretching it into
        // a portrait rectangle.
        .frame(maxHeight: .infinity)
        .aspectRatio(1, contentMode: .fit)

        if let gesture {
            button.simultaneousGesture(gesture)
        } else {
            button
        }
    }
}

private struct DJPerformancePads: View {
    @ObservedObject var deck: DJDeckState
    let model: DJPerformanceModel

    var body: some View {
        HStack(spacing: 4) {
            if deck.padMode == .hotCue {
                ForEach(1...4, id: \.self) { n in
                    Button { model.activateCue(n, deck: deck.id) } label: {
                        Text("\(n)")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .aspectRatio(1, contentMode: .fit)
                            .background(deck.hotCues[n] == nil ? Color.white.opacity(0.05) : Palette.brass,
                                        in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
            } else if deck.padMode == .echo {
                ForEach([0.25, 0.5, 1.0, 2.0], id: \.self) { beats in
                    Text(echoLabel(beats))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                        .background(deck.echoPad == beats ? Palette.brass : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
                        .gesture(DragGesture(minimumDistance: 0).onChanged { _ in model.echoPad(beats, deck: deck.id, pressed: true) }
                            .onEnded { _ in model.echoPad(beats, deck: deck.id, pressed: false) })
                }
            } else {
                ForEach(["IN", "OUT", "SET", deck.loopActive ? "EXIT" : "ENTER"], id: \.self) { label in
                    Button { model.loopPad(["IN", "OUT", "SET", "ENTER"].firstIndex(of: label) ?? 3, deck: deck.id) } label: {
                        Text(label)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .aspectRatio(1, contentMode: .fit)
                            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .font(.system(size: 9, weight: .black, design: .monospaced))
        .foregroundStyle(Palette.ink2)
    }

    private func echoLabel(_ beats: Double) -> String {
        switch beats {
        case 0.25: return "¼"
        case 0.5: return "½"
        case 1: return "1"
        default: return "2"
        }
    }
}

private struct DJFader: View {
    let title: String
    let value: Double
    let onChange: (Double) -> Void
    var body: some View {
        VStack(spacing: 3) {
            Text(title).font(.system(size: 9, weight: .black, design: .monospaced)).foregroundStyle(Palette.ink3)
            Slider(value: Binding(get: { value }, set: onChange))
                .tint(Palette.brass)
        }
        .padding(.horizontal, 9)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct DJHeader: View {
    let outputMode: DJOutputMode
    let cueA: Bool
    let cueB: Bool
    let onBack: () -> Void
    let onOutput: (DJOutputMode) -> Void
    let onCueA: () -> Void
    let onCueB: () -> Void
    let onInfo: () -> Void

    var body: some View {
        ZStack {
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.down")
                        Text("Platterhead DJ")
                            .font(.system(size: 15, weight: .bold))
                    }
                    .frame(height: 34)
                }
                .accessibilityLabel("Close DJ")
                Spacer()
                Button(action: onInfo) {
                    Text("(i)").font(.system(size: 17, weight: .semibold))
                        .frame(width: 34, height: 34)
                }
                .accessibilityLabel("DJ gestures and help")
            }
            HStack(spacing: 6) {
                Picker("Output", selection: Binding(get: { outputMode }, set: onOutput)) {
                    ForEach(DJOutputMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
                .accessibilityLabel("Output mode")

                DJCueButton(deck: "A", isOn: cueA, action: onCueA)
                DJCueButton(deck: "B", isOn: cueB, action: onCueB)
            }
        }
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 12)
        .background(Color.black.opacity(0.22))
    }
}

private struct DJCueButton: View {
    let deck: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text("CUE")
                Text(deck)
                    .font(.system(size: 9, weight: .black, design: .monospaced))
            }
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(isOn ? Palette.bg : Palette.ink2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .background(isOn ? Palette.brass : Color.white.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isOn ? Palette.brass : Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cue deck \(deck)")
        .accessibilityValue(isOn ? "on" : "off")
    }
}

private struct DJWaveform: View {
    @ObservedObject var deck: DJDeckState
    let model: DJPerformanceModel
    let onLoad: () -> Void
    @State private var dragStartDate = Date()
    @State private var didDrag = false
    @State private var scratchActive = false
    @State private var pinchBucket: CGFloat = 1
    @State private var lastX: CGFloat = 0
    @State private var lastSampleDate = Date()
    @State private var touchMode: TouchMode = .pending

    private enum TouchMode { case pending, nudge, move, scratch }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                header(width: proxy.size.width)
                GeometryReader { waveformProxy in
                    ZStack {
                        WaveformCanvas(bins: deck.waveform,
                                       position: deck.position,
                                       duration: deck.duration,
                                       hotCues: deck.hotCues,
                                       isPlaying: deck.isPlaying,
                                       accent: deck.id == .a ? Palette.brass : Color.blue)
                        Rectangle()
                            .fill(deck.id == .a ? Palette.brass : Color.blue)
                            .frame(width: 1.5,
                                   height: max(0, waveformProxy.size.height - 16))
                            .allowsHitTesting(false)
                        VStack {
                            Spacer()
                            HStack {
                                Text(deck.bpm.map { String(format: "%.1f BPM", $0) } ?? "— BPM")
                                    .foregroundStyle(deck.id == .a ? Palette.brass : Color.blue)
                                Spacer()
                                HStack(spacing: 5) {
                                    Text(formatTime(deck.position))
                                    Text("/").foregroundStyle(Palette.ink3)
                                    Text("−" + formatTime(max(0, deck.duration - deck.position)))
                                }
                                Spacer()
                            }
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Palette.ink2)
                            .padding(.horizontal, 9)
                            .padding(.bottom, 7)
                        }
                        // The transport readout is visual chrome, not a
                        // separate control. Let taps anywhere on it reach the
                        // waveform gesture below.
                        .allowsHitTesting(false)
                    }
                    .background(Color.white.opacity(0.035))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                    .gesture(touchGesture(width: waveformProxy.size.width))
                    .simultaneousGesture(pinchGesture)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .padding(4)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            if model.loadingDecks.contains(deck.id) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Analyzing…")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(.black.opacity(0.78), in: Capsule())
            }
        }
    }

    private func header(width: CGFloat) -> some View {
        let minimapWidth = max(112, width * 0.5)
        let minimapHeight = minimapWidth / 4
        return HStack(spacing: 8) {
            Button(action: onLoad) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(deck.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(deck.artist.isEmpty ? "Tap to load" : deck.artist)
                        .font(.system(size: 10)).foregroundStyle(Palette.ink3).lineLimit(1)
                    if deck.row != nil {
                        Text(deck.key ?? "—")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(Palette.ink3)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                MiniMap(bins: deck.waveform,
                        position: deck.position,
                        duration: deck.duration,
                        hotCues: deck.hotCues,
                        accent: deck.id == .a ? Palette.brass : Color.blue)
                    .frame(width: minimapWidth, height: minimapHeight)
                HStack(spacing: 3) {
                    ForEach(1...4, id: \.self) { number in
                        HotCueButton(number: number, lit: deck.hotCues[number] != nil,
                                     onTap: { model.activateCue(number, deck: deck.id) },
                                     onDelete: { model.deleteCue(number, deck: deck.id) })
                    }
                }
            }.frame(width: minimapWidth)
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .foregroundStyle(Palette.ink2)
        .padding(.horizontal, 7)
        .frame(minHeight: max(60, minimapHeight + 32))
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture().onChanged { value in
            let delta = value - pinchBucket
            guard abs(delta) >= 0.035 else { return }
            pinchBucket = value
            model.changeTempo(deck.id, zoom: value)
        }.onEnded { _ in pinchBucket = 1 }
    }

    private func touchGesture(width: CGFloat) -> some Gesture {
        let tapSlop: CGFloat = 12
        let scratchSlop: CGFloat = 8

        return DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !didDrag {
                    didDrag = true
                    dragStartDate = Date()
                    lastSampleDate = dragStartDate
                    lastX = value.translation.width
                    touchMode = .pending
                }
                let now = Date()
                let elapsed = now.timeIntervalSince(dragStartDate)
                let interval = max(0.001, now.timeIntervalSince(lastSampleDate))
                let delta = value.translation.width - lastX
                let speed = abs(delta) / interval
                let horizontal = abs(value.translation.width) > abs(value.translation.height)
                let horizontalDistance = abs(value.translation.width)
                lastX = value.translation.width
                lastSampleDate = now

                if deck.isPlaying {
                    if touchMode == .pending,
                       horizontal,
                       horizontalDistance >= tapSlop,
                       speed > 900,
                       elapsed < 0.28 {
                        touchMode = .nudge
                    } else if touchMode == .pending,
                              horizontal,
                              horizontalDistance >= scratchSlop,
                              elapsed >= 0.22 {
                        // A stationary press is still a play/pause tap. Only
                        // enter scratch after the held touch actually moves;
                        // otherwise normal, slightly slow taps get swallowed.
                        touchMode = .scratch
                        scratchActive = true
                        model.beginScratch(deck.id)
                    }
                    if touchMode == .scratch {
                        model.scratch(deck.id, by: delta, width: width)
                    }
                } else if touchMode == .pending, horizontal, abs(value.translation.width) > 0.5 {
                    if speed > 900, abs(value.translation.width) >= 12, elapsed < 0.25 {
                        touchMode = .nudge
                    } else {
                        touchMode = .move
                        model.movePaused(deck.id, by: delta, width: width)
                    }
                } else if touchMode == .move, horizontal {
                    model.movePaused(deck.id, by: delta, width: width)
                }
            }
            .onEnded { value in
                let elapsed = Date().timeIntervalSince(dragStartDate)
                let horizontal = abs(value.translation.width) > abs(value.translation.height)
                let distance = max(abs(value.translation.width), abs(value.translation.height))
                if scratchActive {
                    model.endScratch(deck.id)
                    scratchActive = false
                }
                if distance < tapSlop && touchMode == .pending {
                    if deck.row == nil { onLoad() } else { model.toggle(deck.id) }
                } else if horizontal && distance >= tapSlop {
                    if touchMode == .nudge {
                        model.nudge(deck.id, direction: value.translation.width > 0 ? 1 : -1)
                    } else if touchMode == .move {
                        model.flick(deck.id,
                                    translation: value.translation.width,
                                    predictedTranslation: value.predictedEndTranslation.width,
                                    width: width)
                    } else if deck.isPlaying && elapsed < 0.22 {
                        model.nudge(deck.id, direction: value.translation.width > 0 ? 1 : -1)
                    }
                }
                didDrag = false
                touchMode = .pending
            }
    }

    private func formatTime(_ value: Double) -> String {
        let seconds = max(0, Int(value.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct WaveformCanvas: View {
    let bins: [WaveformBin]
    let position: Double
    let duration: Double
    let hotCues: [Int: Double]
    let isPlaying: Bool
    let accent: Color

    private let displayWindowSeconds = 4.0

    var body: some View {
        Canvas { context, size in
            let count = max(1, bins.count)
            let mid = size.height * 0.48
            let secondsPerBin = duration > 0 ? duration / Double(count) : displayWindowSeconds
            let firstIndex = duration > 0
                ? max(0, Int(floor((position - displayWindowSeconds / 2) / secondsPerBin)) - 1)
                : 0
            let lastIndex = duration > 0
                ? min(count - 1, Int(ceil((position + displayWindowSeconds / 2) / secondsPerBin)) + 1)
                : count - 1
            let barWidth = max(1.2, CGFloat(secondsPerBin / displayWindowSeconds) * size.width * 0.78)
            for index in firstIndex...max(firstIndex, lastIndex) {
                let bin = bins.isEmpty ? WaveformBin(min: -0.15, max: 0.15, rms: 0.1) : bins[index]
                let time = (Double(index) + 0.5) * secondsPerBin
                let x = size.width / 2 + CGFloat((time - position) / displayWindowSeconds) * size.width
                guard x + barWidth >= 0, x - barWidth <= size.width else { continue }
                drawRGBBin(bin, at: x, mid: mid, height: size.height,
                           width: barWidth, context: &context,
                           fallback: isPlaying ? accent : accent.opacity(0.62))
            }

            // Hot cues move with the waveform content. The playhead stays
            // centered, while each cue is drawn at its exact time position.
            guard duration > 0 else { return }
            for cue in hotCues.values {
                let x = size.width / 2 + CGFloat((cue - position) / displayWindowSeconds) * size.width
                guard x >= -1, x <= size.width + 1 else { continue }
                var marker = Path()
                marker.move(to: CGPoint(x: x, y: 8))
                marker.addLine(to: CGPoint(x: x, y: max(8, size.height - 8)))
                context.stroke(marker, with: .color(Palette.brass.opacity(0.95)), lineWidth: 2)
            }
        }
    }

    private func drawRGBBin(_ bin: WaveformBin, at x: CGFloat, mid: CGFloat,
                            height: CGFloat, width: CGFloat,
                            context: inout GraphicsContext, fallback: Color) {
        let envelope = min(1, max(0.035, CGFloat(max(abs(bin.min), max(abs(bin.max), bin.rms * 1.8)))))
        let totalHeight = envelope * height * 0.84
        let energies = bin.bandRMS.count >= 3
            ? bin.bandRMS.prefix(3).map { max(0, CGFloat($0)) }
            : []
        guard energies.count == 3, energies.reduce(0, +) > 0 else {
            var path = Path()
            path.move(to: CGPoint(x: x, y: mid - totalHeight / 2))
            path.addLine(to: CGPoint(x: x, y: mid + totalHeight / 2))
            context.stroke(path, with: .color(fallback), lineWidth: width)
            return
        }

        let totalEnergy = energies.reduce(0, +)
        let colors: [Color] = [
            Color(red: 0.98, green: 0.16, blue: 0.12), // low / red
            Color(red: 0.18, green: 0.92, blue: 0.28), // mid / green
            Color(red: 0.20, green: 0.48, blue: 1.00)  // high / blue
        ]
        var y = mid - totalHeight / 2
        for index in 0..<3 {
            let segment = totalHeight * energies[index] / totalEnergy
            var path = Path()
            path.move(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x, y: y + max(1, segment)))
            context.stroke(path, with: .color(colors[index].opacity(isPlaying ? 1 : 0.62)),
                           lineWidth: width)
            y += segment
        }
    }
}

private struct MiniMap: View {
    let bins: [WaveformBin]
    let position: Double
    let duration: Double
    let hotCues: [Int: Double]
    let accent: Color

    var body: some View {
        Canvas { context, size in
            // The source overview has 2048 bins. A phone-width minimap cannot
            // display that many independent strokes; cap the redraw to 512
            // samples so playhead updates do not repeatedly rasterize a full
            // high-resolution waveform.
            let binStride = max(1, (bins.count + 511) / 512)
            let count = max(1, (bins.count + binStride - 1) / binStride)
            let step = size.width / CGFloat(count)
            let mid = size.height / 2
            for index in 0..<count {
                let sourceIndex = max(0, min(bins.count - 1, index * binStride))
                let bin = bins.isEmpty ? WaveformBin(min: -0.12, max: 0.12, rms: 0.1) : bins[sourceIndex]
                let x = CGFloat(index) * step + step / 2
                drawRGBBin(bin, at: x, mid: mid, height: size.height,
                           width: max(1, step), context: &context, fallback: accent.opacity(0.7))
            }
            let progress = duration > 0 ? max(0, min(1, position / duration)) : 0
            var head = Path()
            let x = progress * size.width
            head.move(to: CGPoint(x: x, y: 5))
            head.addLine(to: CGPoint(x: x, y: max(5, size.height - 5)))
            context.stroke(head, with: .color(Palette.ink), lineWidth: 1)

            guard duration > 0 else { return }
            for cue in hotCues.values {
                let cueX = max(0, min(1, cue / duration)) * size.width
                var marker = Path()
                marker.move(to: CGPoint(x: cueX, y: 5))
                marker.addLine(to: CGPoint(x: cueX, y: max(5, size.height - 5)))
                context.stroke(marker, with: .color(Palette.brass.opacity(0.95)), lineWidth: 2)
            }
        }
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.12)))
    }

    private func drawRGBBin(_ bin: WaveformBin, at x: CGFloat, mid: CGFloat,
                            height: CGFloat, width: CGFloat,
                            context: inout GraphicsContext, fallback: Color) {
        let envelope = min(1, max(0.035, CGFloat(max(abs(bin.min), max(abs(bin.max), bin.rms * 1.8)))))
        let totalHeight = envelope * height * 0.84
        let energies = bin.bandRMS.count >= 3
            ? bin.bandRMS.prefix(3).map { max(0, CGFloat($0)) }
            : []
        guard energies.count == 3, energies.reduce(0, +) > 0 else {
            var path = Path()
            path.move(to: CGPoint(x: x, y: mid - totalHeight / 2))
            path.addLine(to: CGPoint(x: x, y: mid + totalHeight / 2))
            context.stroke(path, with: .color(fallback), lineWidth: width)
            return
        }
        let totalEnergy = energies.reduce(0, +)
        let colors: [Color] = [
            Color(red: 0.98, green: 0.16, blue: 0.12),
            Color(red: 0.18, green: 0.92, blue: 0.28),
            Color(red: 0.20, green: 0.48, blue: 1.00)
        ]
        var y = mid - totalHeight / 2
        for index in 0..<3 {
            let segment = totalHeight * energies[index] / totalEnergy
            var path = Path()
            path.move(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x, y: y + max(1, segment)))
            context.stroke(path, with: .color(colors[index].opacity(0.82)), lineWidth: width)
            y += segment
        }
    }
}

private struct HotCueButton: View {
    let number: Int
    let lit: Bool
    let onTap: () -> Void
    let onDelete: () -> Void
    @State private var didLongPress = false

    var body: some View {
        Button {
            if !didLongPress { onTap() }
            didLongPress = false
        } label: {
            Text(String(number))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(lit ? Palette.bg : Palette.ink3)
                .frame(width: 28, height: 28)
                .background(lit ? Palette.brass : Color.white.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in
            didLongPress = true
            if lit { onDelete() }
        })
        .accessibilityLabel(lit ? "Hot cue \(number), set" : "Hot cue \(number), empty")
    }
}

private struct DJFooter: View {
    let bass: Double
    let crossfade: Double
    let onBass: (Double) -> Void
    let onCrossfade: (Double) -> Void

    var body: some View {
        HStack(spacing: 10) {
            fader(title: "Bassfader", value: bass, left: "A BASS", right: "B BASS", action: onBass)
            fader(title: "Crossfader", value: crossfade, left: "A", right: "B", action: onCrossfade)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.24))
    }

    private func fader(title: String, value: Double, left: String, right: String,
                       action: @escaping (Double) -> Void) -> some View {
        VStack(spacing: 1) {
            HStack {
                Text(left)
                Spacer()
                Text(title).foregroundStyle(Palette.ink)
                Spacer()
                Text(right)
            }
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(Palette.ink3)
            Slider(value: Binding(get: { value }, set: action), in: 0...1)
                .tint(Palette.brass)
        }
    }
}

private struct DJLoadSheet: View {
    let deck: DJDeckID
    let tracks: [TrackRow]
    let playlists: [Playlist]
    let store: LibraryStore
    let onLoad: (TrackRow) -> Void
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var scope: DJLoadLibraryScope = .songs
    @State private var inputMode: DiscoverySearchInputMode = .metadata
    @State private var query = ""
    @State private var bpmMinText = ""
    @State private var bpmMaxText = ""
    @State private var compatibleKey = ""
    @State private var searchModel: DiscoverySearchViewModel?
    @State private var infoByTrackID: [Int64: DJLoadTrackInfo] = [:]
    @State private var selectedPlaylist: Playlist?
    @State private var playlistTracks: [TrackRow] = []
    @State private var selectedLibraryEntry: LibraryBrowse.Entry?
    @State private var isLoadingPlaylist = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Search mode", selection: $inputMode) {
                    Text("Metadata").tag(DiscoverySearchInputMode.metadata)
                    Text("Mood / sound").tag(DiscoverySearchInputMode.findBySound)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)
                .accessibilityIdentifier("dj.load.searchMode")

                HStack(spacing: 8) {
                    Image(systemName: inputMode == .findBySound ? "wand.and.stars" : "magnifyingglass")
                        .foregroundStyle(Palette.ink3)
                    TextField(
                        inputMode == .findBySound
                            ? "Search by mood or sound, e.g. warm analog pads"
                            : "Search titles, artists, albums, or genres",
                        text: $query)
                        .platformAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel(inputMode == .findBySound ? "Search by mood or sound" : "Search your music")
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 42)
                .glassSurface(cornerRadius: 14)
                .padding(.horizontal)
                .padding(.top, 8)

                HStack(spacing: 8) {
                    loadFilterField("Min BPM", text: $bpmMinText, numberPad: true)
                    loadFilterField("Max BPM", text: $bpmMaxText, numberPad: true)
                    loadFilterField("Key (8A)", text: $compatibleKey, numberPad: false)
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .accessibilityIdentifier("dj.load.musicalFilters")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(DJLoadLibraryScope.allCases) { value in
                            Button {
                                scope = value
                                selectedPlaylist = nil
                                selectedLibraryEntry = nil
                                searchModel?.scope = .allMusic
                            } label: {
                                Text(value.rawValue)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(scope == value ? .white : Palette.ink2)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(scope == value ? Palette.brassDeep : Color.white.opacity(0.07), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.top, 8)
                .padding(.bottom, 6)

                if scope == .playlists, let selectedPlaylist {
                    playlistTrackList(selectedPlaylist)
                } else if scope == .playlists {
                    playlistList
                } else if let selectedLibraryEntry {
                    libraryEntryList(selectedLibraryEntry)
                } else if let mode = scope.browseMode {
                    libraryList(mode)
                }
            }
            .background(Palette.bg)
            .navigationTitle("Load Deck " + deck.rawValue)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onChange(of: inputMode) { _, value in
                searchModel?.inputMode = value
            }
            .onChange(of: query) { _, value in
                searchModel?.searchText = value
            }
            .onChange(of: bpmMinText) { _, value in
                searchModel?.bpmMinText = value
            }
            .onChange(of: bpmMaxText) { _, value in
                searchModel?.bpmMaxText = value
            }
            .onChange(of: compatibleKey) { _, value in
                searchModel?.compatibleKey = value
            }
            .task {
                guard searchModel == nil else { return }
                let model = await DiscoveryRuntimeController.shared.makeSearchViewModel(
                    appState: appState, player: player)
                searchModel = model
                model.inputMode = inputMode
                model.searchText = query
                model.bpmMinText = bpmMinText
                model.bpmMaxText = bpmMaxText
                model.compatibleKey = compatibleKey
            }
        }
    }

    private func loadFilterField(_ label: String, text: Binding<String>, numberPad: Bool) -> some View {
        TextField(label, text: text)
            #if !os(macOS)
            .keyboardType(numberPad ? .numberPad : .asciiCapable)
            #endif
            .font(.caption)
            .padding(.horizontal, 8)
            .frame(minHeight: 36)
            .glassSurface(cornerRadius: 11)
            .accessibilityLabel(label)
    }

    private var libraryRows: [TrackRow] {
        filtered(activeSearchRows ?? tracks)
    }

    private var activeSearchRows: [TrackRow]? {
        guard let searchModel, searchModel.screen.hasResults else { return nil }
        return searchModel.results.map(\.track)
    }

    private var localFilter: DJLoadTrackFilter {
        DJLoadTrackFilter(
            bpmMin: Double(bpmMinText.trimmingCharacters(in: .whitespacesAndNewlines)),
            bpmMax: Double(bpmMaxText.trimmingCharacters(in: .whitespacesAndNewlines)),
            camelotKey: compatibleKey)
    }

    private func libraryList(_ mode: LibraryBrowseMode) -> some View {
        let sections = LibraryBrowse.sections(for: mode, rows: libraryRows)
        return List {
            ForEach(sections) { section in
                Section(section.indexTitle) {
                    ForEach(section.entries) { entry in
                        Button {
                            if entry.kind == .song, let row = entry.rows.first {
                                onLoad(row)
                            } else {
                                selectedLibraryEntry = entry
                                query = ""
                            }
                        } label: {
                            HStack(spacing: 11) {
                                Image(systemName: entry.kind == .song ? "music.note" : "rectangle.stack")
                                    .foregroundStyle(Palette.brass)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.title).foregroundStyle(Palette.ink)
                                    if let subtitle = entry.subtitle {
                                        Text(subtitle).font(.caption).foregroundStyle(Palette.ink3)
                                    }
                                }
                                Spacer()
                                if entry.kind != .song {
                                    Image(systemName: "chevron.right").foregroundStyle(Palette.ink3)
                                }
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if sections.isEmpty {
                loadSearchState
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func libraryEntryList(_ entry: LibraryBrowse.Entry) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    selectedLibraryEntry = nil
                    query = ""
                } label: {
                    Label("All \(scope.rawValue)", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.brass)
                Spacer()
                Text(entry.title).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink).lineLimit(1)
            }
            .padding(.horizontal)
            .padding(.vertical, 9)
            trackList(filtered(activeSearchRows ?? entry.rows))
        }
    }

    private var playlistList: some View {
        List(filteredPlaylists) { playlist in
            Button {
                selectedPlaylist = playlist
                query = ""
                playlistTracks = []
                isLoadingPlaylist = true
                Task {
                    guard let id = playlist.id else {
                        isLoadingPlaylist = false
                        return
                    }
                    playlistTracks = (try? await store.playlistItems(playlistId: id)) ?? []
                    isLoadingPlaylist = false
                }
            } label: {
                HStack {
                    Image(systemName: "music.note.list")
                        .foregroundStyle(Palette.brass)
                    Text(playlist.title).foregroundStyle(Palette.ink)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(Palette.ink3)
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func playlistTrackList(_ playlist: Playlist) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    selectedPlaylist = nil
                    playlistTracks = []
                    query = ""
                } label: {
                    Label("All playlists", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.brass)
                Spacer()
                Text(playlist.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
            }
            .padding(.horizontal)
            .padding(.vertical, 9)

            if isLoadingPlaylist {
                ProgressView("Loading playlist…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                trackList(filtered(activeSearchRows ?? playlistTracks))
            }
        }
    }

    @ViewBuilder
    private var loadSearchState: some View {
        if inputMode == .findBySound, let searchModel {
            switch searchModel.screen {
            case .loading:
                ProgressView("Finding tracks by sound…")
            case .modelMissing:
                ContentUnavailableView("Sound search model needed", systemImage: "arrow.down.circle",
                                       description: Text("Download the sound-search model from Settings to search by mood."))
            case .matchingReferenceUnavailable:
                ContentUnavailableView("Musical match unavailable", systemImage: "music.note.list",
                                       description: Text("The selected track needs BPM and key analysis before matching."))
            default:
                ContentUnavailableView(query.isEmpty ? "No music" : "No matching music",
                                       systemImage: query.isEmpty ? "music.note" : "magnifyingglass",
                                       description: Text(query.isEmpty ? "Add music in My Music first." : "Try a broader mood or sound description."))
            }
        } else {
            ContentUnavailableView(query.isEmpty ? "No music" : "No matching music",
                                   systemImage: query.isEmpty ? "music.note" : "magnifyingglass",
                                   description: Text(query.isEmpty ? "Add music in My Music first." : "Search titles, artists, albums, or genres."))
        }
    }

    private func trackList(_ rows: [TrackRow]) -> some View {
        List(rows) { row in
            Button { onLoad(row) } label: {
                DJLoadTrackRow(row: row, info: infoByTrackID[row.id], subtitle: trackSubtitle(row))
            }
            .accessibilityIdentifier("dj.load.track.\(row.id)")
        }
        .overlay {
            if rows.isEmpty {
                loadSearchState
            }
        }
        .task(id: rows.map(\.id)) { await loadInfo(for: rows) }
        .scrollContentBackground(.hidden)
    }

    private var filteredPlaylists: [Playlist] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return playlists }
        return playlists.filter { $0.title.localizedCaseInsensitiveContains(needle) }
    }

    private func filtered(_ rows: [TrackRow]) -> [TrackRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let textFiltered: [TrackRow]
        if needle.isEmpty || inputMode == .findBySound && activeSearchRows != nil {
            textFiltered = rows
        } else {
            textFiltered = rows.filter { row in
                [row.track.title, row.artist?.name, row.album?.title, row.track.genre]
                    .compactMap { $0 }
                    .contains { $0.localizedCaseInsensitiveContains(needle) }
            }
        }
        guard !localFilter.isEmpty else { return textFiltered }
        return textFiltered.filter { localFilter.matches(infoByTrackID[$0.id] ?? DJLoadTrackInfo()) }
    }

    private func loadInfo(for rows: [TrackRow]) async {
        let ids = rows.map(\.id)
        guard !ids.isEmpty, let values = try? await store.djLoadTrackInfo(trackIds: ids) else { return }
        infoByTrackID.merge(values) { _, new in new }
    }

    private func trackSubtitle(_ row: TrackRow) -> String {
        let artist = row.artist?.name ?? "Unknown artist"
        guard let album = row.album?.title, !album.isEmpty else { return artist }
        return "\(artist) · \(album)"
    }
}

private struct DJLoadTrackRow: View {
    let row: TrackRow
    let info: DJLoadTrackInfo?
    let subtitle: String

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.track.title)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Palette.ink3)
                    .lineLimit(1)
                HStack(spacing: 10) {
                    Text(info?.bpmLabel ?? "— BPM")
                    Text(info?.keyLabel ?? "KEY —")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Palette.brass)
            }
            Spacer(minLength: 4)
            Image(systemName: "arrow.down.to.line.compact")
                .foregroundStyle(Palette.brass)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.track.title), \(subtitle), \(info?.bpmLabel ?? "BPM unknown"), \(info?.keyLabel ?? "key unknown")")
    }
}

private struct DJHelpSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var expanded: Set<String> = []
    @FocusState private var searchFocused
    let onShowMe: (DJHelpTopic) -> Void

    init(onShowMe: @escaping (DJHelpTopic) -> Void) {
        self.onShowMe = onShowMe
        _expanded = State(initialValue: Set(UserDefaults.standard.stringArray(forKey: "dj.help.expanded") ?? []))
    }

    private var topics: [DJHelpTopic] {
        DJHelpSearch.filter(DJHelpContent.sections, query: query)
    }

    private var coveredControls: Set<DJControlID> {
        Set(DJHelpContent.sections.flatMap(\.controls))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("Control coverage").font(.headline)
                        Spacer()
                        Text("\(topics.count)/\(DJHelpContent.sections.count) sections")
                            .font(.caption).foregroundStyle(Palette.ink3)
                    }
                    ForEach(DJControlID.allCases, id: \.self) { control in
                        HStack {
                            Image(systemName: coveredControls.contains(control) ? "checkmark.circle.fill" : "exclamationmark.circle")
                                .foregroundStyle(coveredControls.contains(control) ? .green : .orange)
                            Text(control.rawValue)
                            Spacer()
                            Text(coveredControls.contains(control) ? "covered" : "missing")
                                .font(.caption).foregroundStyle(Palette.ink3)
                        }
                    }
                    HStack {
                        Button("Open all") { expanded = Set(DJHelpContent.sections.map(\.title)) }
                        Spacer()
                        Button("Close all") { expanded.removeAll() }
                    }
                    .font(.caption.weight(.semibold))
                }
                ForEach(topics, id: \.title) { topic in
                    let isExpanded = expanded.contains(topic.title)
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            if isExpanded { expanded.remove(topic.title) }
                            else { expanded.insert(topic.title) }
                        } label: {
                            HStack {
                                Text(topic.title).font(.headline).foregroundStyle(Palette.ink)
                                Spacer()
                                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                    .foregroundStyle(Palette.ink3)
                            }
                        }
                        .buttonStyle(.plain)
                        if isExpanded {
                            highlighted(topic.body).font(.subheadline).foregroundStyle(Palette.ink2)
                            Button("Show me") { onShowMe(topic) }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Palette.brass)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.bg)
            .navigationTitle("DJ Help")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .searchable(text: $query, prompt: "Search DJ controls and gestures")
            .searchFocused($searchFocused)
            .onAppear { searchFocused = true }
            .onChange(of: query) { _, value in
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    expanded.formUnion(topics.map(\.title))
                }
                UserDefaults.standard.set(Array(expanded), forKey: "dj.help.expanded")
            }
            .onChange(of: expanded) { _, value in
                UserDefaults.standard.set(Array(value), forKey: "dj.help.expanded")
            }
        }
    }

    private func highlighted(_ body: String) -> Text {
        let term = query.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        guard !term.isEmpty, let range = body.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return Text(body)
        }
        return Text(body[..<range.lowerBound])
            + Text(body[range]).bold()
            + Text(body[range.upperBound...])
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let power = pow(10, Double(places))
        return (self * power).rounded() / power
    }
}
