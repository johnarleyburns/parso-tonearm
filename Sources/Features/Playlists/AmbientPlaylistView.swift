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
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 16)
                Text("Continuous nature sounds for focus, relaxation, or sleep.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink2)
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
                    .font(.system(size: 15)).foregroundStyle(Palette.brass)
                    .frame(width: 33, height: 33).glassSurface(cornerRadius: 16.5)
            }
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
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)

                VStack(alignment: .leading, spacing: 3) {
                    Text(ambient.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text(ambient.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink2)
                    HStack(spacing: 4) {
                        Circle().fill(Palette.ok).frame(width: 5, height: 5)
                        Text("CC0 Public Domain")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.ink3)
                        Text("· built-in")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.ink3)
                    }
                    .padding(.top, 2)
                }
                Spacer()
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Palette.brass)
            }
            .padding(12)
            .glassSurface(cornerRadius: 18)
        }
        .buttonStyle(.plain)
    }
}
