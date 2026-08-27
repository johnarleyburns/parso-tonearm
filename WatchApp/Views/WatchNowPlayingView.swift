import SwiftUI
import TonearmWatchCore

struct WatchNowPlayingView: View {
    @ObservedObject private var player = WatchPlayer.shared
    @Environment(\.dismiss) private var dismiss
    @State private var crownValue: Double = 0.5

    var body: some View {
        content
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Close only dismisses the sheet — playback continues, and the root's Now
                    // Playing chip stays available to reopen it (§7, "Close must not stop playback").
                    Button("Close") { dismiss() }
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
                if let hint = player.routeHint {
                    Text(hint)
                        .font(.system(.caption2))
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .accessibilityIdentifier("watch.now.routeHint")
                }
                Text(track.title)
                    .font(.system(.headline, design: .default))
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .accessibilityIdentifier("watch.now.title")

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
                        .accessibilityIdentifier("watch.now.elapsed")
                        .accessibilityValue(WatchTimeFmt.mmss(player.elapsed))
                    Spacer()
                    Text("-\(WatchTimeFmt.mmss(max(0, player.duration - player.elapsed)))")
                        .accessibilityIdentifier("watch.now.remaining")
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
                    .accessibilityIdentifier("watch.now.upNext")

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
                Image(systemName: "backward.fill").font(.system(size: 24))
            }
            .accessibilityIdentifier("watch.now.previous")

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 32))
            }
            .accessibilityIdentifier("watch.now.playPause")
            // Exposes real transport state ("playing"/"paused") so the UI smoke test can confirm
            // playback actually started, not just that the button is tappable.
            .accessibilityValue(player.isPlaying ? "playing" : "paused")

            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill").font(.system(size: 24))
            }
            .accessibilityIdentifier("watch.now.next")
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

    private func subtitle(for track: WatchTrackSnapshot) -> String {
        var parts: [String] = []
        if !track.artist.isEmpty { parts.append(track.artist) }
        if let d = track.durationSeconds { parts.append(WatchTimeFmt.mmss(d)) }
        return parts.joined(separator: " · ")
    }
}
