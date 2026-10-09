import SwiftUI
import TonearmWatchCore

/// Installed audio only. All transfer management belongs to the iPhone.
struct WatchDownloadsView: View {
    @ObservedObject private var model = WatchAppAssembly.shared.model

    var body: some View {
        List {
            Section("Downloaded audio") {
                NavigationLink(value: WatchNav.songs) {
                    WatchCollectionRowLabel(title: String(localized: "Songs"),
                        detail: String(localized: "\(model.tracks.count) playable tracks"), tintKey: "songs")
                }.watchCardRow().accessibilityIdentifier("watch.songs")
            }
            Section("Downloaded collections") {
                NavigationLink(value: WatchNav.playlists) {
                    WatchCollectionRowLabel(title: String(localized: "Playlists"),
                        detail: String(localized: "\(model.playlists.count) playlists"), tintKey: "playlists")
                }.watchCardRow().accessibilityIdentifier("watch.downloads.playlists")
                NavigationLink(value: WatchNav.albums) {
                    WatchCollectionRowLabel(title: String(localized: "Albums"),
                        detail: String(localized: "\(model.albums.count) albums"), tintKey: "albums")
                }.watchCardRow().accessibilityIdentifier("watch.downloads.albums")
            }
            Section {
                Text("Send or remove music using My Music → On My Watch on your iPhone.")
                    .font(.caption2).foregroundStyle(.secondary)
                NavigationLink(value: WatchNav.storage) {
                    Label("Storage & Diagnostics", systemImage: "internaldrive")
                }.watchCardRow().accessibilityIdentifier("watch.downloads.storage")
            }
        }
        .listStyle(.plain).navigationTitle("On This Watch")
        .task { await model.refresh() }
    }
}
