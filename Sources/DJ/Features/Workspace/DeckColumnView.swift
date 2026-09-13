import SwiftUI

// MARK: - Deck column

/// One deck's §41.9b column: header (DECK / MASTER / SYNCED + the queue
/// button), title + BPM/key readout, then the club performance block — the
/// **tempo fader on the outer edge** beside the **jog centred** (rule 4), the
/// pad **mode selector** above **eight pads** (rule 5), and **CUE left of
/// PLAY** at the deck's inner base (rule 3) — and beneath it the module slot.
/// The deck's queue (§41.9c) raises as a browse sheet from the header button,
/// so the performance column keeps its club geometry (the compact crate-sheet
/// pattern; mockup `ipad/07` shows no queue panel in the deck column).
struct DeckColumnView: View {
    @ObservedObject var model: WorkspaceModel
    let deck: Deck
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
