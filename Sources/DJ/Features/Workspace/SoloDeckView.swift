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

    public init(model: WorkspaceModel) {
        _model = StateObject(wrappedValue: model)
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
                    lockChip
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
    }

    /// The §42.6 readout band: thermal state, granted buffer and render load
    /// sit inline because on a phone there is no menu bar to hide them in.
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
            }
            Spacer()
            Text("CPU \(Int(model.telemetry.renderLoad * 100))%")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
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
    /// (§42.7). The whole strip is a 1:1 relative drag surface.
    private var crossfaderBar: some View {
        VStack(spacing: 6) {
            crossfaderStrip

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
        }
        .frame(height: 44)
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

            // Waveform — the analysis-driven waveform render lands with the
            // deck-prep wiring; this is the honest neutral baseline.
            Capsule()
                .fill(Color.white.opacity(0.06))
                .frame(height: 64)

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

    private var transport: some View {
        HStack(spacing: 7) {
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
            EQGroup(title: "EQ",
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
                               onChanged: { model.setFilter(deck, knob: $0) })
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
    /// mapped by `JogTransport` onto the engine's transport intents, guarded by
    /// `RTGuard.assertRTSafe` (AT-TWIN-4). The transport is created lazily on
    /// the first gesture so an idle jog costs nothing.
    @State private var jogTransport: JogTransport?

    private func jogIntent(_ intent: JogGestureModel.Intent) {
        if jogTransport == nil {
            jogTransport = JogTransport(engine: model.engine, deck: deck)
        }
        jogTransport?.route(intent)
    }

    /// The honest unavailable stem faders until the M5 separator lands
    /// (plan §2.6).
    private var stemsBlock: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Stems")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("unavailable · M5")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(["Vocals", "Drums", "Bass", "Other"], id: \.self) { stem in
                HStack(spacing: 6) {
                    Text(stem)
                        .font(.system(size: 11))
                        .frame(width: 52, alignment: .leading)
                    GeometryReader { proxy in
                        Capsule().fill(Color.white.opacity(0.08))
                            .overlay(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.2))
                                    .frame(width: proxy.size.width * 0.8)
                            }
                    }
                    .frame(height: 4)
                }
            }
        }
    }
}

/// The focused deck's bank set (§42.6 — the compact chip row incl. `Jog`).
private enum SoloBank: String, CaseIterable {
    case stems = "Stems"
    case eq = "EQ"
    case filter = "Filter"
    case cues = "Cues"
    case jog = "Jog"
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

/// The browse-while-performing crate sheet (§42.7, mockup `iphone/05b`): a
/// raised panel ranked against the currently focused deck. Two rules are
/// normative and structural here: both decks stay visible above the sheet,
/// and the sheet may never cover the crossfader — the panel's height is
/// bounded by `WorkspaceModel.crateSheetMaxHeight` and it renders *behind*
/// the always-visible crossfader bar.
private struct CrateSheetView: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.18))
                .frame(width: 38, height: 4)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
                .padding(.bottom, 12)

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gig crate")
                        .font(.system(size: 15, weight: .bold))
                    Text("ranked against DECK \(model.focusedDeck == .a ? "A" : "B") · browse while performing")
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
            }
            .padding(.horizontal, 15)
            .padding(.bottom, 10)

            Divider()

            VStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                Text("Crate rows land with the library browse wiring")
                    .font(.system(size: 12, weight: .semibold))
                Text("It stays clear of the crossfader, so you can keep mixing while you browse")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 28)

            Spacer(minLength: 0)
        }
        .background(Color(red: 0.055, green: 0.075, blue: 0.10))
        .overlay(alignment: .top) { Divider() }
    }
}
