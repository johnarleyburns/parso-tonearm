import SwiftUI
import TonearmCore

/// The first Listen content: curated starter blends rendered synchronously from
/// `StarterBlendCatalog`. It needs no model, index, sign-in or library, and
/// each card's Play/failure/retry state is independent of the others.
struct StarterBlendsSection: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        StarterBlendsList(playback: appState.starterBlends)
    }
}

private struct StarterBlendsList: View {
    @ObservedObject var playback: StarterBlendPlayback

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Starter Blends")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(StarterBlendCatalog.blends) { blend in
                        StarterBlendCard(blend: blend, state: playback.state(for: blend),
                                         play: { Task { await playback.play(blend) } })
                    }
                }
                .padding(.horizontal, 2)
            }
            HStack(spacing: 6) {
                Text(StarterBlendCatalog.attribution)
                Link("Credits", destination: StarterBlendCatalog.creditsURL)
                    .accessibilityIdentifier("listen.starter.credits")
            }
            .font(Typography.caption)
            .foregroundStyle(Palette.inkSecondary)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .accessibilityIdentifier("listen.starter")
    }
}

private struct StarterBlendCard: View {
    let blend: StarterBlend
    let state: StarterBlendPlayback.CardState
    let play: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(hue: blend.artworkHue, saturation: 0.55, brightness: 0.45))
                Image(systemName: blend.artworkSymbol)
                    .foregroundStyle(.white)
                    .font(Typography.title)
            }
            .frame(width: 132, height: 132)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(blend.title).font(Typography.callout).lineLimit(1)
                Text(blend.subtitle).font(Typography.caption).foregroundStyle(Palette.inkSecondary).lineLimit(2)
                if case .failed(let message) = state {
                    Text(message).font(Typography.caption).foregroundStyle(Palette.danger)
                }
                switch state {
                case .buffering:
                    Text("Buffering…").font(Typography.caption).foregroundStyle(Palette.inkSecondary)
                case .blending:
                    Text("Playing with blends").font(Typography.caption).foregroundStyle(Palette.inkSecondary)
                case .unavailable(let reason, let retryable):
                    Text(reason).font(Typography.caption).foregroundStyle(Palette.danger)
                    Text(retryable ? "Playing in order without blends. Retry to blend again."
                                   : "Playing in order without blends. This blend can't be streamed.")
                        .font(Typography.caption).foregroundStyle(Palette.inkSecondary)
                        .accessibilityIdentifier("listen.starter.sequential.\(blend.id)")
                default:
                    EmptyView()
                }
            }
            .padding(.top, 7)
            Button(action: play) {
                if state == .loading || state == .buffering {
                    ProgressView()
                } else if isFailed {
                    Label("Retry", systemImage: "arrow.clockwise")
                } else {
                    Label("Play", systemImage: "play.fill")
                }
            }
            .buttonStyle(.bordered)
            .disabled(state == .loading || state == .buffering || isPermanent)
            .padding(.top, 6)
            .accessibilityIdentifier("listen.starter.play.\(blend.id)")
        }
        .frame(width: 132, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(blend.title). \(blend.subtitle)")
        .accessibilityHint(hint)
        .accessibilityAction(named: Text(isFailed ? "Retry" : "Play"), play)
    }

    private var isFailed: Bool {
        switch state {
        case .failed, .unavailable(_, true): true
        default: false
        }
    }
    /// A permanently unavailable asset offers no retry: nothing about trying again can change it.
    private var isPermanent: Bool { if case .unavailable(_, false) = state { true } else { false } }
    private var hint: LocalizedStringKey {
        isFailed ? "Couldn't load this blend. Double tap to retry." : "Double tap to play this blend."
    }
}
