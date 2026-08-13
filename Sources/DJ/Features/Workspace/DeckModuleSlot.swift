import SwiftUI

/// The §41.9a **deck module slot** (mockup `ipad/07b`, plan 4.11): the lower
/// third of each iPad deck column offers `JOG · STEMS · PADS · FX`, remembered
/// per deck and **defaulting to `STEMS`** so §41.9 is what an existing user
/// sees unless they ask for something else. The choice persists per deck.
///
/// A module is a **layout member of its own deck column, never an overlay**:
/// swapping modules re-renders that deck's lower third only, changes no engine
/// state, and structurally cannot occlude the mixer column, either waveform,
/// the beat-phase meter or the opposite deck (AT-TWIN-2).
///
/// - **STEMS** — the four honest-unavailable stem faders until the M5
///   separator (plan §2.6);
/// - **JOG** — the 248 pt jog with ± pitch-bend buttons and the vinyl/CDJ
///   platter mode shown inside the platter (§41.9a);
/// - **PADS** — four performance pads;
/// - **FX** — honest-unavailable FX until a later milestone.
struct DeckModuleSlotView: View {
    @ObservedObject var model: WorkspaceModel
    let deck: PerformanceEngine.Deck
    let onJogIntent: (JogGestureModel.Intent) -> Void

    private var slot: WorkspaceModel.DeckModuleSlot { model.moduleSlot(deck) }

    var body: some View {
        VStack(spacing: 10) {
            selector
            content
        }
    }

    /// `JOG · STEMS · PADS · FX` — the same seg idiom as the compact drawer's
    /// bank selector, at 44 pt hit height.
    private var selector: some View {
        HStack(spacing: 3) {
            ForEach(WorkspaceModel.DeckModuleSlot.allCases, id: \.self) { option in
                Button {
                    model.setModuleSlot(option, deck: deck)
                } label: {
                    Text(option.rawValue)
                        .font(.system(size: 9, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(
                            slot == option ? Color.accentColor.opacity(0.28)
                                           : Color.white.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .foregroundStyle(slot == option ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 34)
    }

    @ViewBuilder
    private var content: some View {
        switch slot {
        case .stems: StemsModuleView()
        case .jog: JogModuleView(model: model, deck: deck, onJogIntent: onJogIntent)
        case .pads: PadsModuleView()
        case .fx: FXModuleView()
        }
    }
}

// MARK: - JOG module (§41.9a, mockup `ipad/07b`)

/// The jog module: the §41.9a **248 pt** jog flanked by ± pitch-bend buttons
/// for users who would rather not touch a platter at all, with the vinyl/CDJ
/// platter mode selectable above and shown inside the platter so the mode is
/// never a guess. The jog's intents reach the transport through the same
/// lazily-created `JogTransport` seam as the compact surfaces (FR-ENG-11,
/// AT-TWIN-4), and the bend buttons route through the same `.nudge`/`.release`
/// pair, so a momentary bend behaves identically to a ring bend. Reused by the
/// §41.9b deck column as the permanent jog (the module slot's JOG option and
/// the club column share the same jog module).
struct JogModuleView: View {
    @ObservedObject var model: WorkspaceModel
    let deck: PerformanceEngine.Deck
    let onJogIntent: (JogGestureModel.Intent) -> Void

    var body: some View {
        VStack(spacing: 8) {
            modeToggle
            HStack(alignment: .center, spacing: WorkspaceModel.ModuleGeometry.bendGap) {
                BendButton(sign: -1, onIntent: onJogIntent)
                JogView(model: model, deck: deck,
                        onIntent: onJogIntent,
                        mode: model.jogMode(deck),
                        sensitivity: model.jogSensitivity(deck),
                        showsModeReadout: true)
                    .frame(width: WorkspaceModel.ModuleGeometry.jogSize,
                           height: WorkspaceModel.ModuleGeometry.jogSize)
                BendButton(sign: 1, onIntent: onJogIntent)
            }
        }
    }

    /// `VINYL`/`CDJ` — per-deck platter action, remembered and shown inside
    /// the platter (§41.9a). The switch itself is view-only (FR-ENG-11).
    private var modeToggle: some View {
        HStack(spacing: 4) {
            Text("PLATTER")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach([JogGestureModel.JogMode.vinyl, .cdj], id: \.self) { mode in
                Button {
                    model.setJogMode(mode, deck: deck)
                } label: {
                    Text(mode == .vinyl ? "VINYL" : "CDJ")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            model.jogMode(deck) == mode
                                ? (mode == .vinyl ? Color.green : Color.cyan).opacity(0.22)
                                : Color.white.opacity(0.05),
                            in: Capsule()
                        )
                        .foregroundStyle(
                            model.jogMode(deck) == mode
                                ? (mode == .vinyl ? Color.green : Color.cyan)
                                : Color.secondary
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}

/// A momentary ± pitch-bend button (mockup `ipad/07b`'s BEND columns): hold to
/// bend the deck's tempo by the §41.9a 0.4% step, release to restore. Emits
/// the jog's own `.nudge(rate:)` / `.release` intents, so a button bend is
/// byte-for-byte the same temporary bend a ring rotation produces.
private struct BendButton: View {
    let sign: Double
    let onIntent: (JogGestureModel.Intent) -> Void

    /// The momentary bend step: ±0.4% (mockup `ipad/07b`'s BEND readouts).
    private static let step: Double = 0.004

    @State private var pressed = false

    var body: some View {
        VStack(spacing: 5) {
            Text(sign < 0 ? "−" : "+")
                .font(.system(size: 15, weight: .bold))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(
                    pressed ? Color.accentColor.opacity(0.28)
                            : Color.white.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .foregroundStyle(pressed ? Color.accentColor : .primary)
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0, pressing: { isPressing in
                    if isPressing && !pressed {
                        pressed = true
                        onIntent(.nudge(rate: sign * Self.step))
                    } else if !isPressing && pressed {
                        pressed = false
                        onIntent(.release)
                    }
                }, perform: {})
            Text(pressed ? String(format: "%+.1f%%", sign * Self.step * 100) : "0.0%")
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(pressed ? Color.accentColor : .secondary)
            Text("BEND")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(width: WorkspaceModel.ModuleGeometry.bendColumnWidth)
    }
}

// MARK: - STEMS module (default, §41.9)

/// The four stem faders, the honest-unavailable state until the M5 separator
/// lands (plan §2.6). This is the slot's default — §41.9's stems block moved
/// into the module slot so the choice is per deck. The rows are deliberately
/// compact: the §41.9b deck column keeps the club geometry (jog + pads +
/// transport), and the stem surface that ships in 5.8 is the §41.10 focused
/// view.
private struct StemsModuleView: View {
    var body: some View {
        VStack(spacing: 3) {
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
                        .font(.system(size: 10))
                        .frame(width: 48, alignment: .leading)
                    GeometryReader { proxy in
                        Capsule().fill(Color.white.opacity(0.08))
                            .overlay(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.2))
                                    .frame(width: proxy.size.width * 0.8)
                            }
                    }
                    .frame(height: 3)
                }
            }
        }
    }
}

// MARK: - PADS module

/// Four performance pads — the workspace's cue pad row, inside the slot so the
/// lower third is one swappable module (§41.9a).
private struct PadsModuleView: View {
    var body: some View {
        HStack(spacing: 6) {
            ForEach(["A", "B", "C", "D"], id: \.self) { pad in
                Text(pad)
                    .font(.system(size: 12, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - FX module

/// Honest-unavailable FX until a later milestone: the four FX pads render the
/// disabled state rather than a fake effect set (the waveform/stems baseline
/// convention).
private struct FXModuleView: View {
    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("FX")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("unavailable")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(["ECHO", "RVB", "FLTR", "CRUSH"], id: \.self) { fx in
                    Text(fx)
                        .font(.system(size: 10, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
