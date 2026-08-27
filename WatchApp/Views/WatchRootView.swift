import SwiftUI
import TonearmWatchCore
import TonearmWatchProtocol

struct WatchRootView: View {
    @ObservedObject private var model = WatchAppAssembly.shared.model
    @ObservedObject private var chrome = WatchAppAssembly.shared.chrome
    @ObservedObject private var player = WatchPlayer.shared

    var body: some View {
        List {
            WatchConnectionBanner(banner: chrome.banner)
                .listRowBackground(Color.clear)

            nowPlayingChip

            NavigationLink(value: WatchNav.search) {
                WatchCollectionRow(
                    title: chrome.showsConnectedFeatures ? "Search iPhone Library" : "Search Downloads",
                    subtitle: chrome.showsConnectedFeatures ? "Tracks, albums, playlists" : "On this watch",
                    systemImage: "magnifyingglass")
            }
            .accessibilityIdentifier("watch.search")

            if chrome.showsConnectedFeatures {
                NavigationLink(value: WatchNav.phonePlaylists) {
                    WatchCollectionRow(title: "Playlists", subtitle: "Browse on iPhone",
                                       systemImage: "music.note.list")
                }
                .accessibilityIdentifier("watch.playlists")

                NavigationLink(value: WatchNav.downloads) {
                    WatchCollectionRow(title: "Downloads", subtitle: downloadsSubtitle,
                                       systemImage: "arrow.down.circle")
                }
                .accessibilityIdentifier("watch.downloads")
            } else {
                offlineDownloadRows
            }
        }
        .listStyle(.carousel)
        .navigationTitle("Platterhead")
        .accessibilityIdentifier("watch.root")
        .task { await model.refresh() }
    }

    @ViewBuilder
    private var offlineDownloadRows: some View {
        NavigationLink(value: WatchNav.playlists) {
            WatchCollectionRow(title: "Playlists", subtitle: "\(model.playlists.count) downloaded",
                               systemImage: "music.note.list")
        }
        .accessibilityIdentifier("watch.playlists")

        NavigationLink(value: WatchNav.albums) {
            WatchCollectionRow(title: "Albums", subtitle: "\(model.albums.count) downloaded",
                               systemImage: "square.stack")
        }

        NavigationLink(value: WatchNav.songs) {
            WatchCollectionRow(title: "Tracks", subtitle: "\(model.tracks.count) downloaded",
                               systemImage: "music.note")
        }

        NavigationLink(value: WatchNav.storage) {
            WatchCollectionRow(title: "Storage", subtitle: storageSubtitle, systemImage: "internaldrive")
        }
        .accessibilityIdentifier("watch.downloads")
    }

    private var downloadsSubtitle: String {
        let bytes = model.storage?.readyBytes ?? 0
        return bytes > 0 ? "\(model.tracks.count) tracks · \(WatchTimeFmt.megabytes(bytes))"
                         : "\(model.tracks.count) tracks"
    }

    private var storageSubtitle: String {
        guard let storage = model.storage, storage.readyBytes > 0 else { return "Manage storage" }
        return "\(model.tracks.count) tracks · \(WatchTimeFmt.megabytes(storage.readyBytes))"
    }

    @ViewBuilder
    private var nowPlayingChip: some View {
        if let track = player.currentTrack {
            Button {
                player.navigateToNowPlaying()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.system(size: 16))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title)
                            .font(.system(.caption, design: .default))
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        Text("Now Playing")
                            .font(.system(.caption2))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12))
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("watch.nowPlaying")
            // Lets the watch smoke confirm playback survived a Close without reopening the sheet.
            .accessibilityValue(player.isPlaying ? "playing" : "paused")
        }
    }
}

enum WatchNav: Hashable {
    case search
    case downloads
    case playlists
    case albums
    case songs
    case storage
    case playlist(String)
    case album(String)
    case phonePlaylists
    case phoneCollection(WatchCollectionRef)
    case recovery
}
