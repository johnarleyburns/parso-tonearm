import SwiftUI
import TonearmCore

struct DJFocusSurface: View {
    @ObservedObject var model: DJPerformanceModel
    let onBack: () -> Void
    let onInfo: () -> Void
    let onLoad: (DJDeckID) -> Void
    let onReanalyze: (DJDeckID) -> Void
    @AppStorage("dj.layout") private var layout = "focus"
    @AppStorage("dj.showLayoutSwitch") private var showLayoutSwitch = false
    @AppStorage("dj.focus.sessions") private var sessionCount = 0
    @State private var countedSession = false
    @State private var mixerPresented = false
    @State private var optionsDeck: DJDeckID?

    var body: some View {
        GeometryReader { proxy in
            Group {
                if proxy.size.width > proxy.size.height {
                    DJFocusLandscape(model: model, onBack: onBack, onInfo: onInfo, onLoad: onLoad,
                                     onMixer: { mixerPresented = true }, onOptions: { optionsDeck = $0 })
                } else if layout == "both" {
                    DJBothDecksLayout(model: model, onBack: onBack, onLoad: onLoad,
                                      onMixer: { mixerPresented = true }, onOptions: { optionsDeck = $0 })
                } else {
                    portrait(proxy.safeAreaInsets.bottom)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.bg)
        }
        .onAppear {
            guard !countedSession else { return }
            countedSession = true
            sessionCount += 1
        }
        .sheet(isPresented: $mixerPresented) {
            DJMixerSheet(model: model)
        }
        .sheet(item: $optionsDeck) { deck in
            DJDeckOptionsSheet(model: model, deck: deck, onInfo: onInfo, onReanalyze: { onReanalyze(deck) })
        }
    }

    private func portrait(_ bottomInset: CGFloat) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 10) {
                DJFocusTitleBar(model: model, onBack: onBack,
                                showLayoutSwitch: DJLayoutSwitchPolicy.shouldShow(
                                    manualSetting: showLayoutSwitch, sessionCount: sessionCount),
                                layout: $layout)
                DJDeckChips(model: model, onLoad: onLoad, onReanalyze: onReanalyze)
                DJFocusWaveformCard(model: model, onBrowse: { onLoad(model.activeDeck) })
                DJFocusTempoRow(model: model, onOptions: { optionsDeck = model.activeDeck })
                DJFocusTransportRow(model: model)
                DJPadTabsAndGrid(model: model)
                DJFocusDock(model: model, onLoad: { onLoad(model.activeDeck) }, onMixer: { mixerPresented = true })
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, max(24, bottomInset + 24))
        }
        .background {
            ZStack {
                Circle().fill(Palette.brass.opacity(0.18)).frame(width: 360).blur(radius: 50).offset(x: -170, y: -320)
                Circle().fill(Color.blue.opacity(0.12)).frame(width: 360).blur(radius: 55).offset(x: 180, y: 260)
            }
            .allowsHitTesting(false)
        }
    }
}

struct DJFocusTitleBar: View {
    @ObservedObject var model: DJPerformanceModel
    let onBack: () -> Void
    let showLayoutSwitch: Bool
    @Binding var layout: String
    var body: some View {
        HStack {
            Button(action: onBack) { Image(systemName: "chevron.down").frame(width: 36, height: 36) }
                .djFocusControl(label: "Close DJ", id: "close")
            Spacer()
            Group {
                if showLayoutSwitch {
                    Picker("Layout", selection: $layout) {
                        Text("Focus").tag("focus")
                        Text("Both decks").tag("both")
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 170)
                    .accessibilityIdentifier("dj.focus.layout")
                } else {
                    Text("Platterhead").font(.system(size: 15, weight: .semibold))
                }
            }
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button(action: model.toggleRecording) {
                HStack(spacing: 7) {
                    Circle().fill(Palette.danger).frame(width: 8, height: 8)
                    Text(model.recording ? "REC \(recordingTime)" : "REC")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                }
                .padding(.horizontal, 14).frame(height: 36)
            }
            .djFocusGlass(cornerRadius: 18)
            .accessibilityLabel(model.recording ? "Stop recording, \(recordingTime)" : "Record mix")
            .accessibilityIdentifier("dj.focus.record")
        }
        .foregroundStyle(Palette.ink)
        .frame(height: 36)
    }

    private var recordingTime: String {
        guard let started = model.recordingStartedAt else { return "00:00" }
        let seconds = max(0, Int(Date().timeIntervalSince(started)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct DJDeckChips: View {
    @ObservedObject var model: DJPerformanceModel
    let onLoad: (DJDeckID) -> Void
    let onReanalyze: (DJDeckID) -> Void
    var body: some View {
        HStack(spacing: 10) { chip(.a); chip(.b) }
            .accessibilityElement(children: .contain)
    }

    private func chip(_ id: DJDeckID) -> some View {
        let deck = model.deck(id)
        let focused = model.activeDeck == id
        return Button {
            if deck.row == nil || focused { onLoad(id) } else { model.selectDeck(id) }
        } label: {
            HStack(spacing: 10) {
                Text(id.rawValue).font(.system(size: 13, weight: .black, design: .monospaced))
                    .foregroundStyle(Palette.bg).frame(width: 26, height: 26).background(deck.accent, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(deck.row == nil ? "Load a track" : deck.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(deck.row == nil ? "Tap to browse" : DJChipReadout.text(
                        bpm: deck.bpm, remaining: deck.duration - deck.position,
                        isPlaying: deck.isPlaying, synced: deck.syncEnabled,
                        loadPhase: model.loadPhases[id]?.label,
                        onAir: model.deckIsOnAir(id), loadError: model.loadErrors[id]))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(model.loadErrors[id] == nil ? deck.accent.opacity(0.92) : Palette.danger)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 64)
        }
        .buttonStyle(.plain)
        .djFocusGlass(cornerRadius: 20, fill: focused ? deck.accent.opacity(0.16) : Color.white.opacity(0.075),
                      stroke: focused ? deck.accent.opacity(0.85) : Color.white.opacity(0.13))
        .contextMenu {
            Button("Load Track…") { onLoad(id) }
            Button("Reanalyze") { onReanalyze(id) }
            Button("Clear Hot Cues", role: .destructive) { model.clearHotCues(id) }
            Button("Clear Cue", role: .destructive) { model.clearCue(id) }
            Button("Clear Loop", role: .destructive) { model.clearLoop(id) }
        }
        .accessibilityLabel(deck.row == nil ? "Deck \(id.rawValue), Load a track" : "Deck \(id.rawValue), \(deck.title)")
        .accessibilityIdentifier("dj.focus.deck.\(id.rawValue.lowercased())")
    }
}

extension View {
    func djFocusGlass(cornerRadius: CGFloat = 18, fill: Color = Color.white.opacity(0.075), stroke: Color = Color.white.opacity(0.13)) -> some View {
        modifier(DJFocusGlass(cornerRadius: cornerRadius, fill: fill, stroke: stroke))
    }

    func djFocusControl(label: String, id: String) -> some View {
        djFocusGlass(cornerRadius: 18).accessibilityLabel(label).accessibilityIdentifier("dj.focus.\(id)")
    }
}

private struct DJFocusGlass: ViewModifier {
    let cornerRadius: CGFloat
    let fill: Color
    let stroke: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *), !reduceTransparency {
            content
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill).allowsHitTesting(false))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(stroke, lineWidth: 1).allowsHitTesting(false))
        } else {
            content
                .glassSurface(cornerRadius: cornerRadius, strokeOpacity: 0.13, fill: fill)
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(stroke, lineWidth: 1).allowsHitTesting(false))
        }
    }
}
