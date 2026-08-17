import SwiftUI

/// The iPhone portrait solo-deck surface (mockups `iphone/05a`, `iphone/05b`,
/// §42.6–42.7) over the shared session `WorkspaceModel` (plan 4.7). One deck
/// in focus at full width — waveform, transport, cue pads and the bank chips
/// `Stems · EQ · Filter · Cues · Jog` — and the other deck in a 72 pt strip
/// carrying its identity, playhead and a play/pause. A swipe up on the strip
/// or a tap swaps focus: a **view-only** change, both decks stay live in the
/// engine and no engine state changes (FR-ENG-10, §42.1).
///
/// The crossfader lives in the always-visible bottom bar — the one control
/// you must never navigate to — and the browse-while-performing crate sheet
/// may never cover it (§42.7). The sheet renders *behind* the bar, and its
/// height is bounded by the model's pure geometry rule
/// (`WorkspaceModel.crateSheetMaxHeight`), so the crossfader is reachable
/// through every idiom.
///
/// The gate is `WorkspaceModel.isDecksEnabled` (App. T.3): free users see the
/// real surface dimmed, controls inert, with the lock chip (§40.4). The bottom
/// system gesture is deferred so the crossfader surface stays reachable
/// (§42.7a's shipping rule for every full-screen performance view). Controls
/// are 44 pt minimum with haptic confirmation (NFR-A11Y-3).
public struct SoloDeckView: View {
    @StateObject private var model: WorkspaceModel
    @Environment(\.scenePhase) private var scenePhase
    /// Whether this view owns the engine lifecycle (begin/end, scene-phase
    /// pump pausing, deferred system gestures). `false` when embedded in
    /// `CompactPerformanceView`, which owns the single lifecycle across a
    /// rotation — so rotating never stop/starts the engine (AT-TWIN-1).
    private let managesLifecycle: Bool
    /// The contextual paywall sheet (mockup `iphone/08`, plan 4.13) —
    /// presented only when the user taps the lock chip (FR-STORE-5, §40.4).
    @State private var showingPaywall = false

    public init(model: WorkspaceModel, managesLifecycle: Bool = true) {
        _model = StateObject(wrappedValue: model)
        self.managesLifecycle = managesLifecycle
    }

    public var body: some View {
        Group {
            if model.isDecksEnabled {
                surface
            } else {
                ZStack(alignment: .topTrailing) {
                    surface
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
        // NFR-REL-2: a stopped graph makes every readout below false at once.
        .engineStoppedBanner(model)
        .preferredColorScheme(.dark)
        .overlay(alignment: .topTrailing) {
            // The M2 soft-takeover catch indicator (plan dj-midi-alpha M2).
            MidiCatchIndicator(model: model)
                .padding(12)
        }
        #if os(iOS)
        .defersSystemGestures(on: .bottom)
        #endif
        .onAppear { if managesLifecycle { try? model.begin() } }
        .onDisappear { if managesLifecycle { model.end() } }
        .onChange(of: scenePhase) { _, phase in
            if managesLifecycle { model.setPumpPaused(phase != .active) }
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView(model: PaywallModel(store: model.store))
        }
    }

    private var surface: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    telemetryRow
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                        .padding(.bottom, 8)

                    SoloDeckColumnView(model: model, deck: model.focusedDeck,
                                       isMaster: model.focusedDeck == .a)
                        .padding(.horizontal, 14)

                    SoloStripView(model: model, deck: model.focusedDeck == .a ? .b : .a)
                        .padding(.horizontal, 14)
                        .padding(.top, 9)

                    Text("Swipe up on the strip, or tap it, to swap focus — both decks stay live")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)

                    Spacer(minLength: 8)
                }

                if model.isCrateSheetPresented {
                    CrateSheetView(model: model)
                        .frame(maxHeight: WorkspaceModel.crateSheetMaxHeight(containerHeight: proxy.size.height))
                }

                crossfaderBar
            }
        }
    }

    private var lockChip: some View {
        Label("Platterhead DJ · one-time", systemImage: "lock.fill")
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
            // §53.11: present exactly when the surface is gated — so a run
            // that lost its entitlement fails as "the decks are locked"
            // rather than as a hundred gestures landing on an inert view.
            .accessibilityIdentifier("dj.paywall.lock")
    }

    /// The §42.6 readout band: thermal state, granted buffer, the master
    /// bar:beat readout and render load sit inline because on a phone there is
    /// no menu bar to hide them in.
    private var telemetryRow: some View {
        HStack {
            HStack(spacing: 6) {
                Text(thermalText)
                    .font(.system(size: 10, design: .monospaced))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(thermalColor.opacity(0.16), in: Capsule())
                    .foregroundStyle(thermalColor)
                Text("\(Int(model.engine.bufferPeriodMillis)) ms")
                    .font(.system(size: 10, design: .monospaced))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.cyan.opacity(0.14), in: Capsule())
                    .foregroundStyle(.cyan)
                masterBarReadout
            }
            Spacer()
            Text("CPU \(Int(model.telemetry.renderLoad * 100))%")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    /// The `dj.master.bar` readout (§53.11) — the regression driver polls it
    /// to schedule gestures on phrase boundaries.
    private var masterBarReadout: some View {
        Group {
            if let barBeat = model.masterBarBeat {
                Text("BAR \(barBeat.bar) · \(barBeat.beat)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.08), in: Capsule())
                    .accessibilityLabel("\(barBeat.bar):\(barBeat.beat)")
                    .accessibilityIdentifier("dj.master.bar")
            }
        }
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

    private var thermalColor: Color {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .green
        case .fair: return .orange
        case .serious: return .red
        case .critical: return .red
        @unknown default: return .secondary
        }
    }

    /// The always-visible crossfader bottom bar (§42.1: the one control you
    /// must never have to navigate to). Rendered last in the ZStack so the
    /// crate sheet slides *behind* it and can never cover the crossfader
    /// (§42.7). The whole strip is a 1:1 relative drag surface. The §42.7c
    /// ECHO button lives here too — Echo Out needs both controls reachable
    /// without a drawer (§42.7c, §41.9b rule 7).
    private var crossfaderBar: some View {
        VStack(spacing: 6) {
            crossfaderStrip

            HStack(spacing: 8) {
                Button {
                    model.toggleRecording()
                } label: {
                    Label(
                        model.isRecording
                            ? "Stop · \(Self.elapsedText(model.recordingElapsed))"
                            : "REC",
                        systemImage: model.isRecording ? "stop.circle.fill" : "record.circle"
                    )
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(model.isRecording ? .red : .white)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("dj.transport.record")

                EchoReleaseToCommitButton(model: model, deck: model.focusedDeck,
                                          showsChannelSelector: false)

                // §44.2a: pre-listen is a transition control, so it is always
                // visible on the compact surface — never behind a drawer
                // (§42.7c's transferable core).
                CueButton(model: model, deck: model.focusedDeck)
                    .frame(minHeight: 44)

                Button {
                    model.raiseCrateSheet()
                } label: {
                    Label("Crate", systemImage: "square.stack")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("dj.crate")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Color(red: 0.063, green: 0.075, blue: 0.10))
        .overlay(alignment: .top) { Divider() }
    }

    private var crossfaderStrip: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.10))
                    .frame(height: 10)
                    .overlay {
                        HStack {
                            Text("A").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                            Spacer()
                            Text("CROSSFADER").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                            Spacer()
                            Text("B").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                    }
                let t = CGFloat((model.crossfader + 1) / 2)
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 22, height: 30)
                    .offset(x: max(0, min(width - 22, width * t - 11)))
            }
            .frame(height: 44)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let t = clampUnit(value.location.x / width)
                        model.setCrossfader(Float(t) * 2 - 1, curve: model.crossfaderCurve)
                    }
            )
            .performanceControl("dj.mixer.crossfader", label: "Crossfader",
                                value: model.crossfader)
            .coachGlow(identifier: "dj.mixer.crossfader")
        }
        .frame(height: 44)
    }

    /// "mm:ss" — the record chip's elapsed readout, shared across surfaces.
    private static func elapsedText(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Clamp a value into the closed unit interval.
private func clampUnit(_ value: CGFloat) -> CGFloat {
    max(0, min(1, value))
}

// MARK: - Focused deck

/// The focused deck at full width (§42.6): header pills, title + playhead
/// + BPM readout, waveform, transport row, hot-cue pads and the bank chip row
/// (`Stems · EQ · Filter · Cues · Jog`). The bank selection raises its
/// controls below the chips; the `Jog` chip swaps in the real `JogView`
/// (plan 4.8) — a rendered platter with position marker + phase ghost whose
/// intents reach the transport only through `JogTransport`.
private struct SoloDeckColumnView: View {
    @ObservedObject var model: WorkspaceModel
    let deck: PerformanceEngine.Deck
    let isMaster: Bool

    @State private var bank: SoloBank = .stems

    private var telemetryDeck: EngineTelemetry.Deck {
        deck == .a ? model.telemetry.deckA : model.telemetry.deckB
    }

    private var synced: Bool { model.isSynced(deck) }

    private var deckID: String { deck == .a ? "a" : "b" }

    private var eq: (low: Float, mid: Float, high: Float) {
        deck == .a ? (model.eqALow, model.eqAMid, model.eqAHigh)
                   : (model.eqBLow, model.eqBMid, model.eqBHigh)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(deck == .a ? "Deck A" : "Deck B")
                        .font(.system(size: 17, weight: .bold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("dj.deck.\(deckID).loaded")
                .accessibilityLabel(model.loadedTrackTitle(for: deck) ?? "Nothing loaded")
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(playheadText)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(String(format: "%.2f BPM", telemetryDeck.bpmEffective))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    Text("beat \(Int(telemetryDeck.phase * 100))%")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 9)

            // The §26A waveform stack — analysis-driven, from persisted
            // analysis (FR-WAVE-1): phrase ribbon + full-track overview above
            // the scrolling detail under its fixed-centre playhead.
            waveformStack

            transport
                .padding(.vertical, 10)

            HStack(spacing: 6) {
                ForEach(["A", "B", "C", "D"], id: \.self) { pad in
                    Text(pad)
                        .font(.system(size: 12, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.bottom, 10)

            bankChips
                .padding(.bottom, 10)

            bankContent
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    private var header: some View {
        HStack {
            Text(deck == .a ? "DECK A" : "DECK B")
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.08), in: Capsule())
            if isMaster {
                Pill("MASTER", color: .green)
            } else if synced {
                Pill("SYNCED", color: .cyan)
            }
            Spacer()
            Text("stems")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.green.opacity(0.14), in: Capsule())
                .foregroundStyle(.green)
        }
        .padding(.bottom, 7)
    }

    private var subtitle: String {
        if synced { return "synced · playing" }
        return telemetryDeck.playing ? "playing" : "paused"
    }

    private var playheadText: String {
        let seconds = Double(telemetryDeck.playheadSample) / model.engine.sampleRate
        return Self.timeText(seconds)
    }

    static func timeText(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let whole = Int(clamped)
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }

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
            WaveformDetailView(
                model: waveform,
                windowStart: windowStart(for: playhead, grid: grid),
                visibleSamples: visibleSamples(for: grid),
                playhead: playhead,
                emptyTitle: model.hasLoadedTrack(deck) ? "Not analysed yet" : "Load a track",
                emptyMessage: model.hasLoadedTrack(deck) ? "Analyse to draw the waveform here"
                                                         : "Pick a track from the queue")
                .frame(height: 48)
            OverviewStrip(model: waveform, playhead: playhead) { sample in
                model.seek(deck, toSample: sample, quantized: true)
            }
            .frame(height: 18)
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
        HStack(spacing: 7) {
            TransportButton(title: "CUE",
                            identifier: "dj.deck.\(deckID).cue") {
                model.cue(deck)
            } onRelease: {
                model.releaseCue(deck)
            }
            TransportButton(title: telemetryDeck.playing ? "PAUSE" : "PLAY",
                            emphasized: true,
                            identifier: "dj.deck.\(deckID).play") {
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
            TransportButton(title: "LOOP") {
                model.setLoop(deck, beats: 8)
            } onRelease: {}
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                        model.exitLoop(deck)
                    }
                )
        }
    }

    private var bankChips: some View {
        HStack(spacing: 7) {
            ForEach(SoloBank.allCases, id: \.self) { candidate in
                Button {
                    bank = candidate
                } label: {
                    Text(candidate.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                        .background(
                            bank == candidate ? Color.accentColor.opacity(0.22)
                                              : Color.white.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .foregroundStyle(bank == candidate ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var bankContent: some View {
        switch bank {
        case .stems:
            stemsBlock
        case .eq:
            EQGroup(title: "EQ", deckID: deckID,
                    low: eq.low, mid: eq.mid, high: eq.high) { low, mid, high in
                model.setEQKnobs(deck, low: low, mid: mid, high: high)
            }
        case .filter:
            HStack {
                Text("FILTER")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                VerticalSlider(value: deck == .a ? model.filterA : model.filterB,
                               identifier: "dj.deck.\(deckID).filter",
                               onChanged: { model.setFilter(deck, knob: $0) })
                    .frame(height: 96)
            }
            .padding(.horizontal, 8)
        case .fader:
            HStack {
                Text("CH")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                GainVerticalSlider(value: deck == .a ? model.channelA : model.channelB,
                                   identifier: "dj.deck.\(deckID).fader",
                                   onChanged: { model.setChannelFader(deck, gain: $0) })
                    .frame(height: 96)
            }
            .padding(.horizontal, 8)
        case .cues:
            HStack(spacing: 6) {
                ForEach(["A", "B", "C", "D"], id: \.self) { pad in
                    Text("HOT \(pad)")
                        .font(.system(size: 11, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        case .jog:
            JogView(model: model, deck: deck, onIntent: jogIntent)
                .frame(width: 168, height: 168)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
    }

    /// The jog's only route to the transport (FR-ENG-11, §40.7.7): intents are
    /// mapped by the model-owned `JogTransport` (plan M3 — one per deck, shared
    /// with a MIDI jog) onto the engine's transport intents, guarded by
    /// `RTGuard.assertRTSafe` (AT-TWIN-4).
    private func jogIntent(_ intent: JogGestureModel.Intent) {
        model.jogTransport(for: deck).route(intent)
    }

    /// The honest stem faders (§36.5, plan S8): the status is the real
    /// `DeckStemStatus` (unavailable / separating / prepared) and the faders
    /// are live `StemFaderRow`s when prepared — never the hardcoded
    /// "unavailable · M5" placeholder, and never a fader that looks live and
    /// does nothing.
    private var stemsBlock: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Stems")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(model.stemStatus(deck).label)
                    .font(.caption2)
                    .foregroundStyle(model.stemStatus(deck) == .prepared ? Color.green : .secondary)
            }
            if model.stemStatus(deck) == .prepared {
                ForEach(StemKind.allCases, id: \.self) { stem in
                    StemFaderRow(label: title(stem),
                                 gain: model.stemGain(deck, stem: stem),
                                 muted: model.stemIsMuted(deck, stem: stem),
                                 identifier: "dj.deck.\(deckID).stem.\(stem.rawValue)") { gain in
                        model.setStemGain(deck, stem: stem, gain: gain)
                    } onMuteToggled: {
                        model.setStemMute(deck, stem: stem,
                                          muted: !model.stemIsMuted(deck, stem: stem))
                    }
                }
            } else {
                // The honest disabled state: unity bars, dimmed — never a
                // live-looking fader that does nothing (§36.5).
                ForEach(StemKind.allCases, id: \.self) { stem in
                    HStack(spacing: 6) {
                        Text(title(stem))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .leading)
                        Capsule().fill(Color.white.opacity(0.06))
                            .frame(height: 12)
                    }
                }
            }
        }
    }

    private func title(_ stem: StemKind) -> String {
        switch stem {
        case .vocals: return "Vocals"
        case .drums: return "Drums"
        case .bass: return "Bass"
        case .other: return "Other"
        }
    }
}

/// The focused deck's bank set (§42.6 — the compact chip row incl. `Jog`).
private enum SoloBank: String, CaseIterable {
    case stems = "Stems"
    case eq = "EQ"
    case filter = "Filter"
    case fader = "Fader"
    case cues = "Cues"
    case jog = "Jog"
}

/// A vertical channel-fader drag (gain 0…1, §35.4) for the compact surface —
/// the twin's `ChannelFader` in a bank. `identifier` carries the §53.11
/// accessibility identifier.
private struct GainVerticalSlider: View {
    let value: Float
    var identifier: String?
    let onChanged: (Float) -> Void

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(Color.accentColor.opacity(0.85))
                    .frame(height: max(4, height * CGFloat(clampUnit(CGFloat(value)))))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { gesture in
                    let t = 1 - gesture.location.y / height
                    onChanged(Float(clampUnit(t)))
                }
            )
        }
        .performanceControl(identifier, label: "Channel fader", value: value)
        .coachGlow(identifier: identifier)
    }
}

// MARK: - The other deck in a strip

/// The non-focused deck as a 72 pt strip (§42.1): identity, BPM and state,
/// playhead, and a play/pause — enough to know it is there and to stop it.
/// A tap or a swipe up swaps focus — a view-only change, both decks stay live.
private struct SoloStripView: View {
    @ObservedObject var model: WorkspaceModel
    let deck: PerformanceEngine.Deck

    private var telemetryDeck: EngineTelemetry.Deck {
        deck == .a ? model.telemetry.deckA : model.telemetry.deckB
    }

    private var playheadText: String {
        let seconds = Double(telemetryDeck.playheadSample) / model.engine.sampleRate
        return SoloDeckColumnView.timeText(seconds)
    }

    private var stateText: String {
        if model.isSynced(deck) { return "SYNCED" }
        return telemetryDeck.playing ? "playing" : "paused"
    }

    private var stateColor: Color {
        if model.isSynced(deck) { return .cyan }
        return telemetryDeck.playing ? .green : .secondary
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(deck == .a ? "A" : "B")
                .font(.system(size: 12, weight: .bold))
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 1) {
                Text(deck == .a ? "Deck A" : "Deck B")
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(String(format: "%.1f", telemetryDeck.bpmEffective))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(stateText)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(stateColor)
                }
            }

            Spacer()

            Text(playheadText)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .monospacedDigit()

            Button {
                if telemetryDeck.playing {
                    model.pause(deck)
                } else {
                    model.play(deck)
                }
            } label: {
                Image(systemName: telemetryDeck.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06), lineWidth: 1))
        .frame(height: 72)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { model.swapFocus() }
        .gesture(
            DragGesture(minimumDistance: 24).onEnded { value in
                if value.translation.height < -16 {
                    model.swapFocus()
                }
            }
        )
    }
}

// MARK: - Browse-while-performing crate sheet

/// The browse-while-performing crate sheet (§42.7, mockup `iphone/05b`): the
/// focused deck's queue, ranked against that deck. Two rules are normative and
/// structural here: both decks stay visible above the sheet, and the sheet may
/// never cover the crossfader — the panel's height is bounded by
/// `WorkspaceModel.crateSheetMaxHeight` and it renders *behind* the
/// always-visible crossfader bar.
///
/// Plan 5.1 made the rows real (decision 16: "the crate sheet deferred in 4.7
/// gets its real rows here"): a **source picker at its head** (§41.9c,
/// FR-ENG-13 — the deck's queue may be any selectable source), and one-gesture
/// loading through `WorkspaceModel.load(_:trackID:)` with the FR-LIB-8
/// readiness shown per row (mockup `iphone/05b`'s dimmed caching row — a
/// track that is not deck-ready says so, it never fails on the tap).
/// The §41.9c per-deck source picker (FR-ENG-13), deliberately holding **values**
/// rather than the workspace model.
///
/// `Equatable` is the point: the crate sheet re-renders at telemetry cadence, and
/// a `Menu` whose subtree is rebuilt underneath it closes. Comparing equal across
/// frames where the crates and the selection have not changed keeps a presented
/// menu on screen — the difference between a picker you can use while the decks
/// run and one that snaps shut in your hand.
struct QueueSourcePicker: View, Equatable {
    let deckID: String
    let sources: [DeckQueueSource]
    let current: DeckQueueSource
    let select: (DeckQueueSource) -> Void

    /// `nonisolated` because SwiftUI compares view values off the main actor:
    /// only the immutable inputs are read, never the action closure.
    nonisolated static func == (lhs: QueueSourcePicker, rhs: QueueSourcePicker) -> Bool {
        lhs.deckID == rhs.deckID && lhs.sources == rhs.sources && lhs.current == rhs.current
    }

    var body: some View {
        Menu {
            ForEach(sources, id: \.self) { source in
                Button {
                    select(source)
                } label: {
                    if source == current {
                        Label(source.title, systemImage: "checkmark")
                    } else {
                        Text(source.title)
                    }
                }
                .accessibilityIdentifier("dj.queue.\(source.title)")
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.stack")
                Text(current.title)
                    .lineLimit(1)
            }
            .font(.system(size: 14, weight: .bold))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("dj.deck.\(deckID).queue")
    }
}

private struct CrateSheetView: View {
    @ObservedObject var model: WorkspaceModel

    private var deck: PerformanceEngine.Deck { model.focusedDeck }
    private var queue: DeckQueue { model.queue(for: deck) }
    private var loadState: DeckLoadState { model.loadState(for: deck) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.18))
                .frame(width: 38, height: 4)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
                .padding(.bottom, 12)

            header

            Divider()

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(queue.rows) { row in
                        rowView(row)
                    }
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .background(Color(red: 0.055, green: 0.075, blue: 0.10))
        .overlay(alignment: .top) { Divider() }
        .accessibilityIdentifier("dj.crate.sheet")
        .task {
            await model.refreshDeckQueues()
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                // The §41.9c source picker at the browse surface's head — the
                // deck's queue is any selectable source; the other deck is
                // untouched (FR-ENG-13). It takes plain values and compares
                // equal across telemetry frames on purpose: this sheet observes
                // the model, whose telemetry publishes at display rate, so a
                // picker rebuilt from that would dismiss its own open menu
                // within a frame or two — browse-while-performing means the
                // crate list has to stay open while the decks run.
                QueueSourcePicker(deckID: deck == .a ? "a" : "b",
                                  sources: model.availableQueues,
                                  current: queue.source) { source in
                    Task { await model.selectQueue(source, for: deck) }
                }
                .equatable()
                Text("\(queue.rows.count) tracks · ranked against DECK \(deck == .a ? "A" : "B") · browse while performing")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.dismissCrateSheet()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("dj.crate.close")
        }
        .padding(.horizontal, 15)
        .padding(.bottom, 10)
    }

    private func rowView(_ row: DeckQueueRow) -> some View {
        let isReady = row.readiness.isReady
        let isLoading = loadState == .loading(trackID: row.trackID)
        return Button {
            guard isReady else { return }
            Task { await model.load(deck, trackID: row.trackID) }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isReady ? .primary : .secondary)
                        .lineLimit(1)
                    Text(row.artist.isEmpty ? "—" : row.artist)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                status(for: row, isLoading: isLoading)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 9)
            .background(Color.white.opacity(isReady ? 0.04 : 0.02), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!isReady)
        .opacity(isReady ? 1 : 0.5)
        .accessibilityIdentifier("dj.queue.row.\(row.title)")
    }

    @ViewBuilder
    private func status(for row: DeckQueueRow, isLoading: Bool) -> some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
        } else if row.readiness.isReady {
            Label("load", systemImage: "play.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        } else {
            Text(WorkspaceModel.unavailableReason(row.readiness))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }
}
