import SwiftUI

// MARK: - Mixer column

/// The 202 pt mixer column (§42.7a): only what must be shared and continuous —
/// the beat-phase meter (centred means locked, with signed millisecond error),
/// channel faders A/B, SYNC (tap = beat, hold = downbeat) and the crossfader.
/// **No EQ** — three 44 pt knobs cannot fit the 202 pt column, so EQ is a
/// bank, not a resident control.
struct TwinMixerColumnView: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        VStack(spacing: 4) {
            Text("BEAT PHASE · A vs B")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)

            PhaseErrorMeter(errorFraction: errorFraction)

            Text(phaseText)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(phaseColor)

            HStack(alignment: .center, spacing: 12) {
                ChannelFader(label: "CH A", value: model.channelA,
                             identifier: "dj.deck.a.fader",
                             onChanged: { model.setChannelFader(.a, gain: $0) })
                syncButton
                ChannelFader(label: "CH B", value: model.channelB,
                             identifier: "dj.deck.b.fader",
                             onChanged: { model.setChannelFader(.b, gain: $0) })
            }
            .padding(.top, 2)

            crossfaderBox

            // §42.7c: the ECHO button in the always-visible band — Echo Out is
            // a two-control transition (echo on, fader down), so both must be
            // reachable without a drawer. The shared button's flyout carries
            // the A/B channel chips (the twin's single ECHO serves either
            // channel).
            EchoReleaseToCommitButton(model: model, deck: .a)
            // §44.2a: pre-listen is a transition control, so it is always
            // visible — never behind a drawer (§42.7c's transferable core).
            // **One CUE per channel**, not one for the focused deck: this
            // surface shows both decks at once, and every mixer ever built
            // puts a cue button on each channel. Cueing B while working A is
            // the ordinary case, and a focus-following button would make it
            // impossible.
            HStack(spacing: 12) {
                CueButton(model: model, deck: .a)
                CueButton(model: model, deck: .b)
            }
            .frame(minHeight: 44)
        }
    }

    private var errorFraction: Double {
        let error = WorkspaceModel.beatPhaseError(phaseA: model.telemetry.deckA.phase,
                                                  phaseB: model.telemetry.deckB.phase)
        // Render −0.5…0.5 as the meter's −1…1 span.
        return error * 2
    }

    private var phaseText: String {
        guard model.telemetry.masterBPM > 0 else { return "no master clock" }
        return String(format: "%@ · ±%.1f ms",
                      abs(model.beatPhaseErrorMillis) < 10 ? "locked" : "off",
                      abs(model.beatPhaseErrorMillis))
    }

    private var phaseColor: Color {
        model.telemetry.masterBPM > 0 && abs(model.beatPhaseErrorMillis) < 10
            ? .green : .secondary
    }

    /// SYNC lives in the mixer: tap = beat, hold = downbeat (§32.2). Deck B
    /// syncs to master A, the deck the jog's MASTER cap names.
    private var syncButton: some View {
        VStack(spacing: 4) {
            Button {
                model.sync(.b, to: .a)
            } label: {
                Text("SYNC")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 54, height: 44)
                    .background(
                        model.isSynced(.b) ? Color.cyan.opacity(0.28)
                                           : Color.white.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(model.isSynced(.b) ? Color.cyan : .primary)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                    model.sync(.b, to: .a, barSync: true)
                }
            )
            Text("tap = beat\nhold = downbeat")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var crossfaderBox: some View {
        VStack(spacing: 5) {
            HStack {
                Text("A").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("CROSSFADER").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("B").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.10))
                        .frame(height: 10)
                    let t = CGFloat((model.crossfader + 1) / 2)
                    Capsule()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 22, height: 29)
                        .offset(x: max(0, min(width - 22, width * t - 11)))
                }
                .frame(height: 34)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { value in
                        let t = Self.clampUnit(value.location.x / width)
                        model.setCrossfader(Float(t) * 2 - 1, curve: model.crossfaderCurve)
                    }
                )
                .performanceControl("dj.mixer.crossfader", label: "Crossfader",
                                    value: model.crossfader)
                .coachGlow(identifier: "dj.mixer.crossfader")
            }
            .frame(height: 34)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    private static func clampUnit(_ value: CGFloat) -> CGFloat {
        max(0, min(1, value))
    }
}

/// The beat-phase meter: the signed error between the two decks, centred means
/// locked (mockup `iphone/05c`'s `pmeter`). The marker sits at the centre when
/// the decks are phase-aligned and swings toward the lagging deck.
private struct PhaseErrorMeter: View {
    /// The signed error in the meter's −1…1 span (positive = A ahead).
    let errorFraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Capsule()
                    .fill(Color.white.opacity(0.10))
                Capsule()
                    .fill(Color.white.opacity(0.5))
                    .frame(width: 2, height: proxy.size.height - 6)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                Capsule()
                    .fill(Color.cyan)
                    .frame(width: 10, height: 12)
                    .position(x: proxy.size.width / 2
                                  + CGFloat(errorFraction) * proxy.size.width / 2,
                              y: proxy.size.height / 2)
            }
        }
        .frame(height: 14)
        .frame(width: 120)
        .accessibilityIdentifier("dj.master.phase")
        .coachGlow(identifier: "dj.master.phase")
    }
}

/// A 44 pt-minimum channel fader (trim gain, §35.4). Unity at the top, full
/// kill at the bottom; the whole 34×64 strip is the drag surface. `identifier`
/// carries the §53.11 accessibility identifier.
private struct ChannelFader: View {
    let label: String
    let value: Float
    var identifier: String?
    let onChanged: (Float) -> Void

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { proxy in
                let height = proxy.size.height
                ZStack(alignment: .bottom) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(Color.white.opacity(0.55))
                        .frame(height: max(6, height * Self.clamp01(CGFloat(value))))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { gesture in
                        let t = Self.clamp01((1 - gesture.location.y / height))
                        onChanged(Float(t))
                    }
                )
            }
            .frame(width: 34, height: 64)
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(width: 44, height: 44, alignment: .top)
        .accessibilityIdentifierIfPresent(identifier)
        .coachGlow(identifier: identifier)
    }

    private static func clamp01(_ value: CGFloat) -> CGFloat {
        max(0, min(1, value))
    }
}

/// Apply a §53.11 accessibility identifier only when one is supplied.
private extension View {
    func accessibilityIdentifierIfPresent(_ identifier: String?) -> some View {
        if let identifier {
            return AnyView(self.accessibilityIdentifier(identifier))
        }
        return AnyView(self)
    }
}
