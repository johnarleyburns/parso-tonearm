import SwiftUI

/// The iPhone landscape twin-deck surface (mockup `iphone/05c`, §42.7a) over
/// the single session `WorkspaceModel` (plan 4.9). Both decks are resident —
/// a 168 pt jog each, stacked waveforms on one shared playhead, a 202 pt mixer
/// column (beat-phase meter, channel faders A/B, SYNC tap=beat/hold=downbeat,
/// crossfader), 54×54 transport, a per-deck bank tab, and a continuous
/// screen-edge filter slider on each edge that costs no layout width and is
/// never occluded.
///
/// The layout follows §42.7a's budget exactly (encoded in
/// `WorkspaceModel.TwinGeometry`): `734 = 30 │ 168 jog A │ 6 │ 54 transport │
/// 8 │ 202 mixer │ 8 │ 54 transport │ 6 │ 168 jog B │ 30`. The two 59 pt bands
/// are the landscape sensor-housing dead zones — nothing interactive lives
/// there. The centre of the screen carries only display (waveforms, beat
/// phase, identity); every control sits inside a thumb arc (§42.1).
///
/// The jog is wired exactly as in the solo surface: `JogView` intents reach
/// the transport only through a lazily-created `JogTransport` guarded by
/// `RTGuard.assertRTSafe` (FR-ENG-11, AT-TWIN-4). The momentary bank drawer
/// the tabs announce is commit 4.10 — until then the tabs render the honest
/// passive bar.
///
/// Like `SoloDeckView`, the gate is `WorkspaceModel.isDecksEnabled` (App. T.3)
/// and the view owns its engine lifecycle by default; when embedded in
/// `CompactPerformanceView` (`managesLifecycle: false`) the container owns the
/// single lifecycle so rotating never stop/starts the engine (FR-ENG-10,
/// AT-TWIN-1).
public struct TwinDeckView: View {
    @StateObject private var model: WorkspaceModel
    @Environment(\.scenePhase) private var scenePhase
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
                .padding(.top, 56).padding(.trailing, 12)
        }
        .ignoresSafeArea()
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

    private var surface: some View {
        GeometryReader { proxy in
            let bandTop: CGFloat = 20 + 90 + 38
            ZStack(alignment: .top) {
                // The two 59 pt sensor-housing dead bands carry nothing
                // interactive (§42.7a). The filter edge sliders render *over*
                // this padding at the true screen edges — always live, never
                // occluded (§42.7b's rule 2).
                VStack(spacing: 0) {
                    telemetryRow
                    StackedWaveformView(model: model)
                    identityRow
                    controlBand
                }
                .padding(.horizontal, 59)

                // The screen-edge filter sliders: 24 pt wide, zero layout
                // width, at the innermost point of each thumb arc, and they
                // stay reachable with a bank drawer open (§42.7a).
                HStack {
                    EdgeSlider(value: model.filterA,
                               onChanged: { model.setFilter(.a, knob: $0) })
                        .frame(width: WorkspaceModel.DrawerGeometry.edgeSliderWidth)
                        .accessibilityIdentifier("dj.deck.a.filter")
                        .coachGlow(identifier: "dj.deck.a.filter")
                    Spacer()
                    EdgeSlider(value: model.filterB,
                               onChanged: { model.setFilter(.b, knob: $0) })
                        .frame(width: WorkspaceModel.DrawerGeometry.edgeSliderWidth)
                        .accessibilityIdentifier("dj.deck.b.filter")
                        .coachGlow(identifier: "dj.deck.b.filter")
                }
                .padding(.top, bandTop + 20)
                .frame(height: max(0, proxy.size.height - bandTop - 40))
                .padding(.horizontal, 12)

                // The momentary bank drawer (§42.7b): exactly one deck column
                // wide over that deck's jog + transport — the crossfader, both
                // waveforms, the beat-phase meter and the opposite jog stay
                // live and hit-testable (FR-ENG-12, AT-TWIN-2).
                if let deck = model.drawerState.deck {
                    BankDrawerView(model: model, deck: deck)
                        .frame(width: WorkspaceModel.DrawerGeometry.width,
                               height: WorkspaceModel.DrawerGeometry.height)
                        .position(drawerPosition(in: proxy, deck: deck))
                }
            }
        }
        // The §42.7a bottom-edge crossfader drag surface: full width, 40 pt
        // tall, over the vertical slack + home indicator — a 1:1 relative drag
        // from anywhere, never covered by a modal idiom (§42.7b).
        .overlay(alignment: .bottom) {
            BottomEdgeCrossfader(
                model: model,
                residentCapTravel: WorkspaceModel.TwinGeometry.mixerColumnWidth
                    - WorkspaceModel.TwinGeometry.crossfaderCapWidth)
        }
    }

    /// The drawer's centre over a deck's column in the surface's (full-bleed,
    /// §42.7a canvas) coordinate space: the 59 pt dead band, then the §42.7a
    /// 30 pt outer margin, then the 228 pt column.
    private func drawerPosition(in proxy: GeometryProxy,
                                deck: PerformanceEngine.Deck) -> CGPoint {
        let width = WorkspaceModel.DrawerGeometry.width
        let x: CGFloat
        switch deck {
        case .a:
            x = WorkspaceModel.DrawerGeometry.deadBandInset
                + WorkspaceModel.TwinGeometry.outerMargin + width / 2
        case .b:
            x = proxy.size.width - WorkspaceModel.DrawerGeometry.deadBandInset
                - WorkspaceModel.TwinGeometry.outerMargin - width / 2
        }
        let bandTop: CGFloat = 20 + 90 + 38
        return CGPoint(x: x, y: bandTop + WorkspaceModel.DrawerGeometry.height / 2)
    }

    /// The §42.7a telemetry band: the correctness readouts stay inline because
    /// on a phone there is no menu bar to hide them in. The `dj.master.bar`
    /// readout (§53.11) lives here so the regression driver can schedule
    /// gestures on phrase boundaries.
    private var telemetryRow: some View {
        HStack(spacing: 5) {
            Text(thermalText)
                .font(.system(size: 10, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(thermalColor.opacity(0.16), in: Capsule())
                .foregroundStyle(thermalColor)
            Text("\(Int(model.engine.bufferPeriodMillis)) ms")
                .font(.system(size: 10, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.cyan.opacity(0.14), in: Capsule())
                .foregroundStyle(.cyan)
            Text("TWIN · landscape")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.14), in: Capsule())
                .foregroundStyle(Color.accentColor)
            Spacer()
            masterBarReadout
            Button {
                model.toggleRecording()
            } label: {
                Text(model.isRecording
                     ? "Stop \(Self.elapsedText(model.recordingElapsed))"
                     : "REC")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(model.isRecording ? Color.red.opacity(0.2)
                                                  : Color.red.opacity(0.55),
                                in: Capsule())
                    .foregroundStyle(model.isRecording ? .red : .white)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("dj.transport.record")
            Text("CPU \(Int(model.telemetry.renderLoad * 100))%")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(height: 20)
        .padding(.horizontal, 2)
    }

    private static func elapsedText(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
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

    /// The §42.7a identity row (38 pt): deck titles and BPM/beat readouts
    /// deck-side, the master spectrum + limiter readout centre — the centre
    /// of the screen carries information, never controls (§42.1).
    private var identityRow: some View {
        HStack {
            DeckIdentityView(model: model, deck: .a, alignsTrailing: false)
            Spacer()
            MasterReadoutView(model: model)
            Spacer()
            DeckIdentityView(model: model, deck: .b, alignsTrailing: true)
        }
        .frame(height: 38)
        .padding(.horizontal, 20)
    }

    /// The `dj.master.bar` readout (§53.11): the master clock's bar:beat,
    /// exposed for the regression driver's bar-aware gesture scheduling.
    private var masterBarReadout: some View {
        Group {
            if let barBeat = model.masterBarBeat {
                Text("BAR \(barBeat.bar) · \(barBeat.beat)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.08), in: Capsule())
                    .accessibilityLabel("\(barBeat.bar):\(barBeat.beat)")
                    .accessibilityIdentifier("dj.master.bar")
            }
        }
    }

    /// The control band: deck A (jog + transport) · mixer · deck B (transport
    /// + jog), exactly the §42.7a budget. The band is where the thumbs are;
    /// the mixer carries only what must be shared and continuous.
    private var controlBand: some View {
        HStack(spacing: WorkspaceModel.TwinGeometry.columnGap) {
            TwinDeckColumnView(model: model, deck: .a, transportFirst: false) { intent in
                model.jogTransport(for: .a).route(intent)
            }
            .frame(width: WorkspaceModel.TwinGeometry.deckColumnWidth)

            TwinMixerColumnView(model: model)
                .frame(width: WorkspaceModel.TwinGeometry.mixerColumnWidth)

            TwinDeckColumnView(model: model, deck: .b, transportFirst: true) { intent in
                model.jogTransport(for: .b).route(intent)
            }
            .frame(width: WorkspaceModel.TwinGeometry.deckColumnWidth)
        }
        .frame(height: 206)
        .padding(.horizontal, WorkspaceModel.TwinGeometry.outerMargin)
    }
}

// MARK: - One deck's column

/// One resident deck's control block (§42.7a): the 168 pt jog and the 54×54
/// transport stack side by side (transport on the inner side — deck A's jog
/// sits at the left thumb, deck B's at the right), with the bank tab below.
private struct TwinDeckColumnView: View {
    @ObservedObject var model: WorkspaceModel
    let deck: PerformanceEngine.Deck
    let transportFirst: Bool
    let onJogIntent: (JogGestureModel.Intent) -> Void

    private var telemetryDeck: EngineTelemetry.Deck {
        deck == .a ? model.telemetry.deckA : model.telemetry.deckB
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: WorkspaceModel.TwinGeometry.jogTransportGap) {
                if transportFirst {
                    transportStack
                    jog
                } else {
                    jog
                    transportStack
                }
            }
        }
        .frame(height: WorkspaceModel.DrawerGeometry.height, alignment: .top)
        .overlay(alignment: .bottom) {
            // The bank tab the momentary drawer anchors to (§42.7b). Its 44 pt
            // hit region overlaps the jog's lower rim per §42.7a; holding
            // springs the drawer open over this deck's jog + transport,
            // releasing dismisses it (restoring the jog within one frame) and
            // a tap pins it for hands-free work (AT-TWIN-3).
            BankTabButton(model: model, deck: deck)
        }
    }

    private var jog: some View {
        JogView(model: model, deck: deck, onIntent: onJogIntent)
            .frame(width: WorkspaceModel.TwinGeometry.jogWidth,
                   height: WorkspaceModel.TwinGeometry.jogWidth)
    }

    /// The 54×54 transport: CUE · PLAY/PAUSE · LOOP (54×48), with the loop's
    /// release-to-commit flyout (§42.7b idiom 3). CUE reads before PLAY at the
    /// deck's inner base (§41.9b rule 3's compact adaptation — the vertical
    /// stack is the §42.7a budget's answer to a 54 pt column). SYNC lives in
    /// the mixer column, not here (§42.7a).
    private var transportStack: some View {
        VStack(spacing: 6) {
            TransportButton(title: "CUE",
                            identifier: "dj.deck.\(deckID).cue") {
                model.cue(deck)
            } onRelease: {
                model.releaseCue(deck)
            }
            .frame(width: WorkspaceModel.TwinGeometry.transportWidth,
                   height: WorkspaceModel.TwinGeometry.transportWidth)

            TransportButton(title: telemetryDeck.playing ? "PAUSE" : "PLAY",
                            emphasized: true,
                            identifier: "dj.deck.\(deckID).play") {
                if telemetryDeck.playing {
                    model.pause(deck)
                } else {
                    model.play(deck)
                }
            } onRelease: {}
            .frame(width: WorkspaceModel.TwinGeometry.transportWidth,
                   height: WorkspaceModel.TwinGeometry.transportWidth)

            LoopReleaseToCommitButton(model: model, deck: deck)
        }
    }

    private var deckID: String { deck == .a ? "a" : "b" }
}

/// The bank tab (§42.7b): a 44 pt-hit-region strip overlaid on the jog's lower
/// rim whose **press** springs the §42.7b drawer over this deck's jog +
/// transport. Releasing dismisses it (AT-TWIN-3 restores the jog within one
/// frame); a press shorter than `WorkspaceModel.DrawerGeometry.tapThreshold`
/// is a tap that pins the bank for hands-free work. Pressing the tab of an
/// already-pinned bank toggles it off.
private struct BankTabButton: View {
    @ObservedObject var model: WorkspaceModel
    let deck: PerformanceEngine.Deck

    @State private var pressStart: Date?
    @State private var dismissedPinned = false

    private var isBank: String { deck == .a ? "A" : "B" }

    var body: some View {
        HStack {
            Text("HOLD ▲ \(isBank) BANK")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("EQ · STEMS · PADS · CUES")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(
                model.drawerState.deck == deck ? Color.accentColor.opacity(0.10)
                                               : Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.06), lineWidth: 1))
        .frame(height: 44, alignment: .bottom)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard pressStart == nil else { return }
                    pressStart = Date()
                    if case .pinned(let pinnedDeck, _) = model.drawerState, pinnedDeck == deck {
                        model.dismissDrawer()
                        dismissedPinned = true
                    } else {
                        model.springDrawer(deck: deck)
                    }
                }
                .onEnded { _ in
                    let held = Date().timeIntervalSince(pressStart ?? Date())
                    defer { pressStart = nil; dismissedPinned = false }
                    guard !dismissedPinned else { return }
                    guard model.drawerState.deck == deck else { return }
                    if WorkspaceModel.springReleasePins(holdDuration: held) {
                        model.pinDrawer()
                    } else {
                        model.releaseDrawer()
                    }
                }
        )
    }
}

// MARK: - Stacked waveforms on one shared playhead

/// The §42.7a stacked-waveform display: deck A and deck B detail waveforms on
/// **one shared playhead** — each strip scrolls under its own fixed centre
/// line, so when the decks are in phase the grids align across the shared
/// centre (the "grids line up" read, §26A.5). Both draw from persisted
/// analysis (FR-WAVE-1) — the honest empty state replaces the old placeholder.
private struct StackedWaveformView: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        VStack(spacing: 2) {
            waveRow(deck: .a)
            waveRow(deck: .b)
        }
        .frame(height: 90)
    }

    private func waveRow(deck: PerformanceEngine.Deck) -> some View {
        let waveform = model.waveform(for: deck)
        let grid = waveform?.grid
        let playhead = deck == .a ? model.telemetry.deckA.playheadSample
                                  : model.telemetry.deckB.playheadSample
        let visibleSamples: Double = grid.map { 8 * $0.samplesPerBar } ?? 1
        let windowStart: Int64 = grid.map { grid in
            max(0, Int64(Double(playhead) - visibleSamples / 2))
        } ?? 0
        return VStack(spacing: 1) {
            // §26A.4: each waveform carries its phrase ribbon above it.
            PhraseRibbon(model: waveform,
                         windowStart: 0,
                         visibleSamples: Double(waveform?.durationSamples ?? 1),
                         halveLabels: WaveformThermal.current.degradesRendering)
                .frame(height: 11)
            HStack(spacing: 5) {
                Text(deck == .a ? "A" : "B")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(deck == .a ? .white : Color.cyan.opacity(0.9))
                    .frame(width: 12)
                WaveformDetailView(
                    model: waveform,
                    windowStart: windowStart,
                    visibleSamples: visibleSamples,
                    playhead: playhead,
                    emptyTitle: model.hasLoadedTrack(deck) ? "Not analysed" : "Load a track",
                    emptyMessage: model.hasLoadedTrack(deck) ? "Analyse to draw it here"
                                                             : "Pick from the queue")
            }
            .frame(height: 29)
        }
    }
}

// MARK: - Identity / master readout

/// One deck's identity cell (§42.7a): title, elapsed time and BPM/beat
/// readout. Track titles and keys land with the library seam (the 4.7
/// decision) — the identity row carries the honest deck placeholder.
private struct DeckIdentityView: View {
    @ObservedObject var model: WorkspaceModel
    let deck: PerformanceEngine.Deck
    let alignsTrailing: Bool

    private var telemetryDeck: EngineTelemetry.Deck {
        deck == .a ? model.telemetry.deckA : model.telemetry.deckB
    }

    var body: some View {
        VStack(alignment: alignsTrailing ? .trailing : .leading, spacing: 1) {
            Text(deck == .a ? "Deck A" : "Deck B")
                .font(.system(size: 12.5, weight: .bold))
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(playheadText)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(String(format: "%.1f BPM", telemetryDeck.bpmEffective))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("beat \(Int(telemetryDeck.phase * 100))%")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 228, alignment: alignsTrailing ? .trailing : .leading)
    }

    private var playheadText: String {
        let seconds = Double(telemetryDeck.playheadSample) / model.engine.sampleRate
        let clamped = max(0, seconds)
        return String(format: "%02d:%02d", Int(clamped) / 60, Int(clamped) % 60)
    }
}

/// The centre identity cell (§42.7a): the master spectrum (honest baseline
/// bars) with the limiter state, the read-only centre of the screen.
private struct MasterReadoutView: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 2) {
                ForEach(0..<14, id: \.self) { index in
                    let height = CGFloat(0.3 + 0.7 * (Double((index * 7) % 10) / 10))
                    Capsule()
                        .fill(Color.white.opacity(0.35))
                        .frame(width: 3, height: 20 * height)
                }
            }
            .frame(height: 20)
            HStack {
                Text("MASTER")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(limiterText)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(limiterColor)
            }
        }
        .frame(width: 202)
    }

    private var limiterText: String {
        if let ceiling = model.engine.limiterCeiling {
            return String(format: "limiter −%.1f dB", (1 - ceiling) * 20)
        }
        return "limiter idle"
    }

    private var limiterColor: Color {
        model.engine.limiterCeiling == nil ? .secondary : .green
    }
}

// MARK: - Mixer column

/// The 202 pt mixer column (§42.7a): only what must be shared and continuous —
/// the beat-phase meter (centred means locked, with signed millisecond error),
/// channel faders A/B, SYNC (tap = beat, hold = downbeat) and the crossfader.
/// **No EQ** — three 44 pt knobs cannot fit the 202 pt column, so EQ is a
/// bank, not a resident control.
private struct TwinMixerColumnView: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        VStack(spacing: 4) {
            Text("BEAT PHASE · A vs B")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)

            PhaseErrorMeter(errorFraction: errorFraction)

            Text(phaseText)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(phaseColor)

            HStack(alignment: .center, spacing: 12) {
                ChannelFader(label: "CH A", value: model.channelA,
                             identifier: "dj.deck.a.fader",
                             onChanged: { model.setChannelFader(.a, gain: $0) })
                syncButton
                ChannelFader(label: "CH B", value: model.channelB,
                             identifier: "dj.deck.b.fader",
                             onChanged: { model.setChannelFader(.b, gain: $0) })
            }
            .padding(.top, 2)

            crossfaderBox

            // §42.7c: the ECHO button in the always-visible band — Echo Out is
            // a two-control transition (echo on, fader down), so both must be
            // reachable without a drawer. The shared button's flyout carries
            // the A/B channel chips (the twin's single ECHO serves either
            // channel).
            EchoReleaseToCommitButton(model: model, deck: .a)
            // §44.2a: pre-listen is a transition control, so it is always
            // visible — never behind a drawer (§42.7c's transferable core).
            // **One CUE per channel**, not one for the focused deck: this
            // surface shows both decks at once, and every mixer ever built
            // puts a cue button on each channel. Cueing B while working A is
            // the ordinary case, and a focus-following button would make it
            // impossible.
            HStack(spacing: 12) {
                CueButton(model: model, deck: .a)
                CueButton(model: model, deck: .b)
            }
            .frame(minHeight: 44)
        }
    }

    private var errorFraction: Double {
        let error = WorkspaceModel.beatPhaseError(phaseA: model.telemetry.deckA.phase,
                                                  phaseB: model.telemetry.deckB.phase)
        // Render −0.5…0.5 as the meter's −1…1 span.
        return error * 2
    }

    private var phaseText: String {
        guard model.telemetry.masterBPM > 0 else { return "no master clock" }
        return String(format: "%@ · ±%.1f ms",
                      abs(model.beatPhaseErrorMillis) < 10 ? "locked" : "off",
                      abs(model.beatPhaseErrorMillis))
    }

    private var phaseColor: Color {
        model.telemetry.masterBPM > 0 && abs(model.beatPhaseErrorMillis) < 10
            ? .green : .secondary
    }

    /// SYNC lives in the mixer: tap = beat, hold = downbeat (§32.2). Deck B
    /// syncs to master A, the deck the jog's MASTER cap names.
    private var syncButton: some View {
        VStack(spacing: 4) {
            Button {
                model.sync(.b, to: .a)
            } label: {
                Text("SYNC")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 54, height: 44)
                    .background(
                        model.isSynced(.b) ? Color.cyan.opacity(0.28)
                                           : Color.white.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(model.isSynced(.b) ? Color.cyan : .primary)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                    model.sync(.b, to: .a, barSync: true)
                }
            )
            Text("tap = beat\nhold = downbeat")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var crossfaderBox: some View {
        VStack(spacing: 5) {
            HStack {
                Text("A").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("CROSSFADER").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("B").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.10))
                        .frame(height: 10)
                    let t = CGFloat((model.crossfader + 1) / 2)
                    Capsule()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 22, height: 29)
                        .offset(x: max(0, min(width - 22, width * t - 11)))
                }
                .frame(height: 34)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { value in
                        let t = Self.clampUnit(value.location.x / width)
                        model.setCrossfader(Float(t) * 2 - 1, curve: model.crossfaderCurve)
                    }
                )
                .performanceControl("dj.mixer.crossfader", label: "Crossfader",
                                    value: model.crossfader)
                .coachGlow(identifier: "dj.mixer.crossfader")
            }
            .frame(height: 34)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    private static func clampUnit(_ value: CGFloat) -> CGFloat {
        max(0, min(1, value))
    }
}

/// The beat-phase meter: the signed error between the two decks, centred means
/// locked (mockup `iphone/05c`'s `pmeter`). The marker sits at the centre when
/// the decks are phase-aligned and swings toward the lagging deck.
private struct PhaseErrorMeter: View {
    /// The signed error in the meter's −1…1 span (positive = A ahead).
    let errorFraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Capsule()
                    .fill(Color.white.opacity(0.10))
                Capsule()
                    .fill(Color.white.opacity(0.5))
                    .frame(width: 2, height: proxy.size.height - 6)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                Capsule()
                    .fill(Color.cyan)
                    .frame(width: 10, height: 12)
                    .position(x: proxy.size.width / 2
                                  + CGFloat(errorFraction) * proxy.size.width / 2,
                              y: proxy.size.height / 2)
            }
        }
        .frame(height: 14)
        .frame(width: 120)
        .accessibilityIdentifier("dj.master.phase")
        .coachGlow(identifier: "dj.master.phase")
    }
}

/// A 44 pt-minimum channel fader (trim gain, §35.4). Unity at the top, full
/// kill at the bottom; the whole 34×64 strip is the drag surface. `identifier`
/// carries the §53.11 accessibility identifier.
private struct ChannelFader: View {
    let label: String
    let value: Float
    var identifier: String?
    let onChanged: (Float) -> Void

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { proxy in
                let height = proxy.size.height
                ZStack(alignment: .bottom) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(Color.white.opacity(0.55))
                        .frame(height: max(6, height * Self.clamp01(CGFloat(value))))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { gesture in
                        let t = Self.clamp01((1 - gesture.location.y / height))
                        onChanged(Float(t))
                    }
                )
            }
            .frame(width: 34, height: 64)
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(width: 44, height: 44, alignment: .top)
        .accessibilityIdentifierIfPresent(identifier)
        .coachGlow(identifier: identifier)
    }

    private static func clamp01(_ value: CGFloat) -> CGFloat {
        max(0, min(1, value))
    }
}

/// Apply a §53.11 accessibility identifier only when one is supplied.
private extension View {
    func accessibilityIdentifierIfPresent(_ identifier: String?) -> some View {
        if let identifier {
            return AnyView(self.accessibilityIdentifier(identifier))
        }
        return AnyView(self)
    }
}

// MARK: - Orientation switch

/// The iPhone performance surface (§42.1): **orientation is the mode switch**.
/// Portrait renders the solo-deck `SoloDeckView`, landscape the twin-deck
/// `TwinDeckView` — both over the **one** `WorkspaceModel` and the one live
/// engine. Rotating mid-playback is a view change only: the container owns the
/// engine lifecycle (begin/end, scene-phase pump pausing, deferred system
/// gestures), so a rotation never stop/starts the engine and changes no engine
/// state (FR-ENG-10, AT-TWIN-1).
///
/// There is no toggle, no setting and no button — the surface follows the
/// device orientation, mapping `verticalSizeClass` (`.compact` = landscape =
/// twin, `.regular` = portrait = solo) onto the model's view-only
/// `compactPosture`.
public struct CompactPerformanceView: View {
    @StateObject private var model: WorkspaceModel
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    /// The review-listen sheet (FR-REC-6, plan 5.12) — presented the moment a
    /// recording finalises, exactly as on the iPad workspace.
    @State private var finishMix: DJMix?
    /// The §41.18 transition coach (plan 5.13, FR-TRANS-6) — free, so its entry
    /// sits outside the Pro gate and is reachable before purchase; when open it
    /// lights the real controls the selected lesson moves.
    @StateObject private var coach = TransitionCoachModel()

    public init(model: WorkspaceModel) {
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        Group {
            switch model.compactPosture {
            case .solo:
                SoloDeckView(model: model, managesLifecycle: false)
            case .twin:
                TwinDeckView(model: model, managesLifecycle: false)
            }
        }
        .overlay {
            // The §41.18 coach — a free "Transitions" pill on both compact
            // postures; opening it floats the dismissible panel over the
            // still-playing surface.
            TransitionCoachAccessory(model: coach)
        }
        .environment(\.coachHighlights,
                      coach.isPresented ? coach.highlightedIdentifiers : [])
        .preferredColorScheme(.dark)
        #if os(iOS)
        .defersSystemGestures(on: .bottom)
        #endif
        .onAppear {
            applyPosture()
            try? model.begin()
        }
        .onDisappear { model.end() }
        .onChange(of: scenePhase) { _, phase in
            model.setPumpPaused(phase != .active)
        }
        .onChange(of: verticalSizeClass) { _, _ in
            applyPosture()
        }
        .onChange(of: model.finishedMix) { _, mix in
            if let mix { finishMix = mix }
        }
        .sheet(item: $finishMix) { mix in
            RecordingFinishView(mix: mix)
                .onDisappear { model.dismissFinishedMix() }
        }
    }

    /// Portrait (`.regular` vertical size class) is the solo-deck posture,
    /// landscape (`.compact`) the twin-deck one (§42.1).
    private func applyPosture() {
        let posture: WorkspaceModel.CompactPosture =
            verticalSizeClass == .compact ? .twin : .solo
        if model.compactPosture != posture {
            model.setPosture(posture)
        }
    }
}
