import SwiftUI

/// The §35A Beat FX block below the crossfader (§41.9b rule 7): the post-fader
/// beat-synced **ECHO** — the one Beat FX the five transitions require (plan
/// 5.5, FR-TRANS-4). Channel selector + ON toggle, the five beat lengths and a
/// depth slider; the block is always visible on the tablet, so no drawer or
/// flyout is needed here (the §42.7c compact treatment owns those). The ON
/// button carries the `dj.fx.echo` identifier the regression suite drives.
struct BeatFXBlock: View {
    @ObservedObject var model: WorkspaceModel

    @State private var echoDeck: Deck = .a

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("BEAT FX")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                channelSelector
            }

            HStack(spacing: 5) {
                ForEach(Array(WorkspaceModel.ClubGeometry.echoBeats.enumerated()), id: \.offset) { _, beats in
                    Button {
                        model.setEchoBeats(echoDeck, beats: beats)
                    } label: {
                        Text(echoLabel(beats))
                            .font(.system(size: 9, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 26)
                            .background(
                                model.echoBeats(echoDeck) == beats
                                    ? Color.accentColor.opacity(0.28)
                                    : Color.white.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(
                                model.echoBeats(echoDeck) == beats
                                    ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Text("DEPTH")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                GeometryReader { proxy in
                    let width = proxy.size.width
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.10))
                            .frame(height: 5)
                        Capsule()
                            .fill(Color.accentColor.opacity(0.9))
                            .frame(width: max(4, width * CGFloat(model.echoDepth(echoDeck))), height: 5)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0).onChanged { value in
                            model.setEchoDepth(echoDeck,
                                               depth: Float(Self.clampUnit(value.location.x / width)))
                        }
                    )
                }
                .frame(height: 5)
                onToggle
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.02)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    /// The per-channel selector (mockup `ipad/07`'s "ECHO · A") — the echo is
    /// post-fader and per channel (§35A.1), so the block names which strip it
    /// is sending.
    private var channelSelector: some View {
        HStack(spacing: 4) {
            ForEach([Deck.a, .b], id: \.self) { deck in
                Button {
                    echoDeck = deck
                } label: {
                    Text(deck == .a ? "A" : "B")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 26, height: 22)
                        .background(
                            echoDeck == deck ? Color.accentColor.opacity(0.28)
                                             : Color.white.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(echoDeck == deck ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The ON/OFF toggle — the §35A.2 momentary-or-latched on switch. Carries
    /// the `dj.fx.echo` identifier the regression suite targets (§53.11).
    private var onToggle: some View {
        let on = model.echoEnabled(echoDeck)
        return Button {
            model.setEchoEnabled(echoDeck, enabled: !on)
        } label: {
            Text(on ? "ON" : "OFF")
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(
                    on ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(on ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("dj.fx.echo")
        .coachGlow(identifier: "dj.fx.echo")
    }

    private func echoLabel(_ beats: Double) -> String {
        beats < 1 ? String(format: "1/%d", Int(1 / beats)) : "\(Int(beats))"
    }

    private static func clampUnit(_ value: CGFloat) -> CGFloat {
        max(0, min(1, value))
    }
}
