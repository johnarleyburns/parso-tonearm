import SwiftUI

struct SourceDetailView: View {
    let source: Source
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var tracks: [TrackRow] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                navRow
                hero
                ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, row in
                    Button {
                        player.play(tracks: tracks, startAt: idx, source: .source(source))
                    } label: {
                        TrackRowView(row: row)
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(Palette.hairline)
                }
                Text("Streams from archive.org · played tracks stay in the cache\nand work offline until space is needed")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.ink3)
                    .multilineTextAlignment(.center)
                    .padding(.top, 16)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 160)
        }
        .background(Palette.sourcesBackground.ignoresSafeArea())
        .foregroundStyle(Palette.ink)
        .navigationBarBackButtonHidden()
        .task { tracks = await appState.tracks(for: source) }
    }

    private var navRow: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15)).foregroundStyle(Palette.brass)
                    .frame(width: 33, height: 33).glassSurface(cornerRadius: 16.5)
            }
            Spacer()
            Menu {
                Button("Remove Source", role: .destructive) {
                    Task { await appState.deleteSource(source); dismiss() }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15)).foregroundStyle(Palette.brass)
                    .frame(width: 33, height: 33).glassSurface(cornerRadius: 16.5)
            }
        }
        .padding(.top, 8)
    }

    private var hero: some View {
        VStack(spacing: 0) {
            ArtworkView(identifier: source.iaIdentifier, seed: source.title, cornerRadius: 18)
                .frame(width: 168, height: 168)
                .shadow(color: .black.opacity(0.55), radius: 20, y: 12)
            Text(source.title)
                .font(.system(size: 18, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.top, 13)
            if let artist = tracks.first?.album?.artist {
                Text(artist).font(.system(size: 14)).foregroundStyle(Palette.brass).padding(.top, 3)
            }
            badge.padding(.top, 9)
            cta.padding(.top, 14)
            if let id = source.iaIdentifier, !id.isEmpty,
               let iaURL = ShareURLBuilder.url(identifier: id) {
                Link(destination: iaURL) {
                    HStack(spacing: 5) {
                        Image(systemName: "safari")
                        Text("View on archive.org")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.ink3)
                }
                .padding(.top, 10)
            }
        }
        .padding(.bottom, 6)
    }

    private var badge: some View {
        HStack(spacing: 6) {
            Circle().fill(Palette.ok).frame(width: 6, height: 6)
            Text(badgeText).font(.system(size: 10.5, weight: .semibold)).kerning(0.5)
        }
        .foregroundStyle(Palette.ink2)
        .padding(.horizontal, 11).padding(.vertical, 5)
        .glassSurface(cornerRadius: 12)
    }

    private var badgeText: String {
        if source.kind == .local { return "on device" }
        return "archive.org · \(source.licenseText ?? "streams permitted")"
    }

    private var cta: some View {
        HStack(spacing: 10) {
            Button { player.play(tracks: tracks, startAt: 0, source: .source(source)) } label: {
                ctaLabel(icon: "play.fill", title: "Play")
            }
            Button {
                player.shuffle = true
                player.play(tracks: tracks.shuffled(), startAt: 0, source: .source(source))
            } label: {
                ctaLabel(icon: "shuffle", title: "Shuffle")
            }
        }
    }

    private func ctaLabel(icon: String, title: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
            Text(title)
        }
        .font(.system(size: 14.5, weight: .semibold))
        .foregroundStyle(Palette.brass)
        .frame(maxWidth: .infinity).frame(height: 42)
        .glassSurface(cornerRadius: 21)
    }
}
