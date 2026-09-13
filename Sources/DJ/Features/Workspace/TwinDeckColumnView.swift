import SwiftUI

// MARK: - One deck's column

/// One resident deck's control block (§42.7a): the 168 pt jog and the 54×54
/// transport stack side by side (transport on the inner side — deck A's jog
/// sits at the left thumb, deck B's at the right), with the bank tab below.
struct TwinDeckColumnView: View {
    @ObservedObject var model: WorkspaceModel
    let deck: Deck
    let transportFirst: Bool
    let onJogIntent: (JogGestureModel.Intent) -> Void

    private var telemetryDeck: EngineTelemetry.Deck {
        deck == .a ? model.telemetry.deckA : model.telemetry.deckB
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: WorkspaceModel.TwinGeometry.jogTransportGap) {
                if transportFirst {
                    transportStack
                    jog
                } else {
                    jog
                    transportStack
                }
            }
        }
        .frame(height: WorkspaceModel.DrawerGeometry.height, alignment: .top)
        .overlay(alignment: .bottom) {
            // The bank tab the momentary drawer anchors to (§42.7b). Its 44 pt
            // hit region overlaps the jog's lower rim per §42.7a; holding
            // springs the drawer open over this deck's jog + transport,
            // releasing dismisses it (restoring the jog within one frame) and
            // a tap pins it for hands-free work (AT-TWIN-3).
            BankTabButton(model: model, deck: deck)
        }
    }

    private var jog: some View {
        JogView(model: model, deck: deck, onIntent: onJogIntent)
            .frame(width: WorkspaceModel.TwinGeometry.jogWidth,
                   height: WorkspaceModel.TwinGeometry.jogWidth)
    }

    /// The 54×54 transport: CUE · PLAY/PAUSE · LOOP (54×48), with the loop's
    /// release-to-commit flyout (§42.7b idiom 3). CUE reads before PLAY at the
    /// deck's inner base (§41.9b rule 3's compact adaptation — the vertical
    /// stack is the §42.7a budget's answer to a 54 pt column). SYNC lives in
    /// the mixer column, not here (§42.7a).
    private var transportStack: some View {
        VStack(spacing: 6) {
            TransportButton(title: "CUE",
                            identifier: "dj.deck.\(deckID).cue") {
                model.cue(deck)
            } onRelease: {
                model.releaseCue(deck)
            }
            .frame(width: WorkspaceModel.TwinGeometry.transportWidth,
                   height: WorkspaceModel.TwinGeometry.transportWidth)

            TransportButton(title: telemetryDeck.playing ? "PAUSE" : "PLAY",
                            emphasized: true,
                            identifier: "dj.deck.\(deckID).play") {
                if telemetryDeck.playing {
                    model.pause(deck)
                } else {
                    model.play(deck)
                }
            } onRelease: {}
            .frame(width: WorkspaceModel.TwinGeometry.transportWidth,
                   height: WorkspaceModel.TwinGeometry.transportWidth)

            LoopReleaseToCommitButton(model: model, deck: deck)
        }
    }

    private var deckID: String { deck == .a ? "a" : "b" }
}

/// The bank tab (§42.7b): a 44 pt-hit-region strip overlaid on the jog's lower
/// rim whose **press** springs the §42.7b drawer over this deck's jog +
/// transport. Releasing dismisses it (AT-TWIN-3 restores the jog within one
/// frame); a press shorter than `WorkspaceModel.DrawerGeometry.tapThreshold`
/// is a tap that pins the bank for hands-free work. Pressing the tab of an
/// already-pinned bank toggles it off.
private struct BankTabButton: View {
    @ObservedObject var model: WorkspaceModel
    let deck: Deck

    @State private var pressStart: Date?
    @State private var dismissedPinned = false

    private var isBank: String { deck == .a ? "A" : "B" }

    var body: some View {
        HStack {
            Text("HOLD ▲ \(isBank) BANK")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("EQ · STEMS · PADS · CUES")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(
                model.drawerState.deck == deck ? Color.accentColor.opacity(0.10)
                                               : Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.06), lineWidth: 1))
        .frame(height: 44, alignment: .bottom)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard pressStart == nil else { return }
                    pressStart = Date()
                    if case .pinned(let pinnedDeck, _) = model.drawerState, pinnedDeck == deck {
                        model.dismissDrawer()
                        dismissedPinned = true
                    } else {
                        model.springDrawer(deck: deck)
                    }
                }
                .onEnded { _ in
                    let held = Date().timeIntervalSince(pressStart ?? Date())
                    defer { pressStart = nil; dismissedPinned = false }
                    guard !dismissedPinned else { return }
                    guard model.drawerState.deck == deck else { return }
                    if WorkspaceModel.springReleasePins(holdDuration: held) {
                        model.pinDrawer()
                    } else {
                        model.releaseDrawer()
                    }
                }
        )
    }
}
