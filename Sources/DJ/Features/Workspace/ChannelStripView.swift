import SwiftUI

/// One §41.9b channel strip: TRIM (compact) → HI → MID → LOW → FILTER above a
/// vertical channel fader and a CUE button (rule 1). Each control carries its
/// §53.11 accessibility identifier.
struct ChannelStripView: View {
    @ObservedObject var model: WorkspaceModel
    let deck: Deck

    private var name: String { deck == .a ? "a" : "b" }

    private var eq: (low: Float, mid: Float, high: Float) {
        deck == .a ? (model.eqALow, model.eqAMid, model.eqAHigh)
                   : (model.eqBLow, model.eqBMid, model.eqBHigh)
    }

    private var filter: Float { deck == .a ? model.filterA : model.filterB }
    private var channelGain: Float { deck == .a ? model.channelA : model.channelB }

    var body: some View {
        VStack(spacing: 3) {
            Text(deck == .a ? "CH A" : "CH B")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(deck == .a ? .purple : .cyan)

            // TRIM — the compact control at the strip head (§41.9b geometry).
            Text("TRIM")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
            TrimKnob(value: channelGain) {
                model.setChannelFader(deck, gain: $0)
            }

            EQKnob(label: "HI", value: eq.high,
                   identifier: "dj.deck.\(name).eq.high") {
                model.setEQKnobs(deck, low: eq.low, mid: eq.mid, high: $0)
            }
            EQKnob(label: "MID", value: eq.mid,
                   identifier: "dj.deck.\(name).eq.mid") {
                model.setEQKnobs(deck, low: eq.low, mid: $0, high: eq.high)
            }
            EQKnob(label: "LOW", value: eq.low,
                   identifier: "dj.deck.\(name).eq.low") {
                model.setEQKnobs(deck, low: $0, mid: eq.mid, high: eq.high)
            }

            // FILTER — a knob in the strip (§41.9b rule 6), not a slider.
            EQKnob(label: "FILTER", value: filter,
                   identifier: "dj.deck.\(name).filter") {
                model.setFilter(deck, knob: $0)
            }

            VerticalSlider(value: channelGain,
                           identifier: "dj.deck.\(name).fader") {
                model.setChannelFader(deck, gain: $0)
            }
            .frame(height: 70)

            // **The CUE at the foot of a channel strip is headphone cue**
            // (PFL), on every club mixer ever built — §41.9b rule 1 lists it in
            // that position for exactly that reason. It used to fire the CDJ
            // cue *point* here, which is the deck's transport control and lives
            // with PLAY (rule 3): a club-trained hand reaching for pre-listen
            // would have jumped the track to its cue point instead, mid-set.
            CueButton(model: model, deck: deck)
                .frame(height: 40)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The compact TRIM control at the channel strip's head (§41.9b geometry —
/// five full knobs would exceed the column's height, so the one control not
/// used *during* a transition renders compact). Maps the channel fader gain.
struct TrimKnob: View {
    let value: Float
    let onChanged: (Float) -> Void

    @State private var dragStart: Float?

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.08))
            Circle()
                .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.white.opacity(0.9))
                .frame(width: 2, height: 7)
                .offset(y: -10)
                .rotationEffect(.degrees(Double(value) * 90))
        }
        .frame(width: 28, height: 28)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    if dragStart == nil { dragStart = value }
                    let start = dragStart ?? value
                    let delta = Float(gesture.translation.height) / 80
                    let clamped = min(1, max(0, start - delta))
                    onChanged(clamped)
                }
                .onEnded { _ in dragStart = nil }
        )
    }
}
