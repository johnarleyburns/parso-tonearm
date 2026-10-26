import SwiftUI
import TonearmCore

/// The detail destination shared by the Now Playing card and queue connectors.
struct TransitionDetailSheet: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var transitionPrep: TransitionPrepService
    let presentation: TransitionPresentation
    var note: String?

    var body: some View {
        NavigationStack {
            if let plan = player.transitionPlan, presentation.phase != .notPlanned,
               plan.fromTrackID == presentation.outgoingTrackID, plan.toTrackID == presentation.incomingTrackID {
                WhyThisTransitionView(plan: plan, preparationState: presentation.preparation)
            } else {
                List {
                    Section("Why This Transition?") {
                        Text(note ?? presentation.connectorLabel)
                        if let detail = presentation.fallbackDetail {
                            Text(detail).foregroundStyle(Palette.inkSecondary)
                        }
                    }
                }
                .navigationTitle("Why This Transition?")
            }
        }
    }
}

/// Compact tappable card under the progress bar; expands to a two-track card only while blending.
struct TransitionCard: View {
    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showDetail = false

    private var presentation: TransitionPresentation { player.transitionPresentation }

    private func row(_ id: Int64?) -> TrackRow? {
        guard let id else { return nil }
        return ([player.currentTrack].compactMap { $0 } + player.queue).first { $0.track.id == id }
    }

    var body: some View {
        let p = presentation
        if p.showsConnector, p.phase != .notPlanned {
            Button { showDetail = true } label: {
                VStack(alignment: .leading, spacing: 6) {
                    if let t = timeline {
                        timelineBody(t, p)
                    } else if p.isBlendingNow {
                        blendingBody(p)
                    } else {
                        Text(p.cardTitle)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail = p.fallbackDetail {
                            Text(detail).font(Typography.caption).foregroundStyle(Palette.inkSecondary)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.hairline))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel(p))
            .accessibilityValue(accessibilityValue(p))
            .accessibilityHint("Shows why this transition was chosen")
            .accessibilityIdentifier("np.transitionCard")
            .sheet(isPresented: $showDetail) { TransitionDetailSheet(presentation: p) }
        }
    }

    private var overlap: OverlapCardModel? {
        OverlapCardModel(presentation, snapshot: player.displayedTransitionSnapshot, position: player.currentTime)
    }

    private var timeline: BlendTimelineModel? {
        BlendTimelineModel(presentation, position: player.currentTime)
    }

    private func timelineBody(_ t: BlendTimelineModel, _ p: TransitionPresentation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(t.statusText).font(Typography.caption.weight(.semibold)).foregroundStyle(Palette.ink)
                Spacer()
                Text(t.styleLabel).font(Typography.caption).foregroundStyle(Palette.accent)
            }
            timelineRow(label: "OUT", title: row(p.outgoingTrackID)?.track.title, text: t.outgoingText,
                        progress: t.progress, filled: false)
            timelineRow(label: "IN", title: row(p.incomingTrackID)?.track.title, text: t.incomingText,
                        progress: t.progress, filled: true)
        }
    }

    private func timelineRow(label: String, title: String?, text: String, progress: Double, filled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label + (title.map { " · " + $0 } ?? ""))
                .font(Typography.caption.weight(.bold)).foregroundStyle(Palette.inkSecondary).lineLimit(1)
            ProgressView(value: progress).tint(filled ? Palette.accent : Palette.inkSecondary)
            Text(text).font(Typography.caption).foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityHidden(true)
    }

    private func accessibilityLabel(_ p: TransitionPresentation) -> String {
        if let t = timeline {
            return t.spokenSummary(outgoingTitle: row(p.outgoingTrackID)?.track.title,
                                   incomingTitle: row(p.incomingTrackID)?.track.title)
        }
        if let m = overlap {
            return m.spokenSummary(outgoingTitle: row(p.outgoingTrackID)?.track.title,
                                   incomingTitle: row(p.incomingTrackID)?.track.title)
        }
        return p.accessibilityLabel(outgoingTitle: row(p.outgoingTrackID)?.track.title,
                                    incomingTitle: row(p.incomingTrackID)?.track.title)
    }

    private func accessibilityValue(_ p: TransitionPresentation) -> String {
        // The overlap summary already carries style, phase and timing; keep the value quiet then.
        timeline == nil && overlap == nil ? p.accessibilityValue : ""
    }

    @ViewBuilder
    private func blendingBody(_ p: TransitionPresentation) -> some View {
        if let m = overlap {
            HStack {
                Text(m.title).font(Typography.caption.weight(.semibold)).foregroundStyle(Palette.ink)
                Spacer()
                Text(m.styleLabel).font(Typography.caption).foregroundStyle(Palette.accent)
            }
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            layout {
                deckColumn(label: "OUT", id: p.outgoingTrackID, caption: m.outgoingCaption, fade: 1 - (m.progress ?? 0.5))
                deckColumn(label: "IN", id: p.incomingTrackID, caption: m.incomingCaption, fade: m.progress ?? 0.5)
            }
            PhaseRail(current: m.rail, progress: m.progress)
        } else {
            Text(p.cardTitle).font(Typography.caption).foregroundStyle(Palette.ink)
        }
    }

    private func deckColumn(label: String, id: Int64?, caption: String, fade: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let r = row(id) {
                    ArtworkView(trackRow: r, seed: r.album?.title ?? r.track.title, cornerRadius: 4)
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: "music.note").frame(width: 32, height: 32)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(label).font(Typography.caption.weight(.bold)).foregroundStyle(Palette.inkSecondary)
                    Text(row(id)?.track.title ?? "").font(Typography.caption).foregroundStyle(Palette.ink).lineLimit(1)
                }
            }
            Silhouette(level: fade, filled: label == "IN")
            if !caption.isEmpty {
                Text(caption).font(Typography.caption).foregroundStyle(Palette.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }
}

/// Bar silhouette whose height follows the deck's fade level; decorative, so hidden from VoiceOver.
struct Silhouette: View {
    let level: Double
    let filled: Bool
    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<16, id: \.self) { i in
                let wave = 0.45 + 0.55 * abs(sin(Double(i) * 0.9))
                Capsule()
                    .fill(filled ? Palette.accent : Palette.inkSecondary)
                    .frame(height: max(3, 24 * wave * min(max(level, 0.1), 1)))
            }
        }
        .frame(height: 24)
        .accessibilityHidden(true)
    }
}

/// Outgoing / overlap-now / incoming rail. The active stage is marked by weight and a filled
/// marker, not by color alone.
struct PhaseRail: View {
    let current: OverlapCardModel.Rail
    let progress: Double?

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(OverlapCardModel.Rail.allCases, id: \.self) { stage in
                    let on = stage == current
                    Text(stage.label)
                        .font(Typography.caption.weight(on ? .bold : .regular))
                        .foregroundStyle(on ? Palette.ink : Palette.inkSecondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .background(on ? Palette.accent.opacity(0.18) : Color.clear, in: Capsule())
                        .overlay(Capsule().strokeBorder(on ? Palette.accent : Palette.hairline, lineWidth: on ? 2 : 1))
                }
            }
            if let progress {
                ProgressView(value: progress).tint(Palette.accent)
            }
        }
        .accessibilityHidden(true)
    }
}
