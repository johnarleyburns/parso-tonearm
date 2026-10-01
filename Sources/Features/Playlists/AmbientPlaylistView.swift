import SwiftUI
import TonearmCore

struct AmbientPlaylistView: View {
    @EnvironmentObject var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                navRow
                Text("Ambient")
                    .font(Typography.title)
                    .foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 16)
                Text("Continuous nature sounds for focus, relaxation, or sleep.")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)

                ForEach(BuiltInContentProvider.tracks, id: \.channelId) { ambient in
                    ambientTile(ambient).padding(.top, 14)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 160)
        }
        .background(Palette.sourcesBackground.ignoresSafeArea())
        .navigationBarBackButtonHidden()
    }

    private var navRow: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(Typography.body).foregroundStyle(Palette.accent)
                    .frame(width: 33, height: 33).glassSurface(cornerRadius: 16.5)
            }
            .accessibilityLabel("Back")
            Spacer()
        }
        .padding(.top, 8)
    }

    private func ambientTile(_ ambient: AmbientTrack) -> some View {
        Button {
            player.playAmbient(channelId: ambient.channelId)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    if let videoURL = BuiltInContentProvider.bundledVideoURL(forChannelId: ambient.channelId) {
                        LoopingVideoView(url: videoURL, isPlaying: false)
                            .disabled(true)
                            .frame(width: 68, height: 68)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    } else {
                        ArtworkView(seed: ambient.title, cornerRadius: 14)
                            .frame(width: 68, height: 68)
                    }
                }
                .frame(width: 68, height: 68)
                .shadow(color: Palette.ink.opacity(0.3), radius: 8, y: 4)

                VStack(alignment: .leading, spacing: 3) {
                    Text(ambient.title)
                        .font(Typography.body)
                        .foregroundStyle(Palette.ink)
                    Text(ambient.artist)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkSecondary)
                    HStack(spacing: 4) {
                        Circle().fill(Palette.success).frame(width: 5, height: 5)
                        Text("CC0 Public Domain")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.inkTertiary)
                        Text("· built-in")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.inkTertiary)
                    }
                    .padding(.top, 2)
                }
                Spacer()
                Image(systemName: "play.circle.fill")
                    .font(Typography.title)
                    .foregroundStyle(Palette.accent)
            }
            .padding(12)
            .glassSurface(cornerRadius: 18)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ambient.track.\(ambient.channelId)")
    }
}
