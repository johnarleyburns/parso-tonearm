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
                .padding(.top, 56).padding(.trailing, 12)
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
                CueButton(model: model, deck: model.focusedDeck, height: 44)

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
func clampUnit(_ value: CGFloat) -> CGFloat {
    max(0, min(1, value))
}
