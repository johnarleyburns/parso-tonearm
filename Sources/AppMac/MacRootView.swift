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

    /// Mirrors `appState.tab` (`.settings` has no Mac sidebar row — Settings
    /// is its own `Settings { }` scene, ⌘, — so it maps to `.listen`). A
    /// plain local `@State` here would silently strand every existing
    /// `appState.tab = .myMusic` call site (e.g. RootView.swift's "switch to
    /// My Music after import", and TonearmMacCommands' Edit > Find in
    /// Library) — real app-wide code with no effect on Mac.
    private var selection: Binding<MacSidebarDestination?> {
        Binding(
            get: {
                switch appState.tab {
                case .myMusic: return .myMusic
                case .dj: return .dj
                default: return .listen
                }
            },
            set: {
                switch $0 {
                case .myMusic: appState.tab = .myMusic
                case .dj: appState.tab = .dj
                case .listen, .none: appState.tab = .listen
                }
            })
    }

    var body: some View {
        NavigationSplitView {
            List(MacSidebarDestination.allCases, selection: selection) { destination in
                Label(destination.title, systemImage: destination.systemImage)
                    .tag(destination)
            }
            .navigationTitle("Platterhead")
        } detail: {
            VStack(spacing: 0) {
                Group {
                    switch selection.wrappedValue ?? .listen {
                    case .listen: ListenView()
                    case .myMusic: MyMusicView()
                    case .dj: DJView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !appState.isPerformanceSurfaceFullScreen {
                    MacTransportBar()
                }
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        // Plan §3: "Sidebar + toolbar ... search field, view-mode toggles"
        // — the real payoff over Catalyst's UIKit-flavored nav bar. A native
        // `.searchable` toolbar field, wired to the same `appState.searchText`
        // LibraryView's own search already reacts to (App/AppState.swift),
        // not a second, disconnected search state. Typing switches to My
        // Music — the only place search results actually render.
        .searchable(text: $appState.searchText, placement: .toolbar, prompt: "Search your music")
        .onChange(of: appState.searchText) { _, text in
            guard !text.isEmpty, appState.tab != .myMusic else { return }
            appState.tab = .myMusic
        }
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
    case listen, myMusic, dj

    var id: String { rawValue }

    var title: String {
        switch self {
        case .listen: return "Listen"
        case .myMusic: return "My Music"
        case .dj: return "DJ"
        }
    }

    var systemImage: String {
        switch self {
        case .listen: return "play.circle"
        case .myMusic: return "music.note.list"
        case .dj: return "slider.horizontal.3"
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
