import AVFoundation
import ParsoAudioAnalysis
import ParsoAudioPlayback
import SwiftUI
import TonearmCore

enum DJDeckID: String, CaseIterable, Identifiable {
    case a = "A"
    case b = "B"

    var id: String { rawValue }
}

enum DJOutputMode: String, CaseIterable {
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
    @Published var volume = 1.0
    @Published var bass = 0.5
    @Published var hotCues: [Int: Double] = [:]

    init(id: DJDeckID) { self.id = id }

    var title: String { row?.track.title ?? "LOAD TRACK (id.rawValue)" }
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
    @Published var bassFader = 0.5
    @Published var crossfader = 0.5
    @Published var loadError: String?

    private let store: LibraryStore
    private var tracks: [TrackRow] = []
    private var tickTask: Task<Void, Never>?
    private var audio = DJAudioBacker()
    private let cues = DJHotCueStore()

    init(store: LibraryStore = .shared) {
        self.store = store
        // Keep this dependency explicit: DJ uses the app's PAE-linked playback
        // product and its shared engine version, rather than creating a second
        // listening-path stack.
        _ = ParsoAudioPlaybackLayer.layerVersion
        audio.setBass(deck: .a, gain: 0.5)
        audio.setBass(deck: .b, gain: 0.5)
        audio.setVolume(deck: .a, volume: 0.5)
        audio.setVolume(deck: .b, volume: 0.5)
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                self.tick()
            }
        }
    }

    deinit { tickTask?.cancel() }

    func updateTracks(_ tracks: [TrackRow]) { self.tracks = tracks }

    func deck(_ id: DJDeckID) -> DJDeckState { id == .a ? deckA : deckB }

    func load(_ row: TrackRow, into id: DJDeckID) {
        let deck = deck(id)
        deck.isPlaying = false
        deck.position = 0
        deck.row = row
        deck.duration = row.track.durationSec ?? 0
        deck.bpm = nil
        deck.key = nil
        deck.waveform = []
        deck.hotCues = cues.load(trackID: row.id)
        loadError = nil

        do {
            try audio.load(row: row, deck: id)
            deck.duration = audio.duration(for: id) ?? deck.duration
        } catch {
            loadError = "This track is not available on this device."
        }

        Task { [weak self] in
            guard let self else { return }
            if let analysis = try? await store.discoveryTrackAnalysis(trackId: row.id) {
                deck.bpm = analysis.bpm
                deck.key = analysis.key
                if let bpm = analysis.bpm { deck.tempo = bpm }
            }
            deck.waveform = audio.waveform(for: id)
        }
    }

    func toggle(_ id: DJDeckID) {
        let deck = deck(id)
        guard deck.row != nil else { return }
        deck.isPlaying.toggle()
        if deck.isPlaying {
            audio.play(deck: id, position: deck.position, rate: deck.tempoRatio)
        } else {
            audio.pause(deck: id)
        }
    }

    func setPlaying(_ playing: Bool, deck id: DJDeckID) {
        let deck = deck(id)
        guard deck.row != nil else { return }
        deck.isPlaying = playing
        if playing { audio.play(deck: id, position: deck.position, rate: deck.tempoRatio) }
        else { audio.pause(deck: id) }
    }

    func nudge(_ id: DJDeckID, direction: Double) {
        seek(id, by: direction / 75)
    }

    func movePaused(_ id: DJDeckID, by pixels: CGFloat, width: CGFloat) {
        let deck = deck(id)
        guard !deck.isPlaying, deck.duration > 0, width > 0 else { return }
        seek(id, by: -Double(pixels / width) * deck.duration)
    }

    func scratch(_ id: DJDeckID, by pixels: CGFloat, width: CGFloat) {
        let deck = deck(id)
        guard deck.isPlaying, deck.duration > 0, width > 0 else { return }
        seek(id, by: -Double(pixels / width) * min(deck.duration, 2))
    }

    func flick(_ id: DJDeckID, translation: CGFloat, width: CGFloat) {
        guard !deck(id).isPlaying, width > 0 else { return }
        let seconds = -Double(translation / width) * min(deck(id).duration, 3)
        seek(id, by: seconds)
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
        if let position = deck.hotCues[number] {
            seek(id, to: position)
        } else {
            deck.hotCues[number] = deck.position
            cues.save(deck.hotCues, trackID: deck.row?.id ?? -1)
        }
    }

    func deleteCue(_ number: Int, deck id: DJDeckID) {
        let deck = deck(id)
        deck.hotCues[number] = nil
        if let trackID = deck.row?.id { cues.save(deck.hotCues, trackID: trackID) }
    }

    func setBass(_ value: Double) {
        bassFader = value
        audio.setBass(deck: .a, gain: 1 - value)
        audio.setBass(deck: .b, gain: value)
    }

    func setCrossfader(_ value: Double) {
        crossfader = value
        audio.setVolume(deck: .a, volume: 1 - value)
        audio.setVolume(deck: .b, volume: value)
    }

    func cycleOutputMode() {
        let modes = DJOutputMode.allCases
        let index = modes.firstIndex(of: outputMode) ?? 0
        outputMode = modes[(index + 1) % modes.count]
        audio.setOutputMode(outputMode)
    }

    func stopAll() {
        for id in DJDeckID.allCases {
            deck(id).isPlaying = false
            audio.pause(deck: id)
        }
    }

    private func seek(_ id: DJDeckID, by amount: Double) {
        seek(id, to: deck(id).position + amount)
    }

    private func seek(_ id: DJDeckID, to value: Double) {
        let deck = deck(id)
        let position = max(0, min(deck.duration, value))
        deck.position = position
        audio.seek(deck: id, position: position, playing: deck.isPlaying, rate: deck.tempoRatio)
    }

    private func tick() {
        for id in DJDeckID.allCases {
            let deck = deck(id)
            guard deck.isPlaying, deck.duration > 0 else { continue }
            deck.position += 0.05 * deck.tempoRatio
            if deck.position >= deck.duration {
                deck.position = 0
                deck.isPlaying = false
                audio.pause(deck: id)
            }
        }
    }
}

@MainActor
private final class DJAudioBacker {
    private final class Channel {
        let player = AVAudioPlayerNode()
        let rate = AVAudioUnitVarispeed()
        let eq = AVAudioUnitEQ(numberOfBands: 1)
        let mixer = AVAudioMixerNode()
        var file: AVAudioFile?
        var duration: Double = 0
    }

    private let engine = AVAudioEngine()
    private var channels: [DJDeckID: Channel] = [.a: Channel(), .b: Channel()]
    private var started = false

    init() {
        for channel in channels.values {
            let band = channel.eq.bands[0]
            band.filterType = .lowShelf
            band.frequency = 120
            band.bandwidth = 1
            band.gain = 0
            band.bypass = false
            engine.attach(channel.player)
            engine.attach(channel.rate)
            engine.attach(channel.eq)
            engine.attach(channel.mixer)
            engine.connect(channel.player, to: channel.rate, format: nil)
            engine.connect(channel.rate, to: channel.eq, format: nil)
            engine.connect(channel.eq, to: channel.mixer, format: nil)
            engine.connect(channel.mixer, to: engine.mainMixerNode, format: nil)
        }
        engine.prepare()
    }

    func load(row: TrackRow, deck: DJDeckID) throws {
        guard let url = resolve(row.asset) else { throw DJAudioError.unavailable }
        let channel = channels[deck]!
        channel.player.stop()
        let file = try AVAudioFile(forReading: url)
        channel.file = file
        channel.duration = Double(file.length) / file.fileFormat.sampleRate
        channel.player.scheduleFile(file, at: nil)
        if !started {
            try start()
        }
    }

    func duration(for deck: DJDeckID) -> Double? { channels[deck]?.duration }

    func waveform(for deck: DJDeckID) -> [WaveformBin] {
        guard let file = channels[deck]?.file else { return [] }
        return makeWaveform(file: file)
    }

    func play(deck: DJDeckID, position: Double, rate: Double) {
        let channel = channels[deck]!
        setRate(deck: deck, rate: rate)
        if !channel.player.isPlaying { channel.player.play() }
        if position > 0 { seek(deck: deck, position: position, playing: true, rate: rate) }
    }

    func pause(deck: DJDeckID) { channels[deck]?.player.pause() }

    func seek(deck: DJDeckID, position: Double, playing: Bool, rate: Double) {
        guard let channel = channels[deck], let file = channel.file else { return }
        channel.player.stop()
        let frame = AVAudioFramePosition(max(0, min(Double(file.length), position * file.fileFormat.sampleRate)))
        let frames = AVAudioFrameCount(max(0, file.length - frame))
        channel.player.scheduleSegment(file, startingFrame: frame, frameCount: frames, at: nil)
        setRate(deck: deck, rate: rate)
        if playing { channel.player.play() }
    }

    func setRate(deck: DJDeckID, rate: Double) {
        channels[deck]?.rate.rate = Float(max(0.25, min(4, rate)))
    }

    func setBass(deck: DJDeckID, gain: Double) {
        channels[deck]?.eq.bands[0].gain = Float((gain - 0.5) * 24)
    }

    func setVolume(deck: DJDeckID, volume: Double) {
        channels[deck]?.mixer.outputVolume = Float(max(0, min(1, volume)))
    }

    func setOutputMode(_ mode: DJOutputMode) {
        let pan: Float
        switch mode {
        case .stereo: pan = 0
        case .splitLeft: pan = -1
        case .splitRight: pan = 1
        }
        for channel in channels.values { channel.mixer.pan = pan }
    }

    private func start() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
        #endif
        try engine.start()
        started = true
    }

    private func resolve(_ asset: Asset?) -> URL? {
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

    private func makeWaveform(file: AVAudioFile) -> [WaveformBin] {
        do {
            let capacity = AVAudioFrameCount(file.length)
            guard capacity > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: capacity) else { return [] }
            file.framePosition = 0
            try file.read(into: buffer)
            guard let samples = buffer.floatChannelData else { return [] }
            let count = Int(buffer.frameLength)
            var mono = [Float](repeating: 0, count: count)
            let channels = Int(buffer.format.channelCount)
            for index in 0..<count {
                var value: Float = 0
                for channel in 0..<channels { value += samples[channel][index] }
                mono[index] = value / Float(max(1, channels))
            }
            return mono.withUnsafeBufferPointer {
                WaveformPyramidBuilder.build(
                    $0,
                    sampleRate: file.fileFormat.sampleRate,
                    config: WaveformConfig(baseSamplesPerBin: max(1, count / 240), levels: 1, bandSplit: true)
                ).levels.first ?? []
            }
        } catch {
            return []
        }
    }
}

private enum DJAudioError: Error { case unavailable }

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
                DJHeader(outputMode: model.outputMode,
                         onBack: { appState.isPerformanceSurfaceFullScreen = false; appState.tab = .listen },
                         onOutput: model.cycleOutputMode,
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
        .ignoresSafeArea()
        .onAppear {
            appState.isPerformanceSurfaceFullScreen = true
            model.updateTracks(appState.allTracks)
        }
        .onDisappear {
            model.stopAll()
            appState.isPerformanceSurfaceFullScreen = false
        }
        .onChange(of: appState.allTracks) { _, rows in model.updateTracks(rows) }
        .sheet(item: $loadTarget) { deck in
            DJLoadSheet(deck: deck, tracks: modelTracks, onLoad: { row in
                model.load(row, into: deck)
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
    let onBack: () -> Void
    let onOutput: () -> Void
    let onInfo: () -> Void

    var body: some View {
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
            Button(action: onOutput) {
                Text(outputMode.rawValue)
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.6)
                    .frame(minWidth: 112, minHeight: 34)
                    .background(Color.white.opacity(0.08), in: Capsule())
            }
            .accessibilityLabel(outputMode.helpText)
            Spacer()
            Button(action: onInfo) {
                Text("(i)").font(.system(size: 17, weight: .semibold))
                    .frame(width: 34, height: 34)
            }
            .accessibilityLabel("DJ gestures and help")
        }
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 12)
        .background(Color.black.opacity(0.22))
    }
}

private struct DJWaveform: View {
    @ObservedObject var deck: DJDeckState
    let model: DJPerformanceModel
    let onLoad: () -> Void
    @State private var dragStart: CGFloat = 0
    @State private var dragStartDate = Date()
    @State private var didDrag = false
    @State private var pinchBucket: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                header
                ZStack {
                    WaveformCanvas(bins: deck.waveform,
                                   position: deck.position,
                                   duration: deck.duration,
                                   isPlaying: deck.isPlaying,
                                   accent: deck.id == .a ? Palette.brass : Color.blue)
                    .contentShape(Rectangle())
                    .gesture(touchGesture(width: proxy.size.width))
                    .simultaneousGesture(pinchGesture)
                    Rectangle()
                        .fill(Palette.brass)
                        .frame(width: 1.5)
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
        .frame(maxHeight: .infinity)
        .padding(4)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private var header: some View {
        HStack(spacing: 8) {
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
                        accent: deck.id == .a ? Palette.brass : Color.blue)
                    .frame(width: 112, height: 28)
                HStack(spacing: 3) {
                    ForEach(1...4, id: \.self) { number in
                        HotCueButton(number: number, lit: deck.hotCues[number] != nil,
                                     onTap: { model.activateCue(number, deck: deck.id) },
                                     onDelete: { model.deleteCue(number, deck: deck.id) })
                    }
                }
            }.frame(width: 112)
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .foregroundStyle(Palette.ink2)
        .padding(.horizontal, 7)
        .frame(height: 60)
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
                    dragStart = value.translation.width
                    dragStartDate = Date()
                }
                let delta = value.translation.width - dragStart
                let held = Date().timeIntervalSince(dragStartDate) >= 0.22
                if held {
                    if deck.isPlaying { model.scratch(deck.id, by: delta, width: width) }
                    else { model.movePaused(deck.id, by: delta, width: width) }
                    dragStart = value.translation.width
                }
            }
            .onEnded { value in
                let elapsed = Date().timeIntervalSince(dragStartDate)
                let distance = abs(value.translation.width)
                if distance < 12 && elapsed < 0.22 {
                    if deck.row == nil { onLoad() } else { model.toggle(deck.id) }
                } else if distance >= 12 {
                    if !deck.isPlaying && elapsed < 0.22 {
                        model.nudge(deck.id, direction: value.translation.width > 0 ? 1 : -1)
                    } else if !deck.isPlaying {
                        model.flick(deck.id, translation: value.predictedEndTranslation.width,
                                    width: width)
                    } else if elapsed < 0.22 {
                        model.nudge(deck.id, direction: value.translation.width > 0 ? 1 : -1)
                    }
                }
                didDrag = false
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
        }
    }
}

private struct MiniMap: View {
    let bins: [WaveformBin]
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
    let deck: DJDeckID
    let tracks: [TrackRow]
    let onLoad: (TrackRow) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(tracks) { row in
                Button { onLoad(row) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.track.title).foregroundStyle(Palette.ink)
                        Text(row.artist?.name ?? "Unknown artist")
                            .font(.caption).foregroundStyle(Palette.ink3)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.bg)
            .navigationTitle("Load Deck " + deck.rawValue)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
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
                help("Output", "Cycle stereo, split-left, and split-right monitoring modes.")
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
