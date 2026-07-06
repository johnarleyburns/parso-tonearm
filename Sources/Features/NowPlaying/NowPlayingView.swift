import SwiftUI

struct NowPlayingView: View {
    @EnvironmentObject var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false

    var body: some View {
        ZStack {
            npBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                Capsule().fill(Color.white.opacity(0.35))
                    .frame(width: 36, height: 5).padding(.top, 8)

                ArtworkView(seed: player.currentTrack?.album?.title ?? "np", cornerRadius: 16)
                    .aspectRatio(1, contentMode: .fit)
                    .shadow(color: .black.opacity(0.55), radius: 30, y: 16)
                    .padding(.top, 22)

                meta.padding(.top, 22)
                scrubber.padding(.top, 20)
                transport.padding(.top, 16)
                Spacer()
            }
            .padding(.horizontal, 24)
            .foregroundStyle(.white)
        }
        .presentationDragIndicator(.hidden)
    }

    private var npBackground: some View {
        LinearGradient(stops: [
            .init(color: Color(hex: 0x8A5A24), location: 0),
            .init(color: Color(hex: 0x59391A), location: 0.34),
            .init(color: Color(hex: 0x241708), location: 0.78),
            .init(color: Color(hex: 0x120B05), location: 1)
        ], startPoint: .top, endPoint: .bottom)
    }

    private var meta: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentTrack?.track.title ?? "Nothing playing")
                    .font(.system(size: 17, weight: .bold)).lineLimit(1)
                Text(player.currentTrack?.album?.artist ?? "")
                    .font(.system(size: 14)).foregroundStyle(.white.opacity(0.62))
            }
            Spacer()
            Image(systemName: "ellipsis")
                .frame(width: 30, height: 30)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    private var scrubber: some View {
        VStack(spacing: 7) {
            GeometryReader { geo in
                let w = geo.size.width
                let playedFrac = player.duration > 0 ? min(1, player.currentTime / player.duration) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.16))
                    Capsule().fill(Color.white.opacity(0.30))
                        .frame(width: w * player.cachedFraction)
                    Capsule().fill(Color.white.opacity(0.9))
                        .frame(width: w * (isScrubbing ? scrubValue : playedFrac))
                }
                .frame(height: 7)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            isScrubbing = true
                            scrubValue = max(0, min(1, v.location.x / w))
                        }
                        .onEnded { _ in
                            player.seek(to: scrubValue * player.duration)
                            isScrubbing = false
                        }
                )
            }
            .frame(height: 7)

            HStack {
                Text(TimeFmt.mmss(player.currentTime))
                Spacer()
                Text(qualityChip)
                    .font(.system(size: 9.5, weight: .bold)).kerning(0.8)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.3)))
                Spacer()
                Text("-" + TimeFmt.mmss(max(0, player.duration - player.currentTime)))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))
            .monospacedDigit()
        }
    }

    private var qualityChip: String {
        let codec = player.currentTrack?.track.codec ?? "AUDIO"
        if player.currentTrack?.asset?.kind == .remote {
            return "\(codec) · ● \(player.cachePercent)% CACHED"
        }
        return codec
    }

    private var transport: some View {
        HStack(spacing: 14) {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 20))
                    .frame(width: 52, height: 52).background(.ultraThinMaterial, in: Circle())
            }
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 26))
                    .frame(width: 66, height: 66).background(.ultraThinMaterial, in: Circle())
            }
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 20))
                    .frame(width: 52, height: 52).background(.ultraThinMaterial, in: Circle())
            }
        }
        .foregroundStyle(.white)
    }
}
