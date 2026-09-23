// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tonearm (Platterhead DJ) — Copyright (C) 2026 John Arley Burns.
// See ../../LICENSE.

import AppKit
import SwiftUI
import TonearmCore

/// The `MenuBarExtra` status-item panel (native-mac-app-plan.md §3, mockup
/// §m-extra) — a *second*, additional surface alongside the real system menu
/// bar, not a replacement for it.
struct MacNowPlayingMenuView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer

    /// Local scrub position while actively dragging — avoids fighting the
    /// player's own `currentTime` publisher mid-drag (same pattern as the
    /// iOS `NowPlayingView` scrubber).
    @State private var scrubPosition: Double?
    @State private var isScrubbing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let row = player.currentTrack {
                Text(row.track.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(row.album?.artist ?? row.artist?.name ?? "")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)

                if player.duration > 0 {
                    Slider(
                        value: Binding(
                            get: { scrubPosition ?? player.currentTime },
                            set: { scrubPosition = $0 }),
                        in: 0...player.duration,
                        onEditingChanged: { editing in
                            isScrubbing = editing
                            if !editing, let position = scrubPosition {
                                player.seek(to: position)
                                scrubPosition = nil
                            }
                        })
                        .controlSize(.mini)
                }
            } else {
                Text("Not Playing").font(.system(size: 13, weight: .semibold))
            }

            HStack(spacing: 18) {
                Button { player.previous() } label: { Image(systemName: "backward.fill") }
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                }
                Button { player.next() } label: { Image(systemName: "forward.fill") }
            }
            .buttonStyle(.plain)

            Divider()

            Button("Show Platterhead") { appState.showNowPlaying = true }

            Button("Quit Platterhead") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 220)
    }
}
