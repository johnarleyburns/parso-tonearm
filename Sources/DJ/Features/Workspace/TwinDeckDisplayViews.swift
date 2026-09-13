import SwiftUI

// MARK: - Stacked waveforms on one shared playhead

/// The §42.7a stacked-waveform display: deck A and deck B detail waveforms on
/// **one shared playhead** — each strip scrolls under its own fixed centre
/// line, so when the decks are in phase the grids align across the shared
/// centre (the "grids line up" read, §26A.5). Both draw from persisted
/// analysis (FR-WAVE-1) — the honest empty state replaces the old placeholder.
struct StackedWaveformView: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        VStack(spacing: 2) {
            waveRow(deck: .a)
            waveRow(deck: .b)
        }
        .frame(height: 90)
    }

    private func waveRow(deck: Deck) -> some View {
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
struct DeckIdentityView: View {
    @ObservedObject var model: WorkspaceModel
    let deck: Deck
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
struct MasterReadoutView: View {
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
