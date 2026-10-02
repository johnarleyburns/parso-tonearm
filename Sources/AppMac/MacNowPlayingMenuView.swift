// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tonearm (Platterhead DJ) — Copyright (C) 2026 John Arley Burns.
// See ../../LICENSE.

import AppKit
import SwiftUI
import TonearmCore

/// The `MenuBarExtra` panel — a mini player that stays available while the
/// main window is closed: artwork, title, scrubber, transport and a way back
/// to the window. An additional surface alongside the system menu bar.
struct MacNowPlayingMenuView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer
    @Environment(\.openWindow) private var openWindow

    /// Local scrub position while dragging, so the player's own `currentTime`
    /// updates don't fight the drag.
    @State private var scrubPosition: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let row = player.currentTrack {
                HStack(spacing: 10) {
                    ArtworkView(trackRow: row, seed: row.album?.title ?? row.track.title,
                                cornerRadius: Metrics.cornerSmall, thumbnailMaxDimension: 48)
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.track.title).font(Typography.calloutStrong).lineLimit(1)
                        Text(row.album?.artist ?? row.artist?.name ?? "")
                            .font(Typography.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }

                if !player.isAmbient, player.duration > 0 {
                    Slider(
                        value: Binding(
                            get: { scrubPosition ?? player.currentTime },
                            set: { scrubPosition = $0 }),
                        in: 0...player.duration,
                        onEditingChanged: { editing in
                            if !editing, let position = scrubPosition {
                                player.seek(to: position)
                                scrubPosition = nil
                            }
                        })
                        .controlSize(.mini)
                        .accessibilityLabel("Playback position")
                }
            } else {
                Text("Not Playing").font(Typography.calloutStrong)
            }

            HStack(spacing: 22) {
                Button { player.previous() } label: { Image(systemName: "backward.fill") }
                    .accessibilityLabel("Previous Track")
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button { player.next() } label: { Image(systemName: "forward.fill") }
                    .accessibilityLabel("Next Track")
            }
            .font(Typography.headline)
            .buttonStyle(.plain)
            .disabled(player.currentTrack == nil)
            .frame(maxWidth: .infinity)

            Divider()

            Button("Build a Mix…") { openMainWindow { appState.requestBuildAMix() } }
            Button("Show Platterhead") { openMainWindow { appState.showNowPlaying = player.currentTrack != nil } }
            Button("Quit Platterhead") { NSApplication.shared.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .padding(12)
        .frame(width: 260)
    }

    private func openMainWindow(_ then: () -> Void) {
        openWindow(id: TonearmMacApp.mainWindowID)
        NSApplication.shared.activate()
        then()
    }
}
