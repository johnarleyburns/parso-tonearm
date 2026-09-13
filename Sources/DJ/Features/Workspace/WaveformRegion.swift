import SwiftUI


// MARK: - Shared waveform region

/// The §26A.5 shared waveform display (mockup `ipad/07` rows 1–2): each deck's
/// **full-track overview + phrase ribbon** side by side (view 1), with the two
/// decks' **detail waveforms stacked on ONE shared playhead** beneath (view 2)
/// — each strip scrolls under its own fixed centre line, so a synced pair
/// shows coincident grids. All drawn from the persisted-analysis render model
/// (FR-WAVE-1); the live playheads come from telemetry each frame.
struct WaveformRegion: View {
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

    private func overviewColumn(deck: Deck) -> some View {
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

    private func detailRow(deck: Deck) -> some View {
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
