import SwiftUI

/// The jog surface (plan 4.8; §40.7.5, §40.7.7). Renders the platter at
/// display cadence off the telemetry pump — the position marker (this deck's
/// beat phase) and the **phase ghost** (the other deck's beat phase) are both
/// drawn on the same dial, so aligning the two dots is beatmatching without
/// headphones. The platter is driven by a pure `JogGestureModel`; the emitted
/// `Intent`s go to the owner's `onIntent` closure, and Core Haptics detents
/// (§40.7.4) fire a light transient per master-clock beat and a heavier one
/// per downbeat while the platter is held.
///
/// The jog never touches the engine directly and never executes on the render
/// thread (FR-ENG-11): the intent routing that reaches the transport is
/// guarded by `RTGuard.assertRTSafe` (§46.3, AT-TWIN-4).
///
/// The §41.9a iPad jog module (plan 4.11) drives the same surface at 248 pt:
/// `mode` selects the §40.7.3 platter action (vinyl = scratch, CDJ = nudge —
/// shown inside the platter, so the mode is never a guess), `sensitivity` is
/// the per-deck §40.7.4 value the mixer column fader sets, and
/// `showsModeReadout` swaps the minimal phone hub for the iPad's bar/beat +
/// mode readout that compensates for iPad's lack of a Taptic Engine.
public struct JogView: View {
    @ObservedObject var model: WorkspaceModel
    let deck: PerformanceEngine.Deck
    let onIntent: (JogGestureModel.Intent) -> Void
    let mode: JogGestureModel.JogMode
    let sensitivity: Double
    let showsModeReadout: Bool

    @State private var gesture = JogGestureModel()
    @State private var detents = JogDetentDriver()

    public init(model: WorkspaceModel, deck: PerformanceEngine.Deck,
                onIntent: @escaping (JogGestureModel.Intent) -> Void,
                mode: JogGestureModel.JogMode = .vinyl,
                sensitivity: Double = 1.0,
                showsModeReadout: Bool = false) {
        self.model = model
        self.deck = deck
        self.onIntent = onIntent
        self.mode = mode
        self.sensitivity = sensitivity
        self.showsModeReadout = showsModeReadout
    }

    public var body: some View {
        GeometryReader { proxy in
            let center = JogPoint(x: Double(proxy.size.width / 2),
                                  y: Double(proxy.size.height / 2))
            let radius = Double(min(proxy.size.width, proxy.size.height) / 2)
            ZStack {
                platter
                markers(radius: radius)
                readout
            }
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        handleTouch(location: value.location, center: center, radius: radius)
                    }
                    .onEnded { _ in endTouch() }
            )
        }
        .onAppear {
            gesture.jogMode = mode
            gesture.setSensitivity(sensitivity)
        }
        .onChange(of: mode) { _, newValue in gesture.jogMode = newValue }
        .onChange(of: sensitivity) { _, newValue in gesture.setSensitivity(newValue) }
        .onChange(of: model.telemetry) { _, _ in
            detents.update(telemetry: model.telemetry, sampleRate: model.engine.sampleRate)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Gesture → model → intents

    private func handleTouch(location: CGPoint, center: JogPoint, radius: Double) {
        let point = JogPoint(x: Double(location.x), y: Double(location.y))
        let intent = gesture.isTracking
            ? gesture.touchMoved(to: point)
            : gesture.touchDown(at: point, center: center, radius: radius)
        if let intent { handle(intent) }
    }

    private func endTouch() {
        if let intent = gesture.touchUp() { handle(intent) }
    }

    /// The platter arms the beat/downbeat detents; a bend (ring) does not —
    /// §40.7.4's detents are "while the platter is held".
    private func handle(_ intent: JogGestureModel.Intent) {
        switch intent {
        case .hold: detents.isArmed = true
        case .release: detents.isArmed = false
        default: break
        }
        onIntent(intent)
    }

    // MARK: - Rendering (§40.7.5)

    private var thisPhase: Double {
        deck == .a ? model.telemetry.deckA.phase : model.telemetry.deckB.phase
    }

    private var otherPhase: Double {
        deck == .a ? model.telemetry.deckB.phase : model.telemetry.deckA.phase
    }

    /// The platter: outer ring band, the inner platter disc at the §40.7.3
    /// 58% split, and a hub readout showing the bound deck and its beat phase.
    private var platter: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.04))
            Circle()
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            Circle()
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                .padding(JogGestureModel.platterFraction * 0.5)
            Circle()
                .fill(Color.white.opacity(0.02))
                .padding(JogGestureModel.platterFraction * 0.5)
        }
    }

    /// The two beat-phase markers on the same dial (§40.7.5): a white marker
    /// for this deck's position within the beat, and a ghost marker for the
    /// other deck's — aligning the dots is beatmatching.
    private func markers(radius: Double) -> some View {
        let orbit = radius * 0.66
        return ZStack {
            marker(phase: thisPhase, orbit: orbit, color: .white, size: 8)
            marker(phase: otherPhase, orbit: orbit, color: .cyan, size: 8)
                .opacity(0.6)
        }
    }

    private func marker(phase: Double, orbit: Double, color: Color, size: CGFloat) -> some View {
        let angle = phase * 2 * .pi - .pi / 2
        return Circle()
            .fill(color)
            .frame(width: size, height: size)
            .offset(x: CGFloat(cos(angle) * orbit), y: CGFloat(sin(angle) * orbit))
    }

    /// The hub readout. The compact surfaces keep it minimal — the bound deck
    /// and its beat phase; the §41.9a iPad module (`showsModeReadout`) swaps in
    /// the mode pill + BPM + bar/beat readout the larger platter earns (and
    /// that compensates for iPad's lack of a Taptic Engine, §40.7.4).
    private var readout: some View {
        Group {
            if showsModeReadout {
                modeReadout
            } else {
                VStack(spacing: 2) {
                    Text(deck == .a ? "A" : "B")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.0f%%", thisPhase * 100))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var telemetryDeck: EngineTelemetry.Deck {
        deck == .a ? model.telemetry.deckA : model.telemetry.deckB
    }

    private var modeReadout: some View {
        let color: Color = mode == .vinyl ? .green : .cyan
        return VStack(spacing: 3) {
            Text(mode == .vinyl ? "VINYL" : "CDJ")
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(color.opacity(0.18), in: Capsule())
                .foregroundStyle(color)
            Text(String(format: "%.1f", telemetryDeck.bpmEffective))
                .font(.system(size: 23, weight: .bold, design: .monospaced))
                .monospacedDigit()
            Text(barBeatText)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(mode == .vinyl ? "platter = scratch\nring = bend"
                                : "platter = nudge\nring = bend")
                .font(.system(size: 7))
                .foregroundStyle(color.opacity(0.8))
                .multilineTextAlignment(.center)
        }
    }

    private var barBeatText: String {
        let barBeat = Self.barBeat(playheadSample: telemetryDeck.playheadSample,
                                   bpmEffective: telemetryDeck.bpmEffective,
                                   sampleRate: model.engine.sampleRate)
        return String(format: "BAR %d · BEAT %d", barBeat.bar, barBeat.beat)
    }

    /// The deck's bar/beat readout at its playhead, derived from the
    /// telemetry's `playheadSample` and `bpmEffective` (a 4/4 bar, the default
    /// grid). Pure so the iPad hub's readout is pinned off-device.
    public static func barBeat(playheadSample: Int64,
                               bpmEffective: Double,
                               sampleRate: Double) -> (bar: Int, beat: Int) {
        guard bpmEffective > 0, sampleRate > 0 else { return (1, 1) }
        let samplesPerBeat = sampleRate * 60 / bpmEffective
        guard samplesPerBeat > 0 else { return (1, 1) }
        let beatIndex = max(0, playheadSample) / Int64(samplesPerBeat)
        return (Int(beatIndex / 4) + 1, Int(beatIndex % 4) + 1)
    }
}

/// Per-beat / per-downbeat haptic detents while a platter is held (§40.7.4,
/// NFR-A11Y-6). Driven at display cadence off the telemetry pump: a light
/// transient each master-clock beat boundary and a heavier one when the
/// downbeat phase wraps. The master clock is the audible beat while a held
/// deck is paused, so the detents follow the music that is still playing.
/// A no-op on hosts without UIKit (macOS `swift test` host — no Taptic engine).
@MainActor
final class JogDetentDriver {
    var isArmed = false
    private var lastBeatBoundary: Int64?
    private var lastDownbeatPhase = -1.0

    func update(telemetry: EngineTelemetry, sampleRate: Double) {
        guard isArmed else { return }
        let result = Self.decide(sample: telemetry.masterSample,
                                 masterBPM: telemetry.masterBPM,
                                 downbeatPhase: telemetry.downbeatPhase,
                                 sampleRate: sampleRate,
                                 lastBeatBoundary: lastBeatBoundary,
                                 lastDownbeatPhase: lastDownbeatPhase)
        lastBeatBoundary = result.lastBeatBoundary
        lastDownbeatPhase = result.lastDownbeatPhase
        if result.lightBeat { Haptics.beat() }
        if result.heavyDownbeat { Haptics.downbeat() }
    }

    /// Pure per-frame decision (§40.7.4): one light detent at each beat
    /// boundary of the master clock, and a heavy one when the downbeat phase
    /// wraps (the first armed frame seeds the boundary and fires nothing).
    static func decide(sample: Int64, masterBPM: Double, downbeatPhase: Double,
                       sampleRate: Double, lastBeatBoundary: Int64?,
                       lastDownbeatPhase: Double)
        -> (lightBeat: Bool, heavyDownbeat: Bool, lastBeatBoundary: Int64?,
            lastDownbeatPhase: Double) {
        guard masterBPM > 0, sampleRate > 0 else {
            return (false, false, lastBeatBoundary, lastDownbeatPhase)
        }
        let beatPeriod = Int64(sampleRate * 60 / masterBPM)
        guard beatPeriod > 0 else {
            return (false, false, lastBeatBoundary, lastDownbeatPhase)
        }
        guard let boundary = lastBeatBoundary else {
            let seeded = sample - sample % beatPeriod
            return (false, false, seeded, lastDownbeatPhase)
        }
        let elapsed = sample - boundary
        let light = elapsed >= beatPeriod
        let next = boundary + max(elapsed / beatPeriod, 0) * beatPeriod
        let heavy = lastDownbeatPhase >= 0 && downbeatPhase < lastDownbeatPhase
        return (light, heavy, next, downbeatPhase)
    }
}
