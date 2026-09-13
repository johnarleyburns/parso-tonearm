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
                                deck: Deck) -> CGPoint {
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
