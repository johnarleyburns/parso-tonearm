import SwiftUI
import TonearmCore

struct WatchNowPlayingView: View {
    @ObservedObject private var player = WatchPlayer.shared
    @State private var showUpNext = false
    @State private var crownValue: Double = 0.5

    var body: some View {
        ZStack {
            content
            if player.showFetchOverlay {
                WatchFetchOverlay(
                    trackTitle: player.fetchingTrackTitle,
                    progress: player.fetchProgress,
                    onCancel: { player.cancelFetch() })
            }
        }
        .navigationTitle("Now Playing")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") {
                    player.currentTrack = nil
                    player.isPlaying = false
                    player.clearPosition()
                }
            }
        }
        .onAppear { crownValue = player.volume }
        .focusable(true)
        .digitalCrownRotation(
            $crownValue,
            from: 0.0, through: 1.0,
            by: 0.02,
            sensitivity: .low,
            isContinuous: true
        )
        .onChange(of: crownValue) { _, newValue in
            player.volume = newValue
        }
    }

    @ViewBuilder
    private var content: some View {
        if let track = player.currentTrack {
            VStack(spacing: 0) {
                Text(track.track.title)
                    .font(.system(.headline, design: .default))
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)

                Text(subtitle(for: track))
                    .font(.system(.caption2))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.top, 4)

                Spacer(minLength: 8)

                progressBar
                    .padding(.horizontal, 16)

                HStack {
                    Text(WatchTimeFmt.mmss(player.elapsed))
                    Spacer()
                    Text("-\(WatchTimeFmt.mmss(max(0, player.duration - player.elapsed)))")
                }
                .font(.system(.caption2))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 2)

                transport
                    .padding(.top, 8)
                    .padding(.bottom, 8)

                HStack(spacing: 12) {
                    NavigationLink(destination: WatchUpNextView()) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 14))
                    }
                    .accessibilityIdentifier("np.upnext")

                    Spacer()

                    volumeControl
                }
                .padding(.horizontal, 16)
            }
        } else {
            Text("Nothing Playing")
                .font(.system(.headline, design: .default))
                .foregroundStyle(.secondary)
                .padding(.top, 40)
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.secondary.opacity(0.3))
                    .frame(height: 4)
                Capsule()
                    .fill(.tint)
                    .frame(width: max(0, geo.size.width * (player.duration > 0 ? player.elapsed / player.duration : 0)), height: 4)
            }
        }
        .frame(height: 4)
    }

    private var transport: some View {
        HStack(spacing: 24) {
            Button {
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 24))
            }
            .accessibilityIdentifier("np.prev")

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 32))
            }
            .accessibilityIdentifier("np.playpause")

            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 24))
            }
            .accessibilityIdentifier("np.next")
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private var volumeControl: some View {
        HStack(spacing: 4) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Slider(value: $player.volume, in: 0...1)
                .tint(.white.opacity(0.5))
                .frame(width: 60)
        }
    }

    private func subtitle(for track: TrackRow) -> String {
        var parts: [String] = []
        if let artist = track.album?.artist ?? track.artist?.name { parts.append(artist) }
        if let d = track.track.durationSec {
            parts.append(WatchTimeFmt.mmss(d))
        }
        return parts.joined(separator: " · ")
    }
}
