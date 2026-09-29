import AVFoundation
import Combine
import ParsoAudioCore
import ParsoAudioAnalysis
import ParsoDJEngine
import SwiftUI
import TonearmCore
import TonearmDiscovery




final class DJMasterOutputRouter: RealtimeInsert {
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
    private var model: DJPerformanceModel { appState.djPerformanceModel }
    @State private var loadTarget: DJDeckID?
    @State private var showHelp = false
    @AppStorage("dj.surface") private var surface = "focus"

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if surface == "classic" {
                    DJV2Surface(model: model, onBack: {
                        appState.isPerformanceSurfaceFullScreen = false
                        appState.tab = .listen
                    }, onInfo: { showHelp = true }, onLoad: { loadTarget = $0 }, onReanalyze: { reanalyze($0) })
                } else {
                    DJFocusSurface(model: model, onBack: {
                        appState.isPerformanceSurfaceFullScreen = false
                        appState.tab = .listen
                    }, onInfo: { showHelp = true }, onLoad: { loadTarget = $0 }, onReanalyze: { reanalyze($0) })
                }
            }
        }
        // Keep the top safe area owned by SwiftUI so the iPhone's Dynamic
        // Island/notch cannot cover the back button. The DJ surface still
        // owns the bottom edge and horizontal space for the mixer.
        .ignoresSafeArea(edges: [.bottom])
        .onAppear {
            appState.isPerformanceSurfaceFullScreen = true
        }
        .onDisappear {
            // Deck state and audio are owned by AppState, so changing tabs
            // does not stop playback or reset loaded tracks/positions.
            appState.isPerformanceSurfaceFullScreen = false
        }
        .sheet(item: $loadTarget) { deck in
            DJLoadSheet(deck: deck,
                        tracks: modelTracks,
                        playlists: appState.playlists,
                        store: appState.store,
                        onLoad: { target, row in
                model.load(row, into: target,
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
            if !deck.waveform.isEmpty {
                Rectangle()
                    .fill(deck.id == .a ? Palette.brass : Color.blue)
                    .frame(width: 1.5)
                    .allowsHitTesting(false)
            }
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

struct WaveformCanvas: View {
    let bins: [WaveformBin]
    let position: Double
    let duration: Double
    let hotCues: [Int: Double]
    let isPlaying: Bool
    let accent: Color
    var window: Double = 4.0

    var body: some View {
        Canvas { context, size in
            guard !bins.isEmpty else { return }
            let count = max(1, bins.count)
            let mid = size.height * 0.48
            let secondsPerBin = duration > 0 ? duration / Double(count) : window
            let firstIndex = duration > 0
                ? max(0, Int(floor((position - window / 2) / secondsPerBin)) - 1)
                : 0
            let lastIndex = duration > 0
                ? min(count - 1, Int(ceil((position + window / 2) / secondsPerBin)) + 1)
                : count - 1
            let barWidth = max(1.2, CGFloat(secondsPerBin / window) * size.width * 0.78)
            for index in firstIndex...max(firstIndex, lastIndex) {
                let bin = bins.isEmpty ? WaveformBin(min: -0.15, max: 0.15, rms: 0.1) : bins[index]
                let time = (Double(index) + 0.5) * secondsPerBin
                let x = size.width / 2 + CGFloat((time - position) / window) * size.width
                guard x + barWidth >= 0, x - barWidth <= size.width else { continue }
                drawRGBBin(bin, at: x, mid: mid, height: size.height,
                           width: barWidth, context: &context,
                           fallback: isPlaying ? accent : accent.opacity(0.62))
            }

            // Hot cues move with the waveform content. The playhead stays
            // centered, while each cue is drawn at its exact time position.
            guard duration > 0 else { return }
            for cue in hotCues.values {
                let x = size.width / 2 + CGFloat((cue - position) / window) * size.width
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

struct MiniMap: View {
    let bins: [WaveformBin]
    let position: Double
    let duration: Double
    let hotCues: [Int: Double]
    let accent: Color

    var body: some View {
        Canvas { context, size in
            guard !bins.isEmpty else { return }
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
    let onLoad: (DJDeckID, TrackRow) -> Void
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
    @State private var targetDeck: DJDeckID

    init(deck: DJDeckID, tracks: [TrackRow], playlists: [Playlist], store: LibraryStore,
         onLoad: @escaping (DJDeckID, TrackRow) -> Void) {
        self.deck = deck
        self.tracks = tracks
        self.playlists = playlists
        self.store = store
        self.onLoad = onLoad
        _targetDeck = State(initialValue: deck)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Picker("Load target", selection: $targetDeck) {
                        Text("A").tag(DJDeckID.a)
                        Text("B").tag(DJDeckID.b)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 110)
                    .accessibilityIdentifier("dj.load.target")
                    Spacer()
                    Text("Load to Deck \(targetDeck.rawValue)")
                        .font(.headline)
                }
                .padding(.horizontal)
                .padding(.top, 8)

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
            .navigationTitle("Load to Deck " + targetDeck.rawValue)
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
                                onLoad(targetDeck, row)
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
        let requiresHold = appState.djPerformanceModel.deckIsOnAir(targetDeck)
        return List(rows) { row in
            let rowView = DJLoadTrackRow(row: row, info: infoByTrackID[row.id], subtitle: trackSubtitle(row),
                                         compatibility: compatibility(for: infoByTrackID[row.id]),
                                         requiresHold: requiresHold)
            Button {
                if !requiresHold { onLoad(targetDeck, row) }
            } label: { rowView }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 1)
                    .onEnded { _ in
                        if requiresHold { onLoad(targetDeck, row) }
                    }
            )
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

    private func compatibility(for info: DJLoadTrackInfo?) -> String? {
        guard let info else { return nil }
        let other = targetDeck == .a ? appState.djPerformanceModel.deckB : appState.djPerformanceModel.deckA
        var badges: [String] = []
        if let targetKey = other.key,
           let reference = CamelotKey(code: targetKey),
           let candidate = info.camelotKey.flatMap(CamelotKey.init(code:)),
           MusicalMatchPolicy.compatibleKeys(for: reference).contains(candidate) {
            badges.append("Key match")
        }
        if let targetBPM = other.bpm, let candidateBPM = info.bpm,
           let ratio = MusicalMatchPolicy.bpmDifferenceRatio(candidate: candidateBPM, reference: targetBPM),
           ratio <= 0.02 {
            badges.append("±2%")
        }
        return badges.isEmpty ? nil : badges.joined(separator: " · ")
    }
}

private struct DJLoadTrackRow: View {
    let row: TrackRow
    let info: DJLoadTrackInfo?
    let subtitle: String
    let compatibility: String?
    let requiresHold: Bool

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
                if let compatibility {
                    Text(compatibility)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                Image(systemName: requiresHold ? "hand.tap" : "arrow.down.to.line.compact")
                    .foregroundStyle(Palette.brass)
                if requiresHold {
                    Text("Hold to replace")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Palette.danger)
                }
            }
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
