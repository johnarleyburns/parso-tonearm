import SwiftUI

/// The §42.7b **momentary bank drawer** (mockup `iphone/05d`): a 228 pt-wide
/// panel that rises over **one deck's jog + transport and nothing else**
/// (FR-ENG-12, AT-TWIN-2). The four banks — `EQ · STEMS · PADS · CUES` —
/// sit behind a seg selector; filter is deliberately absent because it lives
/// on the screen edge, still visible and under a thumb while the drawer is
/// open (§42.7b).
///
/// Spring-loading is the point (AT-TWIN-3): **holding** the bank tab raises
/// the drawer and the jog stays covered only as long as the thumb holds;
/// **releasing** dismisses it within one frame and returns the jog under the
/// thumb. A **tap** pins the bank for hands-free work, and a pinned drawer
/// self-dismisses after 12 s of no touch. A held drawer cannot leave the
/// surface in a mode the user has forgotten about.
struct BankDrawerView: View {
    @ObservedObject var model: WorkspaceModel
    let deck: Deck

    private var currentBank: WorkspaceModel.TwinBank {
        model.drawerState.bank ?? model.selectedBank(deck)
    }

    private var isPinned: Bool { model.drawerState.isPinned }

    var body: some View {
        VStack(spacing: 0) {
            header

            bankSelector

            bankContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            hint
                .frame(height: 22)
        }
        .padding(.horizontal, 10)
        .frame(width: WorkspaceModel.DrawerGeometry.width,
               height: WorkspaceModel.DrawerGeometry.height)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(red: 0.055, green: 0.07, blue: 0.095))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0).onChanged { _ in
                model.noteDrawerActivity()
            }
        )
    }

    /// The grab handle, and — once pinned — the dismiss button: the drawer
    /// covers this deck's tab while open, so a pinned bank's toggle-off lives
    /// here rather than under the drawer (AT-TWIN-3's 12 s idle is the other).
    private var header: some View {
        ZStack {
            Capsule()
                .fill(Color.white.opacity(0.18))
                .frame(width: 38, height: 4)
            if isPinned {
                HStack {
                    Spacer()
                    Button {
                        model.dismissDrawer()
                    } label: {
                        Image(systemName: "pin.slash")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .background(Color.white.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.trailing, 4)
            }
        }
        .frame(height: 30)
    }

    /// `EQ · STEMS · PADS · CUES`. In a pinned drawer this is the hands-free
    /// switch; every tap resets the 12 s idle clock.
    private var bankSelector: some View {
        HStack(spacing: 3) {
            ForEach(WorkspaceModel.TwinBank.allCases, id: \.self) { bank in
                Button {
                    model.selectDrawerBank(bank)
                } label: {
                    Text(bank.rawValue)
                        .font(.system(size: 9, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(
                            currentBank == bank ? Color.accentColor.opacity(0.28)
                                               : Color.white.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .foregroundStyle(currentBank == bank ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var bankContent: some View {
        switch currentBank {
        case .eq: eqContent
        case .stems: stemsContent
        case .pads: padsContent
        case .cues: cuesContent
        }
    }

    // MARK: EQ — three 44 pt knobs + a trim fader (mockup `iphone/05d`)

    private var eq: (low: Float, mid: Float, high: Float) {
        deck == .a ? (model.eqALow, model.eqAMid, model.eqAHigh)
                   : (model.eqBLow, model.eqBMid, model.eqBHigh)
    }

    private var eqContent: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                EQKnobWithReadout(label: "HI", knob: eq.high,
                                  identifier: "dj.deck.\(deckID).eq.high",
                                  onChanged: { model.setEQKnobs(deck, low: eq.low, mid: eq.mid, high: $0) })
                EQKnobWithReadout(label: "MID", knob: eq.mid,
                                  identifier: "dj.deck.\(deckID).eq.mid",
                                  onChanged: { model.setEQKnobs(deck, low: eq.low, mid: $0, high: eq.high) })
                EQKnobWithReadout(label: "LOW", knob: eq.low,
                                  identifier: "dj.deck.\(deckID).eq.low",
                                  onChanged: { model.setEQKnobs(deck, low: $0, mid: eq.mid, high: eq.high) })
            }

            Divider().opacity(0.4)

            HStack {
                Text("TRIM")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(trimText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            trimFader
        }
        .padding(.top, 2)
    }

    private var deckID: String { deck == .a ? "a" : "b" }

    private var trimGain: Float {
        deck == .a ? model.channelA : model.channelB
    }

    private var trimText: String {
        let db = 20 * log10(Double(trimGain))
        if trimGain <= 0 { return "KILL" }
        return String(format: "%+.1f dB", db)
    }

    private var trimFader: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10)).frame(height: 6)
                Capsule().fill(Color.white.opacity(0.9)).frame(width: 22, height: 22)
                    .offset(x: max(0, min(width - 22, width * CGFloat(trimGain) - 11)))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    let t = clamp01(value.location.x / width)
                    model.setChannelFader(deck, gain: Float(t))
                }
            )
        }
        .frame(height: 26)
        .accessibilityIdentifier("dj.deck.\(deckID).fader")
        .coachGlow(identifier: "dj.deck.\(deckID).fader")
    }

    // MARK: STEMS — the §2.1 iPhone budget (two live faders when prepared)

    private var stemsContent: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Stems")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(model.stemStatus(deck).label)
                    .font(.caption2)
                    .foregroundStyle(model.stemStatus(deck) == .prepared ? Color.green : .secondary)
            }
            .padding(.horizontal, 4)

            if model.stemStatus(deck) == .prepared {
                // §2.1's budget: two live stem faders on iPhone — the two
                // voices that matter for a transition (the full four stay
                // available from cache and on the iPad's STEMS module).
                StemFaderRow(label: "Vocals",
                             gain: model.stemGain(deck, stem: .vocals),
                             muted: model.stemIsMuted(deck, stem: .vocals),
                             identifier: "dj.deck.\(deckID).stem.vocals") { gain in
                    model.setStemGain(deck, stem: .vocals, gain: gain)
                } onMuteToggled: {
                    model.setStemMute(deck, stem: .vocals,
                                      muted: !model.stemIsMuted(deck, stem: .vocals))
                }
                StemFaderRow(label: "Drums",
                             gain: model.stemGain(deck, stem: .drums),
                             muted: model.stemIsMuted(deck, stem: .drums),
                             identifier: "dj.deck.\(deckID).stem.drums") { gain in
                    model.setStemGain(deck, stem: .drums, gain: gain)
                } onMuteToggled: {
                    model.setStemMute(deck, stem: .drums,
                                      muted: !model.stemIsMuted(deck, stem: .drums))
                }
            } else {
                // The honest disabled state: unity bars, dimmed — never a
                // live-looking fader that does nothing (§36.5).
                ForEach(["Vocals", "Drums"], id: \.self) { stem in
                    HStack(spacing: 6) {
                        Text(stem)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .leading)
                        Capsule().fill(Color.white.opacity(0.06))
                            .frame(height: 12)
                    }
                }
            }

            Text("§2.1's budget: two live stem faders on iPhone — the full four land on the iPad's STEMS module")
                .font(.system(size: 8.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 2)
        }
        .padding(.top, 6)
    }

    // MARK: PADS — four 44 pt performance pads

    private var padsContent: some View {
        HStack(spacing: 6) {
            ForEach(["1", "2", "3", "4"], id: \.self) { pad in
                Text(pad)
                    .font(.system(size: 12, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.top, 6)
        .padding(.horizontal, 2)
    }

    // MARK: CUES — four hot-cue pads (§42.7b: four at 44 pt fit a drawer, eight do not)

    private var cuesContent: some View {
        HStack(spacing: 6) {
            ForEach(["A", "B", "C", "D"], id: \.self) { pad in
                Text("HOT \(pad)")
                    .font(.system(size: 10, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.top, 6)
        .padding(.horizontal, 2)
    }

    private var hint: some View {
        Text(isPinned
             ? "PINNED · 12 s idle dismisses"
             : "hold the tab to peek · release returns the jog")
            .font(.system(size: 8.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// An `EQKnob` with the mockup's per-band readout (kill end stop reads KILL).
/// `identifier` carries the §53.11 accessibility identifier.
private struct EQKnobWithReadout: View {
    let label: String
    let knob: Float
    var identifier: String?
    let onChanged: (Float) -> Void

    var body: some View {
        VStack(spacing: 3) {
            EQKnob(label: label, value: knob, identifier: identifier, onChanged: onChanged)
            Text(readout)
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(readoutColor)
        }
    }

    private var readout: String {
        if knob <= -0.95 { return "KILL" }
        if abs(knob) < 0.01 { return "0.0" }
        return String(format: "%+.1f", PAEWorkspaceEngine.eqKnobToDB(knob))
    }

    private var readoutColor: Color {
        knob <= -0.95 ? .red : .secondary
    }
}

// MARK: - Release-to-commit LOOP flyout (§42.7b idiom 3)

/// The **release-to-commit flyout** anchored to LOOP (§42.7b idiom 3, §41.9a;
/// mockups `ipad/07b`, `iphone/05d`): holding LOOP raises the §41.9a beat
/// counts; **release over a size to set it, release outside to cancel** — the
/// loop never changes on the way out. The button's quick tap keeps the §33
/// 8-beat default.
///
/// The whole interaction is one drag on the button: touch-down opens the
/// flyout after a short hold (a quick tap is a tap), and the release point is
/// resolved against the flyout's chip frames by the model's pure
/// `WorkspaceModel.LoopFlyout.releasedAction(at:)` — the engine is touched
/// only on a release inside a commit target. The flyout is anchored within
/// that deck's column (right-aligned to a deck-A transport, left-aligned to a
/// deck-B transport), so it never covers the mixer column, either waveform,
/// the beat-phase meter or the opposite deck (FR-ENG-12, AT-TWIN-2).
struct LoopReleaseToCommitButton: View {
    @ObservedObject var model: WorkspaceModel
    let deck: Deck

    /// A press held past this opens the flyout; a shorter press is the tap.
    private let openDelay: TimeInterval = 0.30
    /// A press that wanders past this before the delay is a slide, not a hold.
    private let pressTolerance: CGFloat = 20

    @State private var pressStart: Date?
    @State private var dragStart: CGPoint?
    @State private var flyoutOpen = false

    var body: some View {
        GeometryReader { proxy in
            let flyoutFrame = flyoutFrame(in: proxy.size)
            ZStack(alignment: .bottomLeading) {
                if flyoutOpen {
                    LoopFlyoutContent()
                        .frame(width: flyoutFrame.width, height: flyoutFrame.height)
                        .position(x: flyoutFrame.midX, y: flyoutFrame.midY)
                        .allowsHitTesting(false)
                }
                loopButton
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragStart == nil {
                            dragStart = value.location
                            pressStart = Date()
                        }
                        guard !flyoutOpen, let start = dragStart else { return }
                        let held = Date().timeIntervalSince(pressStart ?? Date())
                        let wandered = hypot(value.location.x - start.x,
                                             value.location.y - start.y)
                        if held > openDelay && wandered < pressTolerance {
                            flyoutOpen = true
                            Haptics.confirm()
                        }
                    }
                    .onEnded { value in
                        let held = Date().timeIntervalSince(pressStart ?? Date())
                        defer { flyoutOpen = false; dragStart = nil; pressStart = nil }
                        if flyoutOpen {
                            let point = CGPoint(x: value.location.x - flyoutFrame.minX,
                                                y: value.location.y - flyoutFrame.minY)
                            if let action = WorkspaceModel.LoopFlyout.releasedAction(at: point) {
                                commit(action)
                            }
                        } else if held < openDelay {
                            model.setLoop(deck, beats: 8)
                        }
                    }
            )
        }
        .frame(width: WorkspaceModel.TwinGeometry.transportWidth, height: 48)
    }

    /// The flyout is one deck-column wide at most and stays over that deck's
    /// jog + transport: right-aligned to the transport on deck A (extends over
    /// the jog to the left), left-aligned on deck B (extends right).
    private func flyoutFrame(in size: CGSize) -> CGRect {
        let width = WorkspaceModel.LoopFlyout.width
        let height = WorkspaceModel.LoopFlyout.height
        let minX: CGFloat = deck == .a ? size.width - width : 0
        return CGRect(x: minX, y: -height, width: width, height: height)
    }

    private var loopButton: some View {
        Text(flyoutOpen ? "LOOP …" : "LOOP")
            .font(.system(size: 11, weight: .bold))
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(
                flyoutOpen ? Color.accentColor : Color.white.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .foregroundStyle(.white)
    }

    private func commit(_ action: WorkspaceModel.LoopAction) {
        switch action {
        case .set(let beats): model.setLoop(deck, beats: beats)
        case .exit: model.exitLoop(deck)
        }
        Haptics.confirm()
    }
}

/// The flyout's rendered header + chips, each chip positioned at exactly the
/// model's pure chip frame so the drag's release resolution is honest to what
/// the user sees.
private struct LoopFlyoutContent: View {
    var body: some View {
        VStack(spacing: 0) {
            Text("HOLD LOOP · beats")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: WorkspaceModel.LoopFlyout.headerHeight)
                .padding(.horizontal, 8)

            GeometryReader { proxy in
                ZStack {
                    ForEach(Array(WorkspaceModel.LoopFlyout.beats.enumerated()), id: \.offset) { index, beats in
                        let frame = WorkspaceModel.LoopFlyout.chipFrame(index: index)
                        Text("\(Int(beats))")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: WorkspaceModel.LoopFlyout.chipWidth,
                                   height: WorkspaceModel.LoopFlyout.chipHeight)
                            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                            .position(CGPoint(x: frame.midX,
                                              y: frame.midY - WorkspaceModel.LoopFlyout.headerHeight))
                    }
                    let exit = WorkspaceModel.LoopFlyout.exitChipFrame
                    Text("EXIT LOOP")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: WorkspaceModel.LoopFlyout.exitChipWidth,
                               height: WorkspaceModel.LoopFlyout.chipHeight)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(.red.opacity(0.9))
                        .position(CGPoint(x: exit.midX,
                                          y: exit.midY - WorkspaceModel.LoopFlyout.headerHeight))
                }
                .frame(width: WorkspaceModel.LoopFlyout.width,
                       height: WorkspaceModel.LoopFlyout.height - WorkspaceModel.LoopFlyout.headerHeight)
            }
        }
        .padding(.top, 4)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 0.07, green: 0.085, blue: 0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
    }
}

// MARK: - Bottom-edge crossfader surface (§42.7a idiom 4)

/// §42.7a's **bottom-edge crossfader drag surface**: the entire bottom edge,
/// full width and ~40 pt tall, is a **relative** crossfader surface at 1:1 —
/// reachable from deep inside either thumb arc, it is the crossfader you never
/// have to navigate to. The drag maps 1:1 onto the resident fader cap's travel
/// (`WorkspaceModel.relativeCrossfader`); a double-tap slams to a side.
///
/// It consumes no layout height: it sits over the §42.7a vertical slack + home
/// indicator, and `.defersSystemGestures(on: .bottom)` on the surface keeps
/// the home indicator from swallowing the gesture. It is never covered by any
/// modal idiom (§42.7b) because it is a full-width band below the drawer's
/// frame.
struct BottomEdgeCrossfader: View {
    @ObservedObject var model: WorkspaceModel
    /// The resident fader cap's travel for a full −1 … +1 sweep — the 1:1
    /// mapping constant.
    let residentCapTravel: CGFloat

    @State private var dragOrigin: Float?

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if dragOrigin == nil { dragOrigin = model.crossfader }
                            guard let origin = dragOrigin else { return }
                            let next = WorkspaceModel.relativeCrossfader(
                                from: origin,
                                deltaX: value.translation.width,
                                residentCapTravel: residentCapTravel)
                            model.setCrossfader(next, curve: model.crossfaderCurve)
                        }
                        .onEnded { _ in dragOrigin = nil }
                )
                .gesture(
                    SpatialTapGesture(count: 2)
                        .onEnded { value in
                            let t = value.location.x / width
                            model.setCrossfader(t < 0.5 ? -1 : 1, curve: model.crossfaderCurve)
                        }
                )
                .overlay(alignment: .bottom) {
                    Text("CROSSFADER · drag, double-tap slams")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.55))
                        .padding(.bottom, 3)
                }
        }
        .frame(height: 40)
    }
}

/// Clamp a value into the closed unit interval.
private func clamp01(_ value: CGFloat) -> CGFloat {
    max(0, min(1, value))
}
