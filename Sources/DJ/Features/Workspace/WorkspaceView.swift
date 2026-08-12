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

    private var workspace: some View {
        HStack(spacing: 12) {
            DeckColumnView(model: model, deck: .a, isMaster: true)
            MixerColumnView(model: model)
            DeckColumnView(model: model, deck: .b, isMaster: false)
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
/// readout, waveform strip, transport (CUE · PLAY · SYNC · LOOP), cue pads and
/// the stems block (§41.9). The stems faders render the honest unavailable
/// state until the M5 separator lands (plan §2.6).
private struct DeckColumnView: View {
    @ObservedObject var model: WorkspaceModel
    let deck: PerformanceEngine.Deck
    let isMaster: Bool

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

            // Waveform strip — analysis-driven waveform rendering lands with
            // the deck-prep milestone; this is the honest neutral baseline.
            Capsule()
                .fill(Color.white.opacity(0.06))
                .frame(height: 48)

            transport

            HStack(spacing: 6) {
                ForEach(["A", "B", "C", "D"], id: \.self) { pad in
                    Text(pad)
                        .font(.system(size: 12, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            Divider()

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
                    Text("·")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.03)))
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
