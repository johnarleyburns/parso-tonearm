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

    init(id: DJDeckID) { self.id = id }

    var title: String { row?.track.title ?? "LOAD TRACK " + id.rawValue }
    var artist: String { row?.artist?.name ?? "" }
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
                try? await Task.sleep(for: .milliseconds(50))
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
        deck.tempo = 120
        loadError = nil

        Task { [weak self, store] in
            do {
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
        else { audio.pause(deck: id) }
    }

    func setPlaying(_ playing: Bool, deck id: DJDeckID) {
        let deck = deck(id)
        guard deck.row != nil else { return }
        deck.isPlaying = playing
        if playing { audio.play(deck: id, position: deck.position, rate: deck.tempoRatio) }
        else { audio.pause(deck: id) }
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
            cues.save(deck.hotCues, trackID: deck.row?.id ?? -1)
        }
    }

    func deleteCue(_ number: Int, deck id: DJDeckID) {
        let deck = deck(id)
        deck.hotCues[number] = nil
        audio.deleteHotCue(number, deck: id)
        if let trackID = deck.row?.id { cues.save(deck.hotCues, trackID: trackID) }
    }

    func setBass(_ value: Double) {
        bassFader = value
        audio.setBassBlend(value)
    }

    func setCrossfader(_ value: Double) {
        crossfader = value
        audio.setCrossfader(value)
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
        for id in DJDeckID.allCases {
            let deck = deck(id)
            deck.position = min(deck.duration, audio.position(for: id))
            if !scratching.contains(id) {
                deck.isPlaying = audio.isPlaying(for: id)
            }
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
        GeometryReader { proxy in
            VStack(spacing: 0) {
                // DJView intentionally renders edge-to-edge so the dock cannot
                // cover the mixer, but the header still has to clear the
                // Dynamic Island/notch. Without this spacer the top part of
                // the header is underneath the iPhone display cutout.
                Color.clear.frame(height: proxy.safeAreaInsets.top)
                DJHeader(outputMode: model.outputMode,
                         cueA: model.cueA,
                         cueB: model.cueB,
                         onBack: { appState.isPerformanceSurfaceFullScreen = false; appState.tab = .listen },
                         onOutput: model.setOutputMode,
                         onCueA: { model.toggleCue(.a) },
                         onCueB: { model.toggleCue(.b) },
                         onInfo: { showHelp = true })
                    .frame(height: 58)
                waveformArea
                DJFooter(bass: model.bassFader,
                         crossfade: model.crossfader,
                         onBass: model.setBass,
                         onCrossfade: model.setCrossfader)
                    .frame(height: 58)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(Palette.bg)
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
                        .contentShape(Rectangle())
                        .gesture(touchGesture(width: waveformProxy.size.width))
                        .simultaneousGesture(pinchGesture)
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
                    }
                    .background(Color.white.opacity(0.035))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
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
        DragGesture(minimumDistance: 0)
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
                lastX = value.translation.width
                lastSampleDate = now

                if deck.isPlaying {
                    if touchMode == .pending,
                       horizontal,
                       abs(value.translation.width) >= 12,
                       speed > 900,
                       elapsed < 0.28 {
                        touchMode = .nudge
                    } else if touchMode == .pending, elapsed >= 0.22 {
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
                if distance < 12 && elapsed < 0.22 {
                    if deck.row == nil { onLoad() } else { model.toggle(deck.id) }
                } else if horizontal && distance >= 12 {
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

    var body: some View {
        Canvas { context, size in
            let count = max(1, bins.count)
            let mid = size.height * 0.48
            let step = size.width / CGFloat(count)
            let progress = duration > 0 ? max(0, min(1, position / duration)) : 0
            let scrollOffset = size.width / 2 - CGFloat(progress) * size.width
            for index in 0..<count {
                let bin = bins.isEmpty ? WaveformBin(min: -0.15, max: 0.15, rms: 0.1) : bins[index]
                let x = scrollOffset + CGFloat(index) * step + step / 2
                guard x + step >= 0, x - step <= size.width else { continue }
                let top = mid - CGFloat(bin.max) * size.height * 0.42
                let bottom = mid - CGFloat(bin.min) * size.height * 0.42
                var path = Path()
                path.move(to: CGPoint(x: x, y: top))
                path.addLine(to: CGPoint(x: x, y: bottom))
                context.stroke(path,
                               with: .color(isPlaying ? accent : accent.opacity(0.62)),
                               lineWidth: max(1, step * 0.58))
            }

            // Hot cues move with the waveform content. The playhead stays
            // centered, while each cue is drawn at its exact time position.
            guard duration > 0 else { return }
            for cue in hotCues.values {
                let cueProgress = max(0, min(1, cue / duration))
                let x = size.width / 2 + CGFloat(cueProgress - progress) * size.width
                guard x >= -1, x <= size.width + 1 else { continue }
                var marker = Path()
                marker.move(to: CGPoint(x: x, y: 8))
                marker.addLine(to: CGPoint(x: x, y: max(8, size.height - 8)))
                context.stroke(marker, with: .color(Palette.brass.opacity(0.95)), lineWidth: 2)
            }
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
                var path = Path()
                let x = CGFloat(index) * step + step / 2
                path.move(to: CGPoint(x: x, y: mid - CGFloat(bin.max) * size.height * 0.42))
                path.addLine(to: CGPoint(x: x, y: mid - CGFloat(bin.min) * size.height * 0.42))
                context.stroke(path, with: .color(accent.opacity(0.7)), lineWidth: max(1, step))
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
