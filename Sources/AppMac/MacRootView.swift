// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tonearm (Platterhead DJ) — Copyright (C) 2026 John Arley Burns.
// See ../../LICENSE.

import SwiftUI
import TonearmCore

/// The Mac main window: `NavigationSplitView` + toolbar (native-mac-app-
/// plan.md §3), not a bottom tab dock — Settings moves to the `Settings { }`
/// scene (⌘,) per the plan's own recommendation, so the sidebar only carries
/// Listen and My Music.
struct MacRootView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer
    @State private var selection: MacSidebarDestination? = .listen

    var body: some View {
        NavigationSplitView {
            List(MacSidebarDestination.allCases, selection: $selection) { destination in
                Label(destination.title, systemImage: destination.systemImage)
                    .tag(destination)
            }
            .navigationTitle("Platterhead")
        } detail: {
            VStack(spacing: 0) {
                Group {
                    switch selection ?? .listen {
                    case .listen: ListenView()
                    case .myMusic: MyMusicView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                MacTransportBar()
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .sheet(isPresented: Binding(
            get: { !appState.didOnboard },
            set: { if $0 == false { appState.didOnboard = true } })) {
            OnboardingView()
                .frame(minWidth: 640, minHeight: 520)
        }
        .sheet(isPresented: $appState.showCreatePlaylist) {
            CreatePlaylistSheet()
        }
        .sheet(isPresented: $appState.showNowPlaying) {
            NowPlayingView()
                .frame(minWidth: 420, minHeight: 520)
        }
        .sheet(isPresented: $appState.showWatchSettings) {
            WatchSettingsView()
        }
        .sheet(isPresented: $appState.showAddSource) {
            AddSourceSheet()
                .frame(minWidth: 420, minHeight: 480)
        }
        .sheet(isPresented: $appState.showAddRemoteLibrary) {
            AddServerSheet()
                .frame(minWidth: 420, minHeight: 420)
        }
        .sheet(item: $appState.pickedFolder) { url in
            AddFolderSheet(folderURL: url, folderBookmark: appState.pickedFolderBookmark)
        }
    }
}

enum MacSidebarDestination: String, CaseIterable, Identifiable, Hashable {
    case listen, myMusic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .listen: return "Listen"
        case .myMusic: return "My Music"
        }
    }

    var systemImage: String {
        switch self {
        case .listen: return "play.circle"
        case .myMusic: return "music.note.list"
        }
    }
}

/// A compact persistent transport bar along the bottom of the main window —
/// the Mac equivalent of the iPhone `GlassDock`'s now-playing strip, minus
/// its tab-bar-shaped chrome (mockup §w-listen/§w-library).
private struct MacTransportBar: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer

    var body: some View {
        if let row = player.currentTrack {
            HStack(spacing: 12) {
                ArtworkView(image: nil, seed: row.track.title, cornerRadius: 4)
                    .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 1) {
                    Text(row.track.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Text(row.album?.artist ?? row.artist?.name ?? "")
                        .font(.system(size: 11)).foregroundStyle(Palette.ink2).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button { player.previous() } label: {
                    Image(systemName: "backward.fill")
                }
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                }
                Button { player.next() } label: {
                    Image(systemName: "forward.fill")
                }
                Button { appState.showNowPlaying = true } label: {
                    Image(systemName: "chevron.up")
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 14))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}
