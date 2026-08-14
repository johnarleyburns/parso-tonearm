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
/// - **FX** — ECHO live (the §35A beat-synced echo, plan 5.5); RVB/FLTR/CRUSH
///   honestly unavailable until a later milestone (§35A.4).
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
        case .stems: StemsModuleView(model: model, deck: deck)
        case .jog: JogModuleView(model: model, deck: deck, onJogIntent: onJogIntent)
        case .pads: PadsModuleView()
        case .fx: FXModuleView(model: model, deck: deck)
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

/// The four stem faders (§35.1), **live only when the deck's stems are
/// prepared** (plan 5.8): a prepared set renders draggable gain faders with
/// tap-to-mute; an unprepared deck renders the honest disabled state ("stems
/// not prepared" / "separating…") — never a fader that looks live and does
/// nothing (§36.5, FR-ENG-3). This is the slot's default — §41.9's stems block
/// moved into the module slot so the choice is per deck. The rows are
/// deliberately compact: the §41.9b deck column keeps the club geometry (jog +
/// pads + transport).
private struct StemsModuleView: View {
    @ObservedObject var model: WorkspaceModel
    let deck: PerformanceEngine.Deck

    private var status: DeckStemStatus { model.stemStatus(deck) }
    private var deckID: String { deck == .a ? "a" : "b" }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Stems")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(status.label)
                    .font(.caption2)
                    .foregroundStyle(status == .prepared ? Color.green : .secondary)
            }
            if status == .prepared {
                ForEach(StemKind.allCases, id: \.self) { stem in
                    StemFaderRow(label: title(stem),
                                 gain: model.stemGain(deck, stem: stem),
                                 muted: model.stemIsMuted(deck, stem: stem),
                                 identifier: "dj.deck.\(deckID).stem.\(stem.rawValue)") { gain in
                        model.setStemGain(deck, stem: stem, gain: gain)
                    } onMuteToggled: {
                        model.setStemMute(deck, stem: stem,
                                          muted: !model.stemIsMuted(deck, stem: stem))
                    }
                }
            } else {
                // The honest disabled state: unity bars, dimmed — the status
                // label is carried by the header. Never a live-looking fader
                // that does nothing (§36.5).
                ForEach(StemKind.allCases, id: \.self) { stem in
                    HStack(spacing: 6) {
                        Text(title(stem))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .leading)
                        Capsule().fill(Color.white.opacity(0.06))
                            .frame(height: 12)
                    }
                }
            }
        }
    }

    private func title(_ stem: StemKind) -> String {
        switch stem {
        case .vocals: return "Vocals"
        case .drums: return "Drums"
        case .bass: return "Bass"
        case .other: return "Other"
        }
    }
}

// MARK: - Stem fader row (shared by the module slot and the compact drawer)

/// A live per-voice stem fader for the STEMS surfaces (§35.1, plan 5.8): the
/// gain capsule is a drag surface mapping 0…`StemControlState.maxGain`, and
/// tapping the label toggles mute (the row dims). Only rendered when the
/// deck's stems are prepared — an unprepared deck shows the honest disabled
/// row instead (§36.5).
struct StemFaderRow: View {
    let label: String
    let gain: Float
    let muted: Bool
    let identifier: String
    let onGainChanged: (Float) -> Void
    let onMuteToggled: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onMuteToggled) {
                Text(label)
                    .font(.system(size: 10))
                    .frame(width: 48, alignment: .leading)
                    .foregroundStyle(muted ? Color.secondary : Color.primary)
            }
            .buttonStyle(.plain)

            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                        .frame(height: 12)
                    Capsule().fill(Color.accentColor.opacity(muted ? 0.15 : 0.65))
                        .frame(width: max(8, width * CGFloat(gainFraction)),
                               height: 12)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { value in
                        let t = Float(min(1, max(0, value.location.x / max(width, 1))))
                        onGainChanged(t * StemControlState.maxGain)
                    }
                )
            }
            .frame(height: 14)
        }
        .accessibilityIdentifier(identifier)
    }

    /// The filled fraction of the gain capsule (0…1).
    private var gainFraction: Float {
        min(1, max(0, gain / StemControlState.maxGain))
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

/// The FX module: **ECHO is live** (the §35A beat-synced echo, the one Beat FX
/// M5 ships — plan decision 23); the other three pads stay honestly unavailable
/// rather than shipping a filter-sweep pad that duplicates the filter knob
/// (§35A.4, the stems convention).
private struct FXModuleView: View {
    @ObservedObject var model: WorkspaceModel
    let deck: PerformanceEngine.Deck

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("FX")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("ECHO live · M5")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                echoPad
                ForEach(["RVB", "FLTR", "CRUSH"], id: \.self) { fx in
                    Text(fx)
                        .font(.system(size: 10, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The live ECHO pad — a tap toggles the deck's §35A echo. Highlighted
    /// while on so the state is never a guess.
    private var echoPad: some View {
        let on = model.echoEnabled(deck)
        return Button {
            model.setEchoEnabled(deck, enabled: !on)
        } label: {
            Text("ECHO")
                .font(.system(size: 10, weight: .bold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    on ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(on ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
    }
}
