import SwiftUI

/// The §41.9b tempo fader on the deck's outer edge (rule 4): a vertical fader
/// over the ±8% `ClubGeometry.tempoFaderRange`, fader-up = faster. It sets the
/// deck's rate through the session VM (`WorkspaceModel.setTempo`), so the
/// position mirrors the model state shared by every surface. The VINYL/CDJ
/// platter mode (§41.9a) rides below the fader so the deck's outer edge is one
/// control column; the mode is shown inside the platter and toggled here.
struct TempoFader: View {
    @ObservedObject var model: WorkspaceModel
    let deck: Deck

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { proxy in
                let height = proxy.size.height
                let t = CGFloat((model.tempo(deck) - WorkspaceModel.ClubGeometry.tempoFaderRange.lowerBound)
                                / (WorkspaceModel.ClubGeometry.tempoFaderRange.upperBound
                                   - WorkspaceModel.ClubGeometry.tempoFaderRange.lowerBound))
                ZStack(alignment: .bottom) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule()
                        .fill(Color.accentColor.opacity(0.85))
                        .frame(width: 3)
                        .frame(height: max(8, height * t))
                    Capsule()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 20, height: 4)
                        .offset(y: -(max(8, height * t)) + 2)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { gesture in
                        let fill = min(1, max(0, 1 - gesture.location.y / height))
                        let fraction = -0.08 + 0.16 * Double(fill)
                        model.setTempo(deck, fraction: fraction)
                    }
                )
            }
            Text(String(format: "%+.1f%%", model.tempo(deck) * 100))
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("TEMPO")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
            modeToggle
        }
        .frame(width: WorkspaceModel.ModuleGeometry.tempoFaderWidth)
    }

    /// The VINYL/CDJ platter mode (§41.9a) — view-only, remembered per deck.
    private var modeToggle: some View {
        VStack(spacing: 3) {
            ForEach([JogGestureModel.JogMode.vinyl, .cdj], id: \.self) { mode in
                Button {
                    model.setJogMode(mode, deck: deck)
                } label: {
                    Text(mode == .vinyl ? "VINYL" : "CDJ")
                        .font(.system(size: 7, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                        .background(
                            model.jogMode(deck) == mode
                                ? (mode == .vinyl ? Color.green : Color.cyan).opacity(0.22)
                                : Color.white.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .foregroundStyle(
                            model.jogMode(deck) == mode
                                ? (mode == .vinyl ? Color.green : Color.cyan)
                                : Color.secondary
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
