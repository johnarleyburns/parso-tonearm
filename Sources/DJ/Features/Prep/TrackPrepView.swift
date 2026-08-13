import SwiftUI

/// Track preparation (mockup `ipad/06-track-preparation.html`, §41.8) —
/// commit 4.12's grid-correction surface. Pro, except the analysis readout,
/// which is what a free user sees here (FR-PREP-4): the readout row and the
/// "What we heard" panel always render; the grid tools are gated by
/// `TrackPrepModel.isPreparationEnabled` and render locked for free users
/// (§40.4).
///
/// The grid tools are one-thumb per FR-PREP-5: ×2 / ÷2 are buttons, `Nudge`
/// drags the waveform (the haptic clicks per beat), `Set downbeat` taps the
/// waveform. Every gesture commits **once** on release — the model appends a
/// single correction to the authoritative log (§23.3), never a stream.
///
/// The waveform draws the §26A.2 analysis pyramid as its backdrop (persisted
/// analysis, FR-WAVE-1 — never placeholder geometry), with pinch-zoom real
/// over the grid's bar/beat markers, so the prep zoom already works off the
/// analysis + the grid.
public struct TrackPrepView: View {
    @ObservedObject var model: TrackPrepModel

    public init(model: TrackPrepModel) {
        self.model = model
    }

    /// The active one-thumb grid tool (§41.8's selected chip).
    private enum GridTool: Equatable {
        case nudge
        case setDownbeat
    }

    @State private var gridTool: GridTool = .nudge
    /// Bars visible across the waveform at the current zoom (pinch changes it).
    @State private var visibleBars: CGFloat = 16
    /// The live drag preview offset, in samples (committed once on release).
    @State private var nudgePreviewSamples: Int64 = 0

    private var zoomText: String {
        "1:\(max(1, Int(visibleBars / 4)))"
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 11) {
                header
                readoutRow
                gridToolbar
                waveformCard
                cardsGrid
            }
            .padding(13)
        }
        .background(Color.black.ignoresSafeArea())
        .task { await model.refresh() }
        .onDisappear { model.resetTempoTap() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            if model.isPreparationEnabled {
                Pill("PRO", color: .orange)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot?.title ?? "Track")
                    .font(.system(size: 20, weight: .bold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(zoomText)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.08), in: Capsule())
            Button("Preview") { model.onPreview?() }
                .font(.system(size: 13, weight: .semibold))
                .buttonStyle(.bordered)
            Button("Load to Deck") {
                if let snapshot {
                    model.onLoadToDeck?(snapshot)
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .buttonStyle(.borderedProminent)
        }
    }

    private var subtitle: String {
        guard let snapshot else { return "" }
        var parts = [snapshot.artistNames]
        if let codec = snapshot.codec, !codec.isEmpty {
            parts.append(codec)
        }
        if let duration = snapshot.durationSec, duration > 0 {
            parts.append(String(format: "%.1f:%.0f", duration / 60, duration.truncatingRemainder(dividingBy: 60)))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Analysis readout (free, FR-PREP-4)

    private var readoutRow: some View {
        HStack(spacing: 9) {
            ReadoutPill(title: "BPM", value: bpmText)
            ReadoutPill(title: "KEY", value: keyText)
            ReadoutPill(title: "LUFS", value: lufsText)
            ReadoutPill(title: "DR", value: drText)
            if let confidence = snapshot?.gridConfidence {
                ReadoutPill(title: "GRID", value: String(format: "%.2f", confidence),
                            accent: confidence >= 0.9 ? .green : .orange)
            }
        }
    }

    private var bpmText: String {
        guard let bpm = snapshot?.bpm else { return "—" }
        return String(format: "%.2f", bpm)
    }

    private var keyText: String {
        guard let snapshot else { return "—" }
        if let camelot = snapshot.camelot, !camelot.isEmpty {
            return snapshot.musicalKey.map { "\(camelot) · \($0)" } ?? camelot
        }
        return snapshot.musicalKey ?? "—"
    }

    private var lufsText: String {
        guard let lufs = snapshot?.lufs else { return "—" }
        return String(format: "%.1f", lufs)
    }

    private var drText: String {
        guard let dr = snapshot?.dynamicRangeDB else { return "—" }
        return String(format: "%.0f", dr)
    }

    // MARK: - Grid tools (gated by .preparation)

    private var gridToolbar: some View {
        HStack(spacing: 7) {
            if !model.isPreparationEnabled {
                Pill("PRO", color: .orange)
                Text("Grid tools are a Pro capability — everything above is free")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
            } else {
                GridToolButton("×2") { Task { await model.doubleBPM() } }
                GridToolButton("÷2") { Task { await model.halveBPM() } }
                GridToolButton("Nudge", selected: gridTool == .nudge) {
                    gridTool = .nudge
                }
                GridToolButton("Set downbeat", selected: gridTool == .setDownbeat) {
                    gridTool = .setDownbeat
                }
                GridToolButton("Undo", enabled: (snapshot?.corrections.isEmpty ?? true) == false) {
                    Task { await model.undoLast() }
                }
                Spacer()
            }
        }
        .opacity(model.isPreparationEnabled ? 1 : 0.6)
    }

    // MARK: - Waveform + grid

    private var waveformCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Grid")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let snapshot {
                    Text(firstDownbeatText(snapshot))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(correctionsText(snapshot))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            if let snapshot, let grid = snapshot.grid {
                // §26A.4: the phrase ribbon runs above the waveform — labelled
                // spans in bars, the next drop visible before it arrives.
                PhraseRibbon(model: model.waveform,
                             windowStart: 0,
                             visibleSamples: Double(model.waveform?.durationSamples ?? 1),
                             halveLabels: WaveformThermal.current.degradesRendering)
                    .frame(height: 12)
                waveform(for: snapshot, grid: grid)
            } else {
                Capsule()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 64)
                    .overlay(
                        Text("No beat grid yet — analysis will draw it here")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    /// The waveform over the grid's real bar/beat markers: the §26A.2 analysis
    /// pyramid is the backdrop (persisted analysis, never synthetic geometry —
    /// FR-WAVE-1, §26A.1), the grid ticks/bar numbers from the authoritative
    /// grid draw on top, and pinch zooms `visibleBars`; a Nudge drag previews a
    /// sample offset and commits once on release; Set downbeat taps a sample
    /// onto the grid.
    private func waveform(for snapshot: TrackPrepSnapshot, grid: DeckGrid) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let samplesPerBar = max(grid.samplesPerBar, 1)
            let visibleSamples = Double(visibleBars) * samplesPerBar
            let samplesPerPoint = max(visibleSamples / max(width, 1), 1)
            let viewStart = grid.referenceSample - 4 * samplesPerBar
            let shiftedStart = viewStart + Double(nudgePreviewSamples)

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.06))

                // The §26A.2 analysis pyramid as the backdrop — the audio is
                // drawn from the persisted band-split pyramid, never re-read
                // at draw time (§26A.1). The grid markers and gestures draw
                // over it; unanalysed tracks keep the neutral background.
                WaveformBinsCanvas(model: model.waveform,
                                   windowStart: Int64(viewStart),
                                   samplesPerPoint: samplesPerPoint)

                // Bar ticks + bar labels from the authoritative grid.
                Canvas { context, size in
                    let barIndexStart = Int(floor((viewStart - grid.referenceSample) / samplesPerBar))
                    let barIndexEnd = Int(ceil((viewStart + Double(visibleSamples) - grid.referenceSample) / samplesPerBar))
                    for k in barIndexStart...barIndexEnd {
                        let sample = grid.referenceSample + Double(k) * samplesPerBar
                        let x = (sample - shiftedStart) / samplesPerPoint
                        guard x >= 0 && x <= size.width else { continue }
                        let isDownbeat = ((k % grid.beatsPerBar) + grid.beatsPerBar) % grid.beatsPerBar == 0
                        var path = Path()
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                        context.stroke(path,
                                       with: .color(isDownbeat ? .orange.opacity(0.8) : .white.opacity(0.25)),
                                       lineWidth: isDownbeat ? 1.5 : 0.75)
                        if isDownbeat {
                            let label = context.resolve(Text("\(k / grid.beatsPerBar + 1)")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.55)))
                            context.draw(label, at: CGPoint(x: x + 2, y: 3), anchor: .topLeading)
                        }
                    }
                }

                if !model.isPreparationEnabled {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.35))
                    VStack(spacing: 6) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.orange)
                        Text("Grid tools are Pro")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(model.isPreparationEnabled ? gridGesture(width: width, samplesPerPoint: samplesPerPoint) : nil)
        }
        .frame(height: 96)
        .clipped()
    }

    /// One-thumb grid gestures (FR-PREP-5): in Nudge mode a drag previews a
    /// sample offset and commits a single `.nudge` on release; in Set-downbeat
    /// mode a tap commits `.setDownbeat` at the tapped sample. Both fire the
    /// haptic confirm (NFR-A11Y-3).
    private func gridGesture(width: CGFloat,
                             samplesPerPoint: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                switch gridTool {
                case .nudge:
                    nudgePreviewSamples = Int64(value.translation.width * samplesPerPoint)
                case .setDownbeat:
                    break
                }
            }
            .onEnded { value in
                switch gridTool {
                case .nudge:
                    let delta = Int64(value.translation.width * samplesPerPoint)
                    nudgePreviewSamples = 0
                    guard delta != 0 else { return }
                    Haptics.confirm()
                    Task { await model.nudge(bySamples: delta) }
                case .setDownbeat:
                    guard let snapshot, let grid = snapshot.grid else { return }
                    let samplesPerBar = max(grid.samplesPerBar, 1)
                    let viewStart = grid.referenceSample - 4 * samplesPerBar
                    let sample = viewStart + Double(value.location.x) * samplesPerPoint
                    Haptics.confirm()
                    Task { await model.setDownbeat(atSample: Int64(sample)) }
                }
            }
    }

    private func firstDownbeatText(_ snapshot: TrackPrepSnapshot) -> String {
        guard let sample = snapshot.firstBeatSample, let duration = snapshot.durationSec, duration > 0 else {
            return "no grid yet"
        }
        let seconds = Double(sample) / 48_000
        return String(format: "first downbeat 0:%.0f", seconds)
    }

    private func correctionsText(_ snapshot: TrackPrepSnapshot) -> String {
        switch snapshot.corrections.count {
        case 0: return "no correction stored"
        case 1: return "1 correction"
        default: return "\(snapshot.corrections.count) corrections"
        }
    }

    // MARK: - Cues / loops / What we heard

    private var cardsGrid: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 11) { threeColumns }
            VStack(alignment: .leading, spacing: 11) { threeColumns }
        }
    }

    private var threeColumns: some View {
        Group {
            hotCuesCard
            loopsAndGridCard
            whatWeHeardCard
        }
    }

    /// Hot-cue pad row — the grid structure per mockup `ipad/06`; the pads
    /// themselves land with the cue repository (FR-PREP-2 is not this commit),
    /// so they render the honest unavailable baseline like the stems faders.
    private var hotCuesCard: some View {
        card("Hot cues") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(["A", "B", "C", "D", "E", "F", "G", "H"], id: \.self) { pad in
                    Text(pad)
                        .font(.system(size: 12, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.secondary)
                }
            }
            Text("Cue placement lands with the cue repository — a track prepared here syncs (FR-SYNC-2).")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
    }

    private var loopsAndGridCard: some View {
        card("Loops") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(["½", "1", "2", "4", "8", "16"], id: \.self) { beats in
                    Text(beats)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.secondary)
                }
            }
            Text("Loop snap-to-grid lands with the loop repository.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
    }

    /// The free panel (FR-PREP-4): information about the music, never a
    /// performance capability. Phrase map from the stored phrases; energy curve
    /// and vibe descriptors are the honest baseline until their analysis
    /// surfaces exist.
    private var whatWeHeardCard: some View {
        card("What we heard") {
            HStack {
                Text("Free")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.14), in: Capsule())
                    .foregroundStyle(.green)
                Spacer()
                Text("FR-PREP-4 — information about your music, not a performance capability")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            Text("Phrase map")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            Text(phraseText)
                .font(.system(size: 12))
                .padding(.top, 3)

            Text("Energy")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            Text(energyText)
                .font(.system(size: 12))
                .padding(.top, 3)
        }
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.green.opacity(0.35), lineWidth: 1))
    }

    private var phraseText: String {
        guard let snapshot else { return "Analyze to see the phrase map." }
        if snapshot.phraseCount == 0 { return "No phrases analyzed yet." }
        var parts = ["\(snapshot.phraseCount) phrases"]
        if let longest = snapshot.longestPhraseBeats {
            parts.append("longest \(longest) beats")
        }
        return parts.joined(separator: " · ")
    }

    private var energyText: String {
        guard let energy = snapshot?.energy else { return "No energy curve yet." }
        return String(format: "%.1f / 10 overall", energy)
    }

    // MARK: - Shared bits

    private func card(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    private var snapshot: TrackPrepSnapshot? {
        model.snapshot
    }
}

/// A compact readout pill for the analysis header (mockup `ipad/06`'s pill
/// row: BPM · key · LUFS · DR · grid confidence).
private struct ReadoutPill: View {
    let title: String
    let value: String
    var accent: Color = .primary

    var body: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// A one-thumb grid-tool button (FR-PREP-5 — buttons, not menus).
private struct GridToolButton: View {
    let title: String
    var selected = false
    var enabled = true
    let action: () -> Void

    init(_ title: String, selected: Bool = false, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.selected = selected
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 11)
                .frame(minHeight: 40)
                .background(selected ? Color.orange.opacity(0.22)
                                     : Color.white.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 9))
                .foregroundStyle(selected ? .orange : (enabled ? .primary : .secondary))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}
