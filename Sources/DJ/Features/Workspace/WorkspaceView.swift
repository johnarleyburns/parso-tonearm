import SwiftUI

/// The iPad DJ workspace (mockup `ipad/07-dj-workspace.html`, §41.9) over the
/// single session `WorkspaceModel` (plan 4.6). Two decks flank a centre mixer
/// column: vertical EQ stacks, filter sliders, crossfader, master meter,
/// limiter indicator, beat-phase meter and the thermal/buffer readout. The
/// transport row carries CUE / PLAY / SYNC / LOOP per deck; SYNC tap = beat,
/// hold = downbeat (§32.2).
///
/// The gate is `WorkspaceModel.isDecksEnabled` (App. T.3): free users see the
/// real surface dimmed to ~35%, controls inert, with a single lock chip —
/// nothing is blurred, nothing is hidden (§40.4, §41.15). The bottom system
/// gesture is deferred so the crossfader surface stays reachable
/// (§42.7b). Screen auto-lock scoping (§34A.6) is applied by the model from
/// telemetry, never from a view's lifetime.
public struct WorkspaceView: View {
    @StateObject private var model: WorkspaceModel
    @Environment(\.scenePhase) private var scenePhase

    /// The per-deck `JogTransport` for the §41.9a jog module — created lazily
    /// on the first intent so an idle module costs nothing (the compact
    /// surface convention).
    @State private var jogATransport: JogTransport?
    @State private var jogBTransport: JogTransport?
    /// The contextual paywall sheet (mockup `ipad/13b`, plan 4.13) — presented
    /// only when the user taps the lock chip (FR-STORE-5, §40.4).
    @State private var showingPaywall = false

    public init(model: WorkspaceModel) {
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        Group {
            if model.isDecksEnabled {
                workspace
            } else {
                ZStack(alignment: .topTrailing) {
                    workspace
                        .opacity(0.35)
                        .allowsHitTesting(false)
                    Button {
                        showingPaywall = true
                    } label: {
                        lockChip
                    }
                    .buttonStyle(.plain)
                    .padding(16)
                }
            }
        }
        .preferredColorScheme(.dark)
        #if os(iOS)
        .defersSystemGestures(on: .bottom)
        #endif
        .onAppear { try? model.begin() }
        .onDisappear { model.end() }
        .onChange(of: scenePhase) { _, phase in
            model.setPumpPaused(phase != .active)
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView(model: PaywallModel(store: model.store))
        }
    }

    private var workspace: some View {
        HStack(spacing: 12) {
            DeckColumnView(model: model, deck: .a, isMaster: true) { intent in
                if jogATransport == nil { jogATransport = JogTransport(engine: model.engine, deck: .a) }
                jogATransport?.route(intent)
            }
            MixerColumnView(model: model)
            DeckColumnView(model: model, deck: .b, isMaster: false) { intent in
                if jogBTransport == nil { jogBTransport = JogTransport(engine: model.engine, deck: .b) }
                jogBTransport?.route(intent)
            }
        }
        .padding(12)
    }

    private var lockChip: some View {
        Label("Platterhead DJ · one-time", systemImage: "lock.fill")
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
    }
}

// MARK: - Deck column

/// One deck's column: header (DECK / MASTER / SYNCED), title row, BPM/key
/// readout, waveform strip, transport (CUE · PLAY · SYNC · LOOP) and the
/// **module slot** in the lower third (§41.9a) — `JOG · STEMS · PADS · FX`,
/// remembered per deck, defaulting to `STEMS`. LOOP is the release-to-commit
/// flyout, identical to the compact idiom (§41.9a, §42.7b idiom 3).
private struct DeckColumnView: View {
    @ObservedObject var model: WorkspaceModel
    let deck: PerformanceEngine.Deck
    let isMaster: Bool
    let onJogIntent: (JogGestureModel.Intent) -> Void

    private var telemetryDeck: EngineTelemetry.Deck {
        deck == .a ? model.telemetry.deckA : model.telemetry.deckB
    }

    private var synced: Bool { model.isSynced(deck) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(deck == .a ? "DECK A" : "DECK B")
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.08), in: Capsule())
                Spacer()
                if isMaster {
                    Pill("MASTER", color: .green)
                } else if synced {
                    Pill("SYNCED", color: .cyan)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(deck == .a ? "Deck A" : "Deck B")
                    .font(.system(size: 17, weight: .bold))
                    .lineLimit(1)
                Text(String(format: "%.1f BPM · beat %.0f%%",
                            telemetryDeck.bpmEffective,
                            telemetryDeck.phase * 100))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            // The §26A waveform stack — the analysis-driven waveform from
            // persisted analysis (FR-WAVE-1): the phrase ribbon + full-track
            // overview (§26A.5 view 1) above the scrolling detail waveform
            // under its fixed-centre playhead (§26A.5 view 2).
            waveformStack

            transport

            Divider()

            // The §41.9c per-deck queue — the deck's browse surface with the
            // source picker at its head (FR-ENG-13). The two decks may point at
            // different queues at once; loading is one gesture, and the queue
            // never advances on its own (§41.9c).
            DeckQueuePanel(model: model, deck: deck)

            Divider()

            // The §41.9a module slot: the deck's lower third is one swappable
            // module, remembered per deck, default STEMS. It is a layout
            // member of this column only — never an overlay, so no shared
            // control can be occluded (AT-TWIN-2).
            DeckModuleSlotView(model: model, deck: deck, onJogIntent: onJogIntent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.03)))
    }

    /// The §26A waveform stack: phrase ribbon + full-track overview (§26A.5
    /// view 1) above the scrolling detail waveform under its fixed-centre
    /// playhead (§26A.5 view 2). All drawn from the persisted-analysis render
    /// model (FR-WAVE-1); the live playhead comes from telemetry each frame.
    @ViewBuilder
    private var waveformStack: some View {
        let waveform = model.waveform(for: deck)
        let grid = waveform?.grid
        let playhead = telemetryDeck.playheadSample
        VStack(spacing: 2) {
            PhraseRibbon(model: waveform,
                         windowStart: 0,
                         visibleSamples: Double(waveform?.durationSamples ?? 1),
                         halveLabels: WaveformThermal.current.degradesRendering)
                .frame(height: 12)
            OverviewStrip(model: waveform, playhead: playhead) { sample in
                model.seek(deck, toSample: sample, quantized: true)
            }
            .frame(height: 20)
            WaveformDetailView(
                model: waveform,
                windowStart: windowStart(for: playhead, grid: grid),
                visibleSamples: visibleSamples(for: grid),
                playhead: playhead,
                emptyTitle: model.hasLoadedTrack(deck) ? "Not analysed yet" : "Load a track",
                emptyMessage: model.hasLoadedTrack(deck) ? "Analyse to draw the waveform here"
                                                         : "Pick a track from the queue")
                .frame(height: 40)
        }
    }

    /// The performance window: 16 bars under the fixed-centre playhead (§26A.5).
    private func visibleSamples(for grid: DeckGrid?) -> Double {
        guard let grid else { return 1 }
        return 16 * grid.samplesPerBar
    }

    /// The window start, centred on the playhead and clamped to the track head.
    private func windowStart(for playhead: Int64, grid: DeckGrid?) -> Int64 {
        guard let grid else { return 0 }
        let half = visibleSamples(for: grid) / 2
        return max(0, Int64(Double(playhead) - half))
    }

    private var transport: some View {
        HStack(spacing: 8) {
            TransportButton(title: "CUE") {
                model.cue(deck)
            } onRelease: {
                model.releaseCue(deck)
            }
            TransportButton(title: telemetryDeck.playing ? "PAUSE" : "PLAY",
                            emphasized: true) {
                if telemetryDeck.playing {
                    model.pause(deck)
                } else {
                    model.play(deck)
                }
            } onRelease: {}
            TransportButton(title: "SYNC") {
                model.sync(deck, to: deck == .a ? .b : .a)
            } onRelease: {}
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                        model.sync(deck, to: deck == .a ? .b : .a, barSync: true)
                    }
                )
            // LOOP is the §41.9a/§42.7b release-to-commit flyout: a quick tap
            // keeps the 8-beat default, a hold raises the beat counts and
            // release over a size commits — identical to the compact surface.
            LoopReleaseToCommitButton(model: model, deck: deck)
        }
    }
}

/// The §41.9c per-deck queue panel (plan 5.1, decision 16): the deck's browse
/// surface on the iPad workspace. A **source picker at its head** — the queue
/// is any selectable source and the two decks may draw from different ones at
/// once (FR-ENG-13) — with the queue's rows beneath, each a one-gesture load
/// through the `WorkspaceModel` (the FR-LIB-8 gate, so a track that is not
/// deck-ready is dimmed with its reason, never a failure on the tap). Nothing
/// here auto-advances (§41.9c).
struct DeckQueuePanel: View {
    @ObservedObject var model: WorkspaceModel
    let deck: PerformanceEngine.Deck

    private var queue: DeckQueue { model.queue(for: deck) }
    private var loadState: DeckLoadState { model.loadState(for: deck) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Menu {
                    ForEach(model.availableQueues, id: \.self) { source in
                        Button {
                            Task { await model.selectQueue(source, for: deck) }
                        } label: {
                            if source == queue.source {
                                Label(source.title, systemImage: "checkmark")
                            } else {
                                Text(source.title)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.stack")
                            .font(.system(size: 10, weight: .semibold))
                        Text(queue.source.title)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.07), in: Capsule())
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                Spacer()
                Text("\(queue.rows.count) tracks")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if queue.rows.isEmpty {
                Text("No tracks in this queue yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 4) {
                        ForEach(queue.rows) { row in
                            queueRow(row)
                        }
                    }
                }
                .frame(maxHeight: 132)
            }
        }
        .task {
            await model.refreshDeckQueues()
        }
    }

    private func queueRow(_ row: DeckQueueRow) -> some View {
        let isReady = row.readiness.isReady
        let isLoading = loadState == .loading(trackID: row.trackID)
        return Button {
            guard isReady else { return }
            Task { await model.load(deck, trackID: row.trackID) }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isReady ? .primary : .secondary)
                        .lineLimit(1)
                    Text(row.artist.isEmpty ? "—" : row.artist)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                } else if row.readiness.isReady {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text(WorkspaceModel.unavailableReason(row.readiness))
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(!isReady)
        .opacity(isReady ? 1 : 0.55)
    }
}

/// A 44 pt-minimum transport button with press/release semantics (CUE is a
/// hold-to-preview control, §33.1). Shared by the iPad workspace and the
/// compact solo/twin-deck surfaces (plan 4.7).
struct TransportButton: View {
    let title: String
    var emphasized = false
    let action: () -> Void
    let onRelease: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .background(
                    emphasized ? AnyShapeStyle(Color.accentColor)
                               : AnyShapeStyle(Color.white.opacity(0.08)),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .foregroundStyle(emphasized ? .white : .primary)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0).onEnded { _ in onRelease() }
        )
    }
}

/// A small pill badge, shared across the performance surfaces.
struct Pill: View {
    let text: String
    let color: Color
    init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - Mixer column

/// The centre mixer column (§41.9): master meter, the two EQ groups stacked
/// vertically (six 44 pt knobs do not fit across the column, so they stack),
/// filter sliders, crossfader, limiter indicator, beat-phase meter and the
/// thermal/buffer readout.
private struct MixerColumnView: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        VStack(spacing: 12) {
            Text("MASTER")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            masterMeter

            EQGroup(title: "DECK A · EQ",
                    low: model.eqALow, mid: model.eqAMid, high: model.eqAHigh) { low, mid, high in
                model.setEQKnobs(.a, low: low, mid: mid, high: high)
            }
            EQGroup(title: "DECK B · EQ",
                    low: model.eqBLow, mid: model.eqBMid, high: model.eqBHigh) { low, mid, high in
                model.setEQKnobs(.b, low: low, mid: mid, high: high)
            }

            HStack(spacing: 16) {
                VStack(spacing: 4) {
                    Text("FILTER A").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    VerticalSlider(value: model.filterA, onChanged: { model.setFilter(.a, knob: $0) })
                        .frame(height: 90)
                }
                VStack(spacing: 4) {
                    Text("FILTER B").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    VerticalSlider(value: model.filterB, onChanged: { model.setFilter(.b, knob: $0) })
                        .frame(height: 90)
                }
            }

            VStack(spacing: 4) {
                Text("CROSSFADER").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Slider(value: Binding(get: { model.crossfader },
                                      set: { model.setCrossfader($0, curve: model.crossfaderCurve) }),
                       in: -1...1)
                HStack {
                    Text("A").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text("B").font(.caption2).foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 4) {
                HStack {
                    Text("JOG SENSITIVITY").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "A %.1f · B %.1f",
                                model.jogSensitivityA, model.jogSensitivityB))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                // The §41.9a per-deck jog sensitivity, 0.5–2.0 (§40.7.4) — the
                // mixer column owns the faders, and each scales the jog module's
                // gesture displacement (view-only, never the engine).
                HStack(spacing: 9) {
                    JogSensitivitySlider(value: model.jogSensitivityA,
                                         onChanged: { model.setJogSensitivity(.a, value: $0) })
                    JogSensitivitySlider(value: model.jogSensitivityB,
                                         onChanged: { model.setJogSensitivity(.b, value: $0) })
                }
            }

            Divider()

            HStack {
                Text("Limiter").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(limiterText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(limiterColor)
            }

            VStack(spacing: 4) {
                HStack {
                    Text("Downbeat").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.0f%%", model.telemetry.downbeatPhase * 100))
                        .font(.system(size: 11, design: .monospaced))
                }
                BeatPhaseMeter(phase: model.telemetry.downbeatPhase)
            }

            HStack {
                Text("CPU").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(model.telemetry.renderLoad * 100))%")
                    .font(.system(size: 11, design: .monospaced))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(Color.green)
                        .frame(width: proxy.size.width * CGFloat(min(1, model.telemetry.renderLoad)))
                }
            }
            .frame(height: 6)

            HStack {
                Text("Thermal").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(thermalText).font(.system(size: 11, design: .monospaced))
            }
            HStack {
                Text("Buffer").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f ms", model.engine.bufferPeriodMillis))
                    .font(.system(size: 11, design: .monospaced))
            }
        }
        .frame(width: 268)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.03)))
    }

    private var masterMeter: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(Color.green)
                    .frame(width: proxy.size.width * CGFloat(min(1, model.telemetry.masterLevel)))
            }
        }
        .frame(height: 8)
    }

    private var limiterText: String {
        if let ceiling = model.engine.limiterCeiling {
            return String(format: "active · −%.1f dB", (1 - ceiling) * 20)
        }
        return "idle"
    }

    private var limiterColor: Color {
        model.engine.limiterCeiling == nil ? .secondary : .green
    }

    private var thermalText: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
}

/// A deck's three EQ knobs (§41.9 — the groups stack vertically because six
/// 44 pt knobs do not fit across a 268 pt column). Shared with the compact
/// surface's EQ bank (plan 4.7).
struct EQGroup: View {
    let title: String
    let low: Float
    let mid: Float
    let high: Float
    let onChanged: (Float, Float, Float) -> Void

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.secondary)
            HStack(spacing: 7) {
                EQKnob(label: "HI", value: high) { onChanged(low, mid, $0) }
                EQKnob(label: "MID", value: mid) { onChanged(low, $0, high) }
                EQKnob(label: "LOW", value: low) { onChanged($0, mid, high) }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// A 44 pt minimum rotary knob driven by a vertical drag. The dial renders
/// −1 … +1 across ±135°; the centre detent (kill→unity→+6 dB) is §35.2's
/// mapping — the knob itself is linear knob position.
struct EQKnob: View {
    let label: String
    let value: Float
    let onChanged: (Float) -> Void

    @State private var dragStart: Float?

    var body: some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.08))
                Circle()
                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 2, height: 9)
                    .offset(y: -13)
                    .rotationEffect(.degrees(Double(value) * 135))
            }
            .frame(width: 40, height: 40)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if dragStart == nil { dragStart = value }
                        let start = dragStart ?? value
                        let delta = Float(gesture.translation.height) / 60
                        let clamped = min(1, max(-1, start - delta))
                        onChanged(clamped)
                    }
                    .onEnded { _ in dragStart = nil }
            )
        }
        .frame(width: 44, height: 44)
    }
}

/// A vertical drag fader for the sweep filters (§35.3). Shared with the
/// compact surface's filter bank (plan 4.7).
struct VerticalSlider: View {
    let value: Float
    let onChanged: (Float) -> Void

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(Color.accentColor.opacity(0.85))
                    .frame(height: max(4, height * CGFloat(clamp(0, (value + 1) / 2, 1))))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { gesture in
                    let t = 1 - gesture.location.y / height
                    onChanged(clamp(-1, Float(t) * 2 - 1, 1))
                }
            )
        }
    }
}

/// A horizontal fader for the §41.9a per-deck jog sensitivity (§40.7.4,
/// 0.5–2.0). Maps the value linearly onto the track; the whole strip is the
/// drag surface.
private struct JogSensitivitySlider: View {
    let value: Double
    let onChanged: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let t = CGFloat((value - 0.5) / 1.5)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10)).frame(height: 6)
                Capsule().fill(Color.accentColor.opacity(0.9))
                    .frame(width: 18, height: 18)
                    .offset(x: max(0, min(width - 18, width * t - 9)))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { gesture in
                    let u = Self.clampUnit(gesture.location.x / width)
                    onChanged(0.5 + 1.5 * Double(u))
                }
            )
        }
        .frame(height: 24)
    }

    private static func clampUnit(_ value: CGFloat) -> CGFloat {
        max(0, min(1, value))
    }
}

/// The beat-phase meter: the master's downbeat phase as four beat segments
/// (mockup `ipad/07`'s centre-column readout).
private struct BeatPhaseMeter: View {
    let phase: Double
    private let beatsPerBar = 4

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<beatsPerBar, id: \.self) { index in
                Capsule()
                    .fill(phase * Double(beatsPerBar) > Double(index + 1)
                          ? Color.cyan
                          : Color.cyan.opacity(0.18))
                    .frame(maxWidth: .infinity, maxHeight: 8)
            }
        }
    }
}

/// Clamp a value into a closed range.
private func clamp<T: Comparable>(_ minimum: T, _ value: T, _ maximum: T) -> T {
    min(max(value, minimum), maximum)
}
