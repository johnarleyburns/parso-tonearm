import AVFoundation
import ParsoAudioCore
import ParsoAudioAnalysis
import ParsoDJEngine
import SwiftUI
import TonearmCore

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
    @Published var tempo: Double = 120
    @Published var bass = 0.5
    @Published var hotCues: [Int: Double] = [:]
    @Published var cuePoint: Double?
    @Published var loopIn: Double?
    @Published var loopOut: Double?
    @Published var loopActive = false
    @Published var loopExitPending = false
    @Published var padMode: DJPadMode = .hotCue
    @Published var echoPad: Double?

    init(id: DJDeckID) { self.id = id }

    var title: String { row?.track.title ?? "LOAD TRACK " + id.rawValue }
    var artist: String { row?.artist?.name ?? "" }
    var album: String { row?.album?.title ?? "" }
    var tempoRatio: Double {
        guard let bpm, bpm > 0 else { return 1 }
        return max(0.5, min(2, tempo / bpm))
    }
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
    @Published var masterLevel = UserDefaults.standard.object(forKey: "dj.masterLevel") as? Double ?? 0.8
    @Published var loadError: String?
    @Published private(set) var loadingDecks: Set<DJDeckID> = []

    private let store: LibraryStore
    private var loadGeneration: [DJDeckID: Int] = [.a: 0, .b: 0]
    private var tickTask: Task<Void, Never>?
    private var glideTasks: [DJDeckID: Task<Void, Never>] = [:]
    private var audio = DJAudioBacker()
    private let cues = DJHotCueStore()
    private var scratching: Set<DJDeckID> = []

    init(store: LibraryStore = .shared) {
        self.store = store
        audio.setBassBlend(0.5)
        audio.setCrossfader(0.5)
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                let active = await MainActor.run { [weak self] in
                    self?.deckA.isPlaying == true || self?.deckB.isPlaying == true || self?.scratching.isEmpty == false
                }
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
        deck.isPlaying = false
        deck.position = 0
        deck.row = row
        deck.duration = row.track.durationSec ?? 0
        deck.bpm = nil
        deck.key = nil
        deck.waveform = []
        deck.hotCues = cues.load(trackID: row.id)
        deck.cuePoint = nil
        deck.loopIn = nil
        deck.loopOut = nil
        deck.loopActive = false
        deck.loopExitPending = false
        deck.padMode = .hotCue
        deck.echoPad = nil
        deck.tempo = 120
        loadError = nil

        Task { [weak self, store] in
            do {
                let prep = try await store.djTrackPrep(trackId: row.id)
                if let prep {
                    deck.hotCues = prep.markings.hotCues
                    deck.cuePoint = prep.cuePointSeconds
                    deck.loopIn = prep.loopInSeconds
                    deck.loopOut = prep.loopOutSeconds
                }
                // Resolution may download a remote asset into the local cache.
                // It is part of loading, so a track that was not pre-indexed or
                // pre-downloaded remains a valid DJ selection.
                let url = try await resolve(row)
                let prepared = try await Task.detached(priority: .userInitiated) {
                    if let bookmark = row.asset?.bookmark {
                        guard let prepared = try BookmarkVault.withAccess(bookmark, {
                            try DJAudioBacker.prepare(url: $0, codec: row.track.codec)
                        }) else { throw DJAudioError.unavailable }
                        return prepared
                    }
                    return try DJAudioBacker.prepare(url: url, codec: row.track.codec)
                }.value
                guard let self,
                      self.loadGeneration[id] == generation,
                      self.deck(id).row?.id == row.id else { return }
                try self.audio.load(prepared, deck: id)
                self.audio.restoreHotCues(deck.hotCues, deck: id)
                if let cue = deck.cuePoint { self.audio.setCue(deck: id, position: cue) }
                if let start = deck.loopIn, let end = deck.loopOut { self.audio.setLoop(deck: id, start: start, end: end, active: false) }
                self.loadingDecks.remove(id)
                deck.duration = prepared.analysis.duration
                deck.waveform = self.audio.waveform(for: id)
                let indexed = try? await store.discoveryTrackAnalysis(trackId: row.id)
                deck.bpm = indexed?.bpm ?? prepared.analysis.tempo.bpm
                deck.key = indexed?.key ?? prepared.analysis.key.camelot
                if let bpm = deck.bpm { deck.tempo = bpm }
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
        if deck.isPlaying { audio.play(deck: id, position: deck.position, rate: deck.tempoRatio) }
        else { stop(deck: id) }
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

    func movePaused(_ id: DJDeckID, by pixels: CGFloat, width: CGFloat) {
        let deck = deck(id)
        guard !deck.isPlaying, deck.duration > 0, width > 0 else { return }
        cancelGlide(id)
        seek(id, by: -Double(pixels / width) * deck.duration)
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

    func activateCue(_ number: Int, deck id: DJDeckID) {
        let deck = deck(id)
        guard deck.row != nil else { return }
        cancelGlide(id)
        if let position = deck.hotCues[number] {
            seek(id, to: position)
            audio.jumpHotCue(number, deck: id)
        } else {
            deck.hotCues[number] = deck.position
            audio.setHotCue(number, deck: id, position: deck.position)
            saveMarkings(deck)
        }
    }

    func deleteCue(_ number: Int, deck id: DJDeckID) {
        let deck = deck(id)
        deck.hotCues[number] = nil
        audio.deleteHotCue(number, deck: id)
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
            deck.cuePoint = deck.position; audio.setCue(deck: id, position: deck.position); audio.cuePlayPress(deck: id); saveMarkings(deck)
        }
    }

    func cueUp(_ id: DJDeckID) { audio.cuePlayRelease(deck: id); deck(id).position = audio.position(for: id) }

    func minimapSeek(_ id: DJDeckID, x: CGFloat, width: CGFloat) {
        let deck = deck(id)
        guard !deck.isPlaying, width > 0, deck.duration > 0 else { return }
        seek(id, to: deck.duration * Double(max(0, min(width, x)) / width))
    }

    func toggleEcho(_ id: DJDeckID) {
        let deck = deck(id)
        if deck.padMode == .echo { deck.padMode = .hotCue; audio.disarmEchoOut(deck: id) }
        else {
            if deck.padMode == .loop, deck.loopActive {
                audio.reloopExit(deck: id)
                deck.loopActive = false
            }
            deck.padMode = .echo
            audio.armEchoOut(deck: id)
        }
    }

    func toggleLoop(_ id: DJDeckID) {
        let deck = deck(id)
        if deck.padMode == .loop {
            deck.padMode = .hotCue
            if deck.loopActive { audio.reloopExit(deck: id); deck.loopActive = false }
        } else {
            if deck.padMode == .echo { audio.disarmEchoOut(deck: id) }
            deck.padMode = .loop
        }
    }

    func echoPad(_ value: Double, deck id: DJDeckID, pressed: Bool) {
        let deck = deck(id); guard deck.padMode == .echo else { return }
        deck.echoPad = pressed ? value : nil
        if pressed { audio.setEcho(deck: id, enabled: true, beats: value) }
        else { audio.setEcho(deck: id, enabled: false, beats: value) }
    }

    func loopPad(_ pad: Int, deck id: DJDeckID) {
        let deck = deck(id); guard deck.padMode == .loop else { return }
        switch pad {
        case 0:
            deck.loopIn = deck.position; deck.loopOut = nil; deck.loopActive = false; audio.loopIn(deck: id); saveMarkings(deck)
        case 1:
            guard let start = deck.loopIn, deck.position > start else { return }
            deck.loopOut = deck.position; deck.loopActive = false; audio.setLoop(deck: id, start: start, end: deck.position, active: false); saveMarkings(deck)
        case 2:
            guard let start = deck.loopIn, let bpm = deck.bpm, bpm > 0 else { return }
            let lengths = [1.0, 2, 4, 8, 16, 32]
            let current = deck.loopOut.map { max(0, Int((($0 - start) * bpm / 60).rounded())) } ?? 4
            let next = lengths.first(where: { Int($0) > current }) ?? 1
            let end = min(deck.duration, start + next * 60 / bpm)
            deck.loopOut = end; audio.setLoop(deck: id, start: start, end: end, active: false); saveMarkings(deck)
        default:
            guard deck.loopIn != nil, deck.loopOut != nil else { return }
            if deck.loopActive { audio.exitLoopAtEnd(deck: id); deck.loopActive = false; deck.loopExitPending = true }
            else { audio.setLoopActive(deck: id, active: true); deck.loopActive = true; deck.loopExitPending = false }
        }
    }

    private func stop(deck id: DJDeckID) {
        let state = deck(id)
        state.isPlaying = false
        audio.stop(deck: id, echoOut: state.padMode == .echo)
    }

    private func saveMarkings(_ deck: DJDeckState) {
        guard let id = deck.row?.id, id >= 0 else { return }
        let markings = DJMarkings(hotCues: deck.hotCues, cuePointSeconds: deck.cuePoint,
                                  loopInSeconds: deck.loopIn, loopOutSeconds: deck.loopOut)
        Task { try? await store.saveDJMarkings(markings, trackId: id) }
    }

    func setBass(_ value: Double) {
        bassFader = value
        audio.setBassBlend(value)
    }

    func setCrossfader(_ value: Double) {
        crossfader = value
        audio.setCrossfader(value)
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

    private func tick() {
        audio.pollEvents()
        for id in DJDeckID.allCases {
            let deck = deck(id)
            deck.position = min(deck.duration, audio.position(for: id))
            if !scratching.contains(id) {
                deck.isPlaying = audio.isPlaying(for: id)
            }
            deck.loopActive = audio.isLoopActive(for: id)
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

    struct PreparedDJTrack: Sendable {
        let buffer: PCMBuffer
        let analysis: TrackAnalysis
    }

    nonisolated static func prepare(url: URL, codec: String?) throws -> PreparedDJTrack {
        let buffer = try AudioFileReader(url: url, container: container(codec: codec, url: url)).readAll()
        let analysis = TrackAnalyzer().analyze(buffer)
        return PreparedDJTrack(buffer: buffer, analysis: analysis)
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

    func load(_ track: PreparedDJTrack, deck: DJDeckID) throws {
        if !engine.isRunning { try start() }
        let index = deck == .a ? 0 : 1
        engine.decks[index].load(track.analysis, buffer: track.buffer)
        engine.decks[index].tempoRange = .wide
        prepared[deck] = track
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

    func restoreHotCues(_ cues: [Int: Double], deck: DJDeckID) {
        guard let track = prepared[deck] else { return }
        let player = engine.decks[index(for: deck)]
        for slot in 0..<4 { player.deleteHotCue(slot) }
        for (slot, position) in cues where (1...4).contains(slot) {
            let frame = Int64(max(0, min(Double(track.buffer.frameCount),
                                         position * track.buffer.format.sampleRate)).rounded())
            player.triggerHotCue(slot - 1, atSample: frame)
        }
    }

    func setHotCue(_ slot: Int, deck: DJDeckID, position: Double) {
        guard let track = prepared[deck], (1...4).contains(slot) else { return }
        let frame = Int64(max(0, min(Double(track.buffer.frameCount),
                                     position * track.buffer.format.sampleRate)).rounded())
        engine.decks[index(for: deck)].triggerHotCue(slot - 1, atSample: frame)
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
        guard (1...4).contains(slot) else { return }
        engine.decks[index(for: deck)].jumpHotCue(slot - 1)
    }

    func deleteHotCue(_ slot: Int, deck: DJDeckID) {
        guard (1...4).contains(slot) else { return }
        engine.decks[index(for: deck)].deleteHotCue(slot - 1)
    }

    func beginScratch(deck: DJDeckID) {
        engine.decks[index(for: deck)].jogTouchBegan()
    }

    func scratch(deck: DJDeckID, seconds: Double) {
        engine.decks[index(for: deck)].fastSearch(seconds: seconds)
    }

    func endScratch(deck: DJDeckID) {
        engine.decks[index(for: deck)].jogTouchEnded()
    }

    func setBassBlend(_ value: Double) {
        let position = max(0, min(1, value))
        let a = engine.mixer.channelA
        let b = engine.mixer.channelB
        a.eqLow = position > 0.5 ? -24 * ((position - 0.5) * 2) : 0
        b.eqLow = position < 0.5 ? -24 * ((0.5 - position) * 2) : 0
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
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
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

    private func restoreHotCues(_ deck: DJDeckID) {
        // Hot-cue positions are restored by DJPerformanceModel's persisted
        // state; PAE receives the exact sample address when the user jumps.
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
            DJTitleBar(onBack: {
                appState.isPerformanceSurfaceFullScreen = false
                appState.tab = .listen
            }, onInfo: { showHelp = true })
            DJEightRowSurface(model: model,
                              onLoad: { loadTarget = $0 })
        }
        // Keep the top safe area owned by SwiftUI so the iPhone's Dynamic
        // Island/notch cannot cover the back button. The DJ surface still
        // owns the bottom edge and horizontal space for the mixer.
        .ignoresSafeArea(edges: [.bottom, .horizontal])
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
        .sheet(isPresented: $showHelp) { DJHelpSheet() }
        .alert("DJ Audio", isPresented: Binding(get: { model.loadError != nil },
                                                 set: { if !$0 { model.loadError = nil } })) {
            Button("OK", role: .cancel) { model.loadError = nil }
        } message: { Text(model.loadError ?? "") }
    }

    private var modelTracks: [TrackRow] { appState.allTracks }

    private var waveformArea: some View {
        GeometryReader { proxy in
            VStack(spacing: 4) {
                DJWaveform(deck: model.deckA, model: model,
                           onLoad: { loadTarget = .a })
                DJWaveform(deck: model.deckB, model: model,
                           onLoad: { loadTarget = .b })
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(width: proxy.size.width, height: proxy.size.height)
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

                deckTrack(model.deckA, onLoad: onLoad)
                    .frame(width: layout.frame(col: 0, row: 1, span: 4).width,
                           height: layout.frame(col: 0, row: 1, span: 4).height)
                    .position(x: layout.frame(col: 0, row: 1, span: 4).midX,
                              y: layout.frame(col: 0, row: 1, span: 4).midY)
                deckTrack(model.deckB, onLoad: onLoad)
                    .frame(width: layout.frame(col: 0, row: 6, span: 4).width,
                           height: layout.frame(col: 0, row: 6, span: 4).height)
                    .position(x: layout.frame(col: 0, row: 6, span: 4).midX,
                              y: layout.frame(col: 0, row: 6, span: 4).midY)

                deckTransport(model.deckA, row: 1)
                deckTransport(model.deckB, row: 6)
                deckMinimap(model.deckA, row: 2)
                deckMinimap(model.deckB, row: 5)
                deckPads(model.deckA, row: 2)
                deckPads(model.deckB, row: 5)
                deckWaveform(model.deckA, row: 3)
                deckWaveform(model.deckB, row: 4)

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

    private func deckTrack(_ deck: DJDeckState, onLoad: @escaping (DJDeckID) -> Void) -> some View {
        Button { onLoad(deck.id) } label: {
            HStack(spacing: 8) {
                Text(deck.id.rawValue)
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundStyle(deck.id == .a ? Palette.brass : Color.blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text(deck.title).font(.system(size: 13, weight: .bold)).lineLimit(1)
                    Text(deck.artist.isEmpty ? "Tap to load" : deck.artist)
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.ink2).lineLimit(1)
                    Text(deck.album.isEmpty ? "" : deck.album)
                        .font(.system(size: 9)).foregroundStyle(Palette.ink3).lineLimit(1)
                }
                Spacer(minLength: 2)
            }
            .padding(.horizontal, 8)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Load deck \(deck.id.rawValue)")
    }

    private func deckTransport(_ deck: DJDeckState, row: Int) -> some View {
        return HStack(spacing: 5) {
            DJTransportButton(title: "CUE", active: deck.cuePoint != nil,
                              gesture: cueGesture(deck.id))
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(2)
        .gridPlacement(row: row, col: 4, span: 4)
    }

    private func cueGesture(_ id: DJDeckID) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in model.cueDown(id) }
            .onEnded { _ in model.cueUp(id) }
    }

    private func deckMinimap(_ deck: DJDeckState, row: Int) -> some View {
        MiniMap(bins: deck.waveform, position: deck.position, duration: deck.duration,
                hotCues: deck.hotCues, accent: deck.id == .a ? Palette.brass : Color.blue)
            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                model.minimapSeek(deck.id, x: value.location.x, width: max(1, value.translation.width + value.location.x))
            })
            .gridPlacement(row: row, col: 0, span: 4)
    }

    private func deckWaveform(_ deck: DJDeckState, row: Int) -> some View {
        ZStack {
            WaveformCanvas(bins: deck.waveform, position: deck.position, duration: deck.duration,
                           hotCues: deck.hotCues, isPlaying: deck.isPlaying,
                           accent: deck.id == .a ? Palette.brass : Color.blue)
            Rectangle().fill(deck.id == .a ? Palette.brass : Color.blue).frame(width: 1.5)
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
        }
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
        .gridPlacement(row: row, col: 0, span: 8)
    }

    private func deckPads(_ deck: DJDeckState, row: Int) -> some View {
        DJPerformancePads(deck: deck, model: model)
            .gridPlacement(row: row, col: 4, span: 4)
    }

    private func cycleOutput() {
        let modes = DJOutputMode.allCases
        let next = (modes.firstIndex(of: model.outputMode).map { ($0 + 1) % modes.count }) ?? 0
        model.setOutputMode(modes[next])
    }

    private func formatTime(_ value: Double) -> String {
        let seconds = max(0, Int(value.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private extension View {
    func gridPlacement(row: Int, col: Int, span: Int = 1) -> some View {
        GeometryReader { proxy in
            let layout = DJGridLayout(size: proxy.size, gap: 5)
            self.frame(width: layout.frame(col: col, row: row, span: span).width,
                      height: layout.frame(col: col, row: row, span: span).height)
                .position(x: layout.frame(col: col, row: row, span: span).midX,
                          y: layout.frame(col: col, row: row, span: span).midY)
        }
        .allowsHitTesting(true)
    }
}

private struct DJSmallInfoButton: View {
    var body: some View {
        Text("(i)").font(.system(size: 14, weight: .bold, design: .monospaced))
            .foregroundStyle(Palette.ink2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    Button("\(n)") { model.activateCue(n, deck: deck.id) }
                        .buttonStyle(.plain).background(deck.hotCues[n] == nil ? Color.white.opacity(0.05) : Palette.brass,
                                                         in: RoundedRectangle(cornerRadius: 5))
                }
            } else if deck.padMode == .echo {
                ForEach([0.25, 0.5, 1.0, 2.0], id: \.self) { beats in
                    Text(echoLabel(beats))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(deck.echoPad == beats ? Palette.brass : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
                        .gesture(DragGesture(minimumDistance: 0).onChanged { _ in model.echoPad(beats, deck: deck.id, pressed: true) }
                            .onEnded { _ in model.echoPad(beats, deck: deck.id, pressed: false) })
                }
            } else {
                ForEach(["IN", "OUT", "SET", deck.loopActive ? "EXIT" : "ENTER"], id: \.self) { label in
                    Button(label) { model.loopPad(["IN", "OUT", "SET", "ENTER"].firstIndex(of: label) ?? 3, deck: deck.id) }
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
            Text("CUE (deck)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(isOn ? Palette.bg : Palette.ink2)
                .frame(width: 48, height: 30)
                .background(isOn ? Palette.brass : Color.white.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isOn ? Palette.brass : Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cue deck (deck)")
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
            let count = max(1, bins.count)
            let step = size.width / CGFloat(count)
            let mid = size.height / 2
            for index in 0..<count {
                let bin = bins.isEmpty ? WaveformBin(min: -0.12, max: 0.12, rms: 0.1) : bins[index]
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
    private enum LibraryScope: String, CaseIterable, Identifiable {
        case tracks = "Tracks"
        case playlists = "Playlists"

        var id: String { rawValue }
    }

    let deck: DJDeckID
    let tracks: [TrackRow]
    let playlists: [Playlist]
    let store: LibraryStore
    let onLoad: (TrackRow) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var scope: LibraryScope = .tracks
    @State private var query = ""
    @State private var selectedPlaylist: Playlist?
    @State private var playlistTracks: [TrackRow] = []
    @State private var isLoadingPlaylist = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Load from", selection: $scope) {
                    ForEach(LibraryScope.allCases) { value in
                        Text(value.rawValue).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)

                if scope == .tracks {
                    trackList(filtered(tracks))
                } else if let selectedPlaylist {
                    playlistTrackList(selectedPlaylist)
                } else {
                    playlistList
                }
            }
            .background(Palette.bg)
            .navigationTitle("Load Deck " + deck.rawValue)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
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
        .searchable(text: $query, prompt: "Search playlists")
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
                trackList(filtered(playlistTracks))
            }
        }
    }

    private func trackList(_ rows: [TrackRow]) -> some View {
        List(rows) { row in
            Button { onLoad(row) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.track.title).foregroundStyle(Palette.ink)
                    Text(trackSubtitle(row))
                        .font(.caption).foregroundStyle(Palette.ink3)
                }
            }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "No tracks" : "No matching tracks",
                    systemImage: query.isEmpty ? "music.note" : "magnifyingglass",
                    description: Text(query.isEmpty
                        ? "Add music to your library to load a DJ deck."
                        : "Search by track, artist, or album."))
            }
        }
        .searchable(text: $query, prompt: "Search tracks, artists, or albums")
        .scrollContentBackground(.hidden)
    }

    private var filteredPlaylists: [Playlist] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return playlists }
        return playlists.filter { $0.title.localizedCaseInsensitiveContains(needle) }
    }

    private func filtered(_ rows: [TrackRow]) -> [TrackRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return rows }
        return rows.filter { row in
            [row.track.title, row.artist?.name, row.album?.title]
                .compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    private func trackSubtitle(_ row: TrackRow) -> String {
        let artist = row.artist?.name ?? "Unknown artist"
        guard let album = row.album?.title, !album.isEmpty else { return artist }
        return "\(artist) · \(album)"
    }
}

private struct DJHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                help("Tap waveform", "Play or pause the deck.")
                help("Hold and drag while playing", "Scratch the track under the centered playhead.")
                help("Swipe while playing", "Nudge the track by 1/75 second.")
                help("Drag while paused", "Move the waveform beneath the stationary playhead.")
                help("Flick while paused", "Let the waveform slide naturally forward or backward.")
                help("Pinch", "Pinch in to lower BPM by 0.1; pinch out to raise BPM by 0.1.")
                help("Hot cues 1–4", "Tap an empty cue to store; tap a lit cue to jump; hold to delete.")
                help("Bassfader / Crossfader", "Blend bass or deck volume from A to B.")
                help("Output", "Choose stereo, split-left, or split-right program routing.")
                help("CUE A / CUE B", "Turn on either cue to hear that deck pre-fader in the headphone cue path. Both may be enabled together.")
            }
            .scrollContentBackground(.hidden)
            .background(Palette.bg)
            .navigationTitle("DJ Help")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func help(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline).foregroundStyle(Palette.ink)
            Text(detail).font(.subheadline).foregroundStyle(Palette.ink2)
        }
        .listRowBackground(Color.white.opacity(0.04))
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let power = pow(10, Double(places))
        return (self * power).rounded() / power
    }
}
