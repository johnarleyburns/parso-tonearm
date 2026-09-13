import SwiftUI

// MARK: - The other deck in a strip

/// The non-focused deck as a 72 pt strip (§42.1): identity, BPM and state,
/// playhead, and a play/pause — enough to know it is there and to stop it.
/// A tap or a swipe up swaps focus — a view-only change, both decks stay live.
struct SoloStripView: View {
    @ObservedObject var model: WorkspaceModel
    let deck: Deck

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

