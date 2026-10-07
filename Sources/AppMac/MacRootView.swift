// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tonearm (Platterhead DJ) — Copyright (C) 2026 John Arley Burns.
// See ../../LICENSE.

import SwiftUI
import TonearmCore

/// The Mac main window: a `NavigationSplitView` whose sidebar carries the
/// iPhone's tabs (Listen, My Music) — Settings is the app's `Settings { }`
/// scene (⌘,) — with a toolbar (Add Music, Build a Mix, search), a transport
/// bar along the bottom and Now Playing as a trailing inspector. Every
/// app-wide sheet and importer comes from the same `AppPresentations` the
/// iPhone uses, so the two shells cannot drift apart.
struct MacRootView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer
    @FocusState private var isSearchFocused: Bool
    @State private var isDropTargeted = false

    /// Mirrors `appState.tab` (Mood, Find, and Settings have no Mac sidebar
    /// row, so they map to Listen). Shared code such as "switch to My Music
    /// after an import" keeps working because it writes `appState.tab`.
    private var selection: Binding<MacSidebarDestination?> {
        Binding(
            get: { appState.tab == .myMusic ? .myMusic : .listen },
            set: { appState.tab = $0 == .myMusic ? .myMusic : .listen })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                Section {
                    ForEach(MacSidebarDestination.allCases) { destination in
                        Label(destination.title, systemImage: destination.systemImage)
                            .tag(destination)
                            .accessibilityIdentifier("sidebar.\(destination.rawValue)")
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .navigationTitle("Platterhead")
        } detail: {
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    Group {
                        switch selection.wrappedValue ?? .listen {
                        case .listen: ListenView()
                        case .myMusic: MyMusicView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    AppStatusBanners()
                }
                MacTransportBar()
            }
            .background(Palette.libraryBackground)
            .inspector(isPresented: $appState.showNowPlaying) {
                NowPlayingView()
                    .inspectorColumnWidth(min: 340, ideal: 380, max: 480)
            }
        }
        .frame(minWidth: 960, minHeight: 620)
        .searchable(text: $appState.searchText, placement: .toolbar, prompt: "Search your music")
        .searchFocused($isSearchFocused)
        .onChange(of: appState.searchText) { _, text in
            guard !text.isEmpty, appState.tab != .myMusic else { return }
            appState.tab = .myMusic
        }
        .onChange(of: appState.macSearchFocusRequest) { _, _ in
            appState.tab = .myMusic
            isSearchFocused = true
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    MacAddMusicMenuItems()
                } label: {
                    Label("Add Music", systemImage: "plus")
                }
                .help("Add a folder, audio files or a remote library")
                .accessibilityIdentifier("toolbar.addMusic")

                Button {
                    appState.requestBuildAMix()
                } label: {
                    Label("Build a Mix", systemImage: "waveform.path.ecg")
                }
                .help("Build a 15, 30 or 60 minute mix")
                .accessibilityIdentifier("toolbar.buildMix")

                Button {
                    appState.showNowPlaying.toggle()
                } label: {
                    Label("Now Playing", systemImage: "sidebar.trailing")
                }
                .help("Show or hide Now Playing")
                .accessibilityIdentifier("toolbar.nowPlaying")
            }
        }
        // Drop a folder or audio files anywhere on the window to add them —
        // the same flow as Add Local Folder / Add Audio Files. A web link
        // (an archive.org or Jamendo page dragged from Safari) is added as a
        // library, like the iPhone's Share extension.
        .dropDestination(for: URL.self) { urls, _ in
            if let link = urls.first(where: { !$0.isFileURL }) {
                Task { await appState.handleSharedSourceURL(link.absoluteString) }
                return true
            }
            let importable = AppImport.importable(urls)
            guard !importable.isEmpty else { return false }
            AppImport.route(importable, asSMB: false, appState: appState)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Palette.accent, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .toastLayer(bottomInset: 72)
        .environmentObject(appState.transitionPrepService)
        .tint(Palette.accent)
        .modifier(AppPresentations())
    }
}

enum MacSidebarDestination: String, CaseIterable, Identifiable, Hashable {
    case listen, myMusic

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .listen: "Listen"
        case .myMusic: "My Music"
        }
    }

    var systemImage: String {
        switch self {
        case .listen: "play.circle"
        case .myMusic: "music.note.list"
        }
    }
}

/// The Add Music choices — the iPhone's Add sheet as a native menu, used by
/// the toolbar and the File menu.
struct MacAddMusicMenuItems: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Button("Add Local Folder…") { appState.pendingImport = .folder }
        Button("Add Audio Files…") { appState.pendingImport = .files }
        Divider()
        Button("Add Remote Library…") { appState.showAddRemoteLibrary = true }
        Button("Add Internet Archive or Jamendo…") { appState.showAddSource = true }
    }
}

/// The persistent transport bar along the bottom of the main window — the
/// Mac equivalent of the iPhone mini player: artwork and title (click for Now
/// Playing), previous / play-pause / next, a scrubber, shuffle, repeat and
/// volume.
private struct MacTransportBar: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer
    @State private var scrubPosition: Double?

    var body: some View {
        if let row = player.currentTrack {
            HStack(spacing: 14) {
                Button { appState.showNowPlaying.toggle() } label: {
                    HStack(spacing: 10) {
                        ArtworkView(trackRow: row, seed: row.album?.title ?? row.track.title,
                                    cornerRadius: Metrics.cornerSmall,
                                    thumbnailMaxDimension: 44)
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.track.title).font(Typography.calloutStrong).lineLimit(1)
                            Text(row.album?.artist ?? row.artist?.name ?? "")
                                .font(Typography.caption)
                                .foregroundStyle(Palette.inkSecondary)
                                .lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(width: 240, alignment: .leading)
                .help("Show Now Playing")
                .accessibilityIdentifier("transport.nowPlaying")

                HStack(spacing: 16) {
                    Button { player.toggleShuffle() } label: {
                        Image(systemName: "shuffle")
                            .foregroundStyle(player.shuffle ? Palette.accent : Palette.inkSecondary)
                    }
                    .accessibilityLabel("Shuffle")
                    Button { player.previous() } label: { Image(systemName: "backward.fill") }
                        .accessibilityLabel("Previous Track")
                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(Typography.headline)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                    .accessibilityIdentifier("transport.playpause")
                    Button { player.next() } label: { Image(systemName: "forward.fill") }
                        .accessibilityLabel("Next Track")
                    Button { player.cycleRepeatMode() } label: {
                        Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                            .foregroundStyle(player.repeatMode == .off ? Palette.inkSecondary : Palette.accent)
                    }
                    .accessibilityLabel("Repeat")
                }
                .buttonStyle(.plain)

                if !player.isAmbient, player.duration > 0 {
                    HStack(spacing: 8) {
                        Text(TimeFmt.mmss(scrubPosition ?? player.currentTime))
                            .font(Typography.caption.monospacedDigit())
                            .foregroundStyle(Palette.inkTertiary)
                        Slider(value: Binding(
                            get: { scrubPosition ?? player.currentTime },
                            set: { scrubPosition = $0 }),
                               in: 0...max(player.duration, 1),
                               onEditingChanged: { editing in
                                   if !editing, let position = scrubPosition {
                                       player.seek(to: position)
                                       scrubPosition = nil
                                   }
                               })
                            .controlSize(.small)
                            .accessibilityLabel("Playback position")
                        Text(TimeFmt.mmss(player.duration))
                            .font(Typography.caption.monospacedDigit())
                            .foregroundStyle(Palette.inkTertiary)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Spacer()
                }

                HStack(spacing: 6) {
                    Image(systemName: "speaker.fill").foregroundStyle(Palette.inkTertiary)
                    Slider(value: Binding(
                        get: { Double(player.outputLevel) },
                        set: { player.setOutputLevel(Float($0)) }), in: 0...1)
                        .controlSize(.small)
                        .frame(width: 90)
                        .accessibilityLabel("Volume")
                }
            }
            .font(Typography.body)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }
}
