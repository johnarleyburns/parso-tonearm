import SwiftUI

/// The iPad DJ workspace (mockup `ipad/07-dj-workspace.html`, §41.9b) over the
/// single session `WorkspaceModel` (plan 4.6). The §41.9b arrangement is the
/// club-standard one: the two decks' waveforms stack on one shared playhead at
/// the top (§26A.5), and below them each deck column carries the performance
/// controls in their club positions — jog centred with the **tempo fader on the
/// outer edge** (rule 4), **eight pads** under their mode selector (rule 5),
/// and **CUE left of PLAY** at the deck's inner base (rule 3). The centre mixer
/// column is the **per-channel strip** pair (rule 1: TRIM → HI → MID → LOW →
/// FILTER above a vertical channel fader and a CUE button) with the crossfader
/// horizontal and bottom-centre (rule 2).
///
/// The gate is `WorkspaceModel.isDecksEnabled` (App. T.3): free users see the
/// real surface dimmed to ~35%, controls inert, with a single lock chip —
/// nothing is blurred, nothing is hidden (§40.4, §41.15). The bottom system
/// gesture is deferred so the crossfader surface stays reachable
/// (§42.7b). Screen auto-lock scoping (§34A.6) is applied by the model from
/// telemetry, never from a view's lifetime.
///
/// Accessibility identifiers follow §53.11 (`dj.deck.<a|b>.<play|cue|filter|
/// fader>`, `dj.deck.<a|b>.eq.<low|mid|high>`, `dj.mixer.crossfader`,
/// `dj.fx.echo`, `dj.master.bar`) — part of each control's contract, not test
/// scaffolding (plan decision 27).
public struct WorkspaceView: View {
    @StateObject private var model: WorkspaceModel
    @Environment(\.scenePhase) private var scenePhase

    /// The per-deck `JogTransport` for the §41.9b jog — created lazily on the
    /// first intent so an idle module costs nothing (the compact surface
    /// convention).
    @State private var jogATransport: JogTransport?
    @State private var jogBTransport: JogTransport?
    /// The contextual paywall sheet (mockup `ipad/13b`, plan 4.13) — presented
    /// only when the user taps the lock chip (FR-STORE-5, §40.4).
    @State private var showingPaywall = false
    /// The review-listen sheet (FR-REC-6, plan 5.12): presented the moment a
    /// recording finalises (`model.finishedMix`), cleared on dismiss.
    @State private var finishMix: DJMix?
    /// The §41.18 transition coach (plan 5.13, FR-TRANS-6) — **free tier**, so
    /// its entry sits outside the Pro gate's dimmed surface and is reachable
    /// before purchase. When open, the workspace lights the real controls the
    /// selected lesson moves (§41.18).
    @StateObject private var coach = TransitionCoachModel()

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
        .overlay {
            // The §41.18 coach: a free, always-tappable "Transitions" pill and,
            // when open, the dismissible panel over the still-playing surface.
            TransitionCoachAccessory(model: coach)
        }
        // NFR-REL-2: a stopped graph makes every readout below false at once.
        .engineStoppedBanner(model)
        .environment(\.coachHighlights,
                      coach.isPresented ? coach.highlightedIdentifiers : [])
        .preferredColorScheme(.dark)
        #if os(iOS)
        .defersSystemGestures(on: .bottom)
        #endif
        .onAppear { try? model.begin() }
        .onDisappear { model.end() }
        .onChange(of: scenePhase) { _, phase in
            model.setPumpPaused(phase != .active)
        }
        .onChange(of: model.finishedMix) { _, mix in
            if let mix { finishMix = mix }
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView(model: PaywallModel(store: model.store))
        }
        .sheet(item: $finishMix) { mix in
            RecordingFinishView(mix: mix)
                .onDisappear { model.dismissFinishedMix() }
        }
    }

    private var workspace: some View {
        VStack(spacing: WorkspaceModel.ModuleGeometry.columnGap) {
            WaveformRegion(model: model)
            HStack(spacing: WorkspaceModel.ModuleGeometry.columnGap) {
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
        }
        .padding(WorkspaceModel.ModuleGeometry.outerPadding)
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
}

// MARK: - Shared waveform region

/// The §26A.5 shared waveform display (mockup `ipad/07` rows 1–2): each deck's
/// **full-track overview + phrase ribbon** side by side (view 1), with the two
/// decks' **detail waveforms stacked on ONE shared playhead** beneath (view 2)
/// — each strip scrolls under its own fixed centre line, so a synced pair
/// shows coincident grids. All drawn from the persisted-analysis render model
/// (FR-WAVE-1); the live playheads come from telemetry each frame.
private struct WaveformRegion: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: WorkspaceModel.ModuleGeometry.columnGap) {
                overviewColumn(deck: .a)
                overviewColumn(deck: .b)
            }
            VStack(spacing: 2) {
                detailRow(deck: .a)
                detailRow(deck: .b)
            }
        }
    }

    private func overviewColumn(deck: PerformanceEngine.Deck) -> some View {
        let waveform = model.waveform(for: deck)
        let playhead = deck == .a ? model.telemetry.deckA.playheadSample
                                  : model.telemetry.deckB.playheadSample
        return VStack(spacing: 2) {
            PhraseRibbon(model: waveform,
                         windowStart: 0,
                         visibleSamples: Double(waveform?.durationSamples ?? 1),
                         halveLabels: WaveformThermal.current.degradesRendering)
                .frame(height: 12)
            OverviewStrip(model: waveform, playhead: playhead) { sample in
                model.seek(deck, toSample: sample, quantized: true)
            }
            .frame(height: 18)
        }
        .frame(maxWidth: .infinity)
    }

    private func detailRow(deck: PerformanceEngine.Deck) -> some View {
        let waveform = model.waveform(for: deck)
        let grid = waveform?.grid
        let playhead = deck == .a ? model.telemetry.deckA.playheadSample
                                  : model.telemetry.deckB.playheadSample
        let visibleSamples: Double = grid.map { 8 * $0.samplesPerBar } ?? 1
        let windowStart: Int64 = grid.map { grid in
            max(0, Int64(Double(playhead) - visibleSamples / 2))
        } ?? 0
        return HStack(spacing: 5) {
            Text(deck == .a ? "A" : "B")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(deck == .a ? .white : Color.cyan.opacity(0.9))
                .frame(width: 12)
            WaveformDetailView(
                model: waveform,
                windowStart: windowStart,
                visibleSamples: visibleSamples,
                playhead: playhead,
                emptyTitle: model.hasLoadedTrack(deck) ? "Not analysed yet" : "Load a track",
                emptyMessage: model.hasLoadedTrack(deck) ? "Analyse to draw the waveform here"
                                                         : "Pick a track from the queue")
        }
        .frame(height: 30)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Deck column

/// One deck's §41.9b column: header (DECK / MASTER / SYNCED + the queue
/// button), title + BPM/key readout, then the club performance block — the
/// **tempo fader on the outer edge** beside the **jog centred** (rule 4), the
/// pad **mode selector** above **eight pads** (rule 5), and **CUE left of
/// PLAY** at the deck's inner base (rule 3) — and beneath it the module slot.
/// The deck's queue (§41.9c) raises as a browse sheet from the header button,
/// so the performance column keeps its club geometry (the compact crate-sheet
/// pattern; mockup `ipad/07` shows no queue panel in the deck column).
private struct DeckColumnView: View {
    @ObservedObject var model: WorkspaceModel
    let deck: PerformanceEngine.Deck
    let isMaster: Bool
    let onJogIntent: (JogGestureModel.Intent) -> Void

    @State private var showingQueue = false

    private var telemetryDeck: EngineTelemetry.Deck {
        deck == .a ? model.telemetry.deckA : model.telemetry.deckB
    }

    private var synced: Bool { model.isSynced(deck) }

    private var deckID: String { deck == .a ? "a" : "b" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(deck == .a ? "DECK A" : "DECK B")
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.08), in: Capsule())
                if isMaster {
                    Pill("MASTER", color: .green)
                } else if synced {
                    Pill("SYNCED", color: .cyan)
                }
                Spacer()
                Button {
                    showingQueue = true
                } label: {
                    Label("Queue", systemImage: "square.stack")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.07), in: Capsule())
                }
                .buttonStyle(.plain)
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

            performanceBlock

            transport

            Divider()

            // The §41.9a module slot: the deck's swappable lower module,
            // remembered per deck, default STEMS. It is a layout member of
            // this column only — never an overlay, so no shared control can be
            // occluded (AT-TWIN-2).
            DeckModuleSlotView(model: model, deck: deck, onJogIntent: onJogIntent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.03)))
        .sheet(isPresented: $showingQueue) {
            // The §41.9c per-deck queue as a browse sheet — the source picker
            // at its head (FR-ENG-13), one-gesture loads through the FR-LIB-8
            // gate, nothing auto-advances (§41.9c).
            DeckQueuePanel(model: model, deck: deck)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    /// The §41.9b performance block: tempo fader on the outer edge + jog
    /// centred (rule 4), then the mode selector above eight pads (rule 5). The
    /// jog is the plain §40.7 platter (248 pt) — the mockup's club column puts
    /// the jog beside the tempo fader without the optional ± bend columns, and
    /// the bend-column jog module stays available in the module slot's JOG
    /// option. The platter shows its VINYL/CDJ mode readout; the mode toggle
    /// rides under the tempo fader so the outer edge is one control column.
    /// The §41.9a jog sensitivity sits under the pads — the mixer column is
    /// now the two channel strips, so the per-deck faders live with the jog.
    private var performanceBlock: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                if deck == .a {
                    TempoFader(model: model, deck: deck)
                    JogView(model: model, deck: deck,
                            onIntent: onJogIntent,
                            mode: model.jogMode(deck),
                            sensitivity: model.jogSensitivity(deck),
                            showsModeReadout: true)
                        .frame(width: WorkspaceModel.ModuleGeometry.jogSize,
                               height: WorkspaceModel.ModuleGeometry.jogSize)
                } else {
                    JogView(model: model, deck: deck,
                            onIntent: onJogIntent,
                            mode: model.jogMode(deck),
                            sensitivity: model.jogSensitivity(deck),
                            showsModeReadout: true)
                        .frame(width: WorkspaceModel.ModuleGeometry.jogSize,
                               height: WorkspaceModel.ModuleGeometry.jogSize)
                    TempoFader(model: model, deck: deck)
                }
            }
            PadBlock(model: model, deck: deck)
            JogSensitivitySlider(value: model.jogSensitivity(deck),
                                 onChanged: { model.setJogSensitivity(deck, value: $0) })
        }
    }

    /// The §41.9b transport row at the deck's inner base (rule 3): **CUE left
    /// of PLAY**, then SYNC (tap = beat, hold = downbeat) and the LOOP
    /// release-to-commit flyout. Deck B mirrors horizontally — the row is
    /// laid out identically but the deck column sits on the right, so PLAY is
    /// nearest the mixer on both decks.
    private var transport: some View {
        HStack(spacing: 8) {
            TransportButton(title: "CUE",
                            emphasized: false,
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
            LoopReleaseToCommitButton(model: model, deck: deck)
        }
    }
}

/// The §41.9b tempo fader on the deck's outer edge (rule 4): a vertical fader
/// over the ±8% `ClubGeometry.tempoFaderRange`, fader-up = faster. It sets the
/// deck's rate through the session VM (`WorkspaceModel.setTempo`), so the
/// position mirrors the model state shared by every surface. The VINYL/CDJ
/// platter mode (§41.9a) rides below the fader so the deck's outer edge is one
/// control column; the mode is shown inside the platter and toggled here.
private struct TempoFader: View {
    @ObservedObject var model: WorkspaceModel
    let deck: PerformanceEngine.Deck

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { proxy in
                let height = proxy.size.height
                let t = CGFloat((model.tempo(deck) - WorkspaceModel.ClubGeometry.tempoFaderRange.lowerBound)
                                / (WorkspaceModel.ClubGeometry.tempoFaderRange.upperBound
                                   - WorkspaceModel.ClubGeometry.tempoFaderRange.lowerBound))
                ZStack(alignment: .bottom) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule()
                        .fill(Color.accentColor.opacity(0.85))
                        .frame(width: 3)
                        .frame(height: max(8, height * t))
                    Capsule()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 20, height: 4)
                        .offset(y: -(max(8, height * t)) + 2)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { gesture in
                        let fill = min(1, max(0, 1 - gesture.location.y / height))
                        let fraction = -0.08 + 0.16 * Double(fill)
                        model.setTempo(deck, fraction: fraction)
                    }
                )
            }
            Text(String(format: "%+.1f%%", model.tempo(deck) * 100))
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("TEMPO")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
            modeToggle
        }
        .frame(width: WorkspaceModel.ModuleGeometry.tempoFaderWidth)
    }

    /// The VINYL/CDJ platter mode (§41.9a) — view-only, remembered per deck.
    private var modeToggle: some View {
        VStack(spacing: 3) {
            ForEach([JogGestureModel.JogMode.vinyl, .cdj], id: \.self) { mode in
                Button {
                    model.setJogMode(mode, deck: deck)
                } label: {
                    Text(mode == .vinyl ? "VINYL" : "CDJ")
                        .font(.system(size: 7, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                        .background(
                            model.jogMode(deck) == mode
                                ? (mode == .vinyl ? Color.green : Color.cyan).opacity(0.22)
                                : Color.white.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .foregroundStyle(
                            model.jogMode(deck) == mode
                                ? (mode == .vinyl ? Color.green : Color.cyan)
                                : Color.secondary
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A horizontal fader for the §41.9a per-deck jog sensitivity (§40.7.4,
/// 0.5–2.0). Maps the value linearly onto the track; the whole strip is the
/// drag surface. Compact so it sits under the §41.9b pad block without
/// disturbing the club geometry.
private struct JogSensitivitySlider: View {
    let value: Double
    let onChanged: (Double) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("JOG")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
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
            Text(String(format: "%.1f", value))
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 22)
        }
    }

    private static func clampUnit(_ value: CGFloat) -> CGFloat {
        max(0, min(1, value))
    }
}

/// The §41.9b pad block (rule 5): the `HOT CUE · PAD FX · BEAT JUMP · SAMPLER`
/// mode selector immediately above **eight** pads in two rows of four. The pads
/// render the honest placeholder state — the pad *features* (hot cues, pad FX,
/// beat jump, sampler) land with their own commits; the block's job in 5.4 is
/// the club-standard geometry (eight, under the selector, ≥ 44 pt).
private struct PadBlock: View {
    @ObservedObject var model: WorkspaceModel
    let deck: PerformanceEngine.Deck

    @State private var modeIndex = 0

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(Array(WorkspaceModel.ClubGeometry.padModes.enumerated()), id: \.offset) { index, mode in
                    Button {
                        modeIndex = index
                    } label: {
                        Text(mode)
                            .font(.system(size: 9, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                            .background(
                                modeIndex == index ? Color.accentColor.opacity(0.28)
                                                   : Color.white.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                            .foregroundStyle(modeIndex == index ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(height: 34)

            ForEach(0..<WorkspaceModel.ClubGeometry.padRows, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(0..<WorkspaceModel.ClubGeometry.padColumns, id: \.self) { col in
                        let index = row * WorkspaceModel.ClubGeometry.padColumns + col
                        Text(padLabel(index: index))
                            .font(.system(size: 12, weight: .bold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private func padLabel(index: Int) -> String {
        // Honest placeholder until the pad features land: the pad row carries
        // the mode's implied labels (A–H hot cues) without pretending the
        // engine is wired.
        String(UnicodeScalar(("A" as UnicodeScalar).value + UInt32(index)) ?? "A")
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
                .frame(maxHeight: 100)
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
/// compact solo/twin-deck surfaces (plan 4.7). `identifier` carries the §53.11
/// accessibility identifier when the control is part of a performance surface
/// (plan decision 27).
struct TransportButton: View {
    let title: String
    var emphasized = false
    var identifier: String?
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
        .accessibilityIdentifierIfPresent(identifier)
        .coachGlow(identifier: identifier)
    }
}

/// Apply a §53.11 accessibility identifier only when one is supplied — the
/// non-performance controls (SYNC, LOOP, bank chips) keep SwiftUI's default
/// identity instead of carrying an empty identifier.
private extension View {
    func accessibilityIdentifierIfPresent(_ identifier: String?) -> some View {
        if let identifier {
            return AnyView(self.accessibilityIdentifier(identifier))
        }
        return AnyView(self)
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

/// The centre mixer column (§41.9b): the two **per-channel vertical strips**
/// side by side (rule 1 — TRIM → HI → MID → LOW → FILTER above a vertical
/// channel fader and a CUE button), the crossfader **horizontal and
/// bottom-centre** (rule 2), the §35A Beat FX block below it (rule 7, honest
/// unavailable until the echo engine lands in 5.5), and the master/limiter/
/// thermal readouts. Width is the §41.9b 320 pt.
private struct MixerColumnView: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("MASTER")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                masterBarReadout
            }

            masterMeter

            recordControl

            HStack(alignment: .top, spacing: 6) {
                ChannelStripView(model: model, deck: .a)
                ChannelStripView(model: model, deck: .b)
            }

            crossfader

            BeatFXBlock(model: model)

            Divider()

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
                Text("Limiter").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(limiterText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(limiterColor)
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
        .frame(width: WorkspaceModel.ModuleGeometry.mixerColumnWidth)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.03)))
    }

    /// The `dj.master.bar` readout (§53.11): the master clock's bar:beat,
    /// which the regression driver polls to schedule gestures on phrase
    /// boundaries. Part of the control contract — VoiceOver needs it too.
    private var masterBarReadout: some View {
        Group {
            if let barBeat = model.masterBarBeat {
                Text("BAR \(barBeat.bar) · \(barBeat.beat)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .accessibilityLabel("\(barBeat.bar):\(barBeat.beat)")
                    .accessibilityIdentifier("dj.master.bar")
            } else {
                Text("BAR —")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
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

    /// The §37.2 record control (mockup `ipad/07`'s "■ Stop & save ·
    /// 00:18:42", plan 5.10, decision 14). The record/elapsed chip is session
    /// VM state shared across every performance surface; the engine's tap +
    /// encoder start on tap-to-record and finalize on tap-to-stop. Carries the
    /// `dj.transport.record` identifier the regression suite drives (§53.11,
    /// dj-regression-suite.md 5.10).
    private var recordControl: some View {
        Button {
            model.toggleRecording()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.isRecording ? Color.red : Color.white.opacity(0.25))
                    .frame(width: 9, height: 9)
                if model.isRecording {
                    Text("Stop & save · \(Self.elapsedText(model.recordingElapsed))")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                } else {
                    Text("REC")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("dj.transport.record")
    }

    private static func elapsedText(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// The crossfader, horizontal and bottom-centre (§41.9b rule 2) — never in
    /// a drawer, never behind a mode. Carries the `dj.mixer.crossfader`
    /// identifier.
    private var crossfader: some View {
        VStack(spacing: 4) {
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
                        let u = Self.clampUnit(value.location.x / width)
                        model.setCrossfader(Float(u) * 2 - 1, curve: model.crossfaderCurve)
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

    private static func clampUnit(_ value: CGFloat) -> CGFloat {
        max(0, min(1, value))
    }
}

/// The §35A Beat FX block below the crossfader (§41.9b rule 7): the post-fader
/// beat-synced **ECHO** — the one Beat FX the five transitions require (plan
/// 5.5, FR-TRANS-4). Channel selector + ON toggle, the five beat lengths and a
/// depth slider; the block is always visible on the tablet, so no drawer or
/// flyout is needed here (the §42.7c compact treatment owns those). The ON
/// button carries the `dj.fx.echo` identifier the regression suite drives.
private struct BeatFXBlock: View {
    @ObservedObject var model: WorkspaceModel

    @State private var echoDeck: PerformanceEngine.Deck = .a

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("BEAT FX")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                channelSelector
            }

            HStack(spacing: 5) {
                ForEach(Array(WorkspaceModel.ClubGeometry.echoBeats.enumerated()), id: \.offset) { _, beats in
                    Button {
                        model.setEchoBeats(echoDeck, beats: beats)
                    } label: {
                        Text(echoLabel(beats))
                            .font(.system(size: 9, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 26)
                            .background(
                                model.echoBeats(echoDeck) == beats
                                    ? Color.accentColor.opacity(0.28)
                                    : Color.white.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(
                                model.echoBeats(echoDeck) == beats
                                    ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Text("DEPTH")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                GeometryReader { proxy in
                    let width = proxy.size.width
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.10))
                            .frame(height: 5)
                        Capsule()
                            .fill(Color.accentColor.opacity(0.9))
                            .frame(width: max(4, width * CGFloat(model.echoDepth(echoDeck))), height: 5)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0).onChanged { value in
                            model.setEchoDepth(echoDeck,
                                               depth: Float(Self.clampUnit(value.location.x / width)))
                        }
                    )
                }
                .frame(height: 5)
                onToggle
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.02)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    /// The per-channel selector (mockup `ipad/07`'s "ECHO · A") — the echo is
    /// post-fader and per channel (§35A.1), so the block names which strip it
    /// is sending.
    private var channelSelector: some View {
        HStack(spacing: 4) {
            ForEach([PerformanceEngine.Deck.a, .b], id: \.self) { deck in
                Button {
                    echoDeck = deck
                } label: {
                    Text(deck == .a ? "A" : "B")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 26, height: 22)
                        .background(
                            echoDeck == deck ? Color.accentColor.opacity(0.28)
                                             : Color.white.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(echoDeck == deck ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The ON/OFF toggle — the §35A.2 momentary-or-latched on switch. Carries
    /// the `dj.fx.echo` identifier the regression suite targets (§53.11).
    private var onToggle: some View {
        let on = model.echoEnabled(echoDeck)
        return Button {
            model.setEchoEnabled(echoDeck, enabled: !on)
        } label: {
            Text(on ? "ON" : "OFF")
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(
                    on ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(on ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("dj.fx.echo")
        .coachGlow(identifier: "dj.fx.echo")
    }

    private func echoLabel(_ beats: Double) -> String {
        beats < 1 ? String(format: "1/%d", Int(1 / beats)) : "\(Int(beats))"
    }

    private static func clampUnit(_ value: CGFloat) -> CGFloat {
        max(0, min(1, value))
    }
}

/// One §41.9b channel strip: TRIM (compact) → HI → MID → LOW → FILTER above a
/// vertical channel fader and a CUE button (rule 1). Each control carries its
/// §53.11 accessibility identifier.
private struct ChannelStripView: View {
    @ObservedObject var model: WorkspaceModel
    let deck: PerformanceEngine.Deck

    private var name: String { deck == .a ? "a" : "b" }

    private var eq: (low: Float, mid: Float, high: Float) {
        deck == .a ? (model.eqALow, model.eqAMid, model.eqAHigh)
                   : (model.eqBLow, model.eqBMid, model.eqBHigh)
    }

    private var filter: Float { deck == .a ? model.filterA : model.filterB }
    private var channelGain: Float { deck == .a ? model.channelA : model.channelB }

    var body: some View {
        VStack(spacing: 3) {
            Text(deck == .a ? "CH A" : "CH B")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(deck == .a ? .purple : .cyan)

            // TRIM — the compact control at the strip head (§41.9b geometry).
            Text("TRIM")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
            TrimKnob(value: channelGain) {
                model.setChannelFader(deck, gain: $0)
            }

            EQKnob(label: "HI", value: eq.high,
                   identifier: "dj.deck.\(name).eq.high") {
                model.setEQKnobs(deck, low: eq.low, mid: eq.mid, high: $0)
            }
            EQKnob(label: "MID", value: eq.mid,
                   identifier: "dj.deck.\(name).eq.mid") {
                model.setEQKnobs(deck, low: eq.low, mid: $0, high: eq.high)
            }
            EQKnob(label: "LOW", value: eq.low,
                   identifier: "dj.deck.\(name).eq.low") {
                model.setEQKnobs(deck, low: $0, mid: eq.mid, high: eq.high)
            }

            // FILTER — a knob in the strip (§41.9b rule 6), not a slider.
            EQKnob(label: "FILTER", value: filter,
                   identifier: "dj.deck.\(name).filter") {
                model.setFilter(deck, knob: $0)
            }

            VerticalSlider(value: channelGain,
                           identifier: "dj.deck.\(name).fader") {
                model.setChannelFader(deck, gain: $0)
            }
            .frame(height: 70)

            Button {
                model.cue(deck)
            } label: {
                Text("CUE")
                    .font(.system(size: 10, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("dj.deck.\(name).cue")
            .simultaneousGesture(
                DragGesture(minimumDistance: 0).onEnded { _ in model.releaseCue(deck) }
            )
        }
        .frame(maxWidth: .infinity)
    }
}

/// The compact TRIM control at the channel strip's head (§41.9b geometry —
/// five full knobs would exceed the column's height, so the one control not
/// used *during* a transition renders compact). Maps the channel fader gain.
private struct TrimKnob: View {
    let value: Float
    let onChanged: (Float) -> Void

    @State private var dragStart: Float?

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.08))
            Circle()
                .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.white.opacity(0.9))
                .frame(width: 2, height: 7)
                .offset(y: -10)
                .rotationEffect(.degrees(Double(value) * 90))
        }
        .frame(width: 28, height: 28)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    if dragStart == nil { dragStart = value }
                    let start = dragStart ?? value
                    let delta = Float(gesture.translation.height) / 80
                    let clamped = min(1, max(0, start - delta))
                    onChanged(clamped)
                }
                .onEnded { _ in dragStart = nil }
        )
    }
}

/// A deck's three EQ knobs (§41.9b — the compact surfaces' EQ bank keeps the
/// three-in-a-row form where the full channel strip does not fit). The knobs
/// carry the §53.11 per-band identifiers for the deck they belong to.
struct EQGroup: View {
    let title: String
    let deckID: String
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
                EQKnob(label: "HI", value: high,
                       identifier: "dj.deck.\(deckID).eq.high") { onChanged(low, mid, $0) }
                EQKnob(label: "MID", value: mid,
                       identifier: "dj.deck.\(deckID).eq.mid") { onChanged(low, $0, high) }
                EQKnob(label: "LOW", value: low,
                       identifier: "dj.deck.\(deckID).eq.low") { onChanged($0, mid, high) }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// A 44 pt minimum rotary knob driven by a vertical drag. The dial renders
/// −1 … +1 across ±135°; the centre detent (kill→unity→+6 dB) is §35.2's
/// mapping — the knob itself is linear knob position. `identifier` carries the
/// §53.11 accessibility identifier on performance surfaces.
struct EQKnob: View {
    let label: String
    let value: Float
    var identifier: String?
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
        .performanceControl(identifier, label: label, value: value)
        .coachGlow(identifier: identifier)
    }
}

/// A vertical drag fader for the channel strips (§35.4) and the compact
/// surface's filter bank (plan 4.7). `identifier` carries the §53.11
/// accessibility identifier on performance surfaces.
struct VerticalSlider: View {
    let value: Float
    var identifier: String?
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
        .performanceControl(identifier, label: "Fader", value: value)
        .coachGlow(identifier: identifier)
    }
}

/// The beat-phase meter: the master's downbeat phase as four beat segments
/// (mockup `ipad/07`'s centre-column readout). Carries the §53.11
/// `dj.master.phase` identifier so the §41.18 coach can light it as the Blend
/// transition's beat-phase role (§35B row 5).
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
        .accessibilityIdentifier("dj.master.phase")
        .coachGlow(identifier: "dj.master.phase")
    }
}

/// Clamp a value into a closed range.
private func clamp<T: Comparable>(_ minimum: T, _ value: T, _ maximum: T) -> T {
    min(max(value, minimum), maximum)
}


/// One accessibility element per continuous performance control, carrying its
/// §53.11 identifier **and its current position**. Shared by all three
/// performance surfaces.
///
/// Two things depend on it. VoiceOver otherwise reads a knob that says nothing
/// about where it is set. And the DJ regression lanes can tell a gesture that
/// moved a control from one that landed on scenery: a synthesised drag on a
/// control that is present but unreachable is silent, and with no value to
/// compare it stays silent all the way to a missing transition signature in the
/// recording, hours later (§53.5).
///
/// `children: .ignore` is what makes it *one* element. A decorated control
/// otherwise scatters its identifier across every label inside it, and a driver
/// that takes the first match ends up dragging within a 7-point letter "A".
extension View {
    func performanceControl(_ identifier: String?, label: String, value: Float) -> some View {
        let element = accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(String(format: "%.3f", value))
        if let identifier {
            return AnyView(element.accessibilityIdentifier(identifier))
        }
        return AnyView(element)
    }
}
