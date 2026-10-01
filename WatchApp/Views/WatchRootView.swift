import SwiftUI
import TonearmWatchCore
import TonearmWatchProtocol

struct WatchRootView: View {
    @ObservedObject private var model = WatchAppAssembly.shared.model
    @ObservedObject private var chrome = WatchAppAssembly.shared.chrome

    var body: some View {
        List {
            WatchConnectionBanner(banner: chrome.banner)
                .listRowBackground(Color.clear)

            WatchNowPlayingChip()

            NavigationLink(value: WatchNav.search) {
                WatchCollectionRow(
                    title: chrome.showsConnectedFeatures ? String(localized: "Search iPhone Library") : String(localized: "Search Downloads"),
                    subtitle: chrome.showsConnectedFeatures ? String(localized: "Tracks, albums, playlists") : String(localized: "On this watch"),
                    systemImage: "magnifyingglass")
            }
            .accessibilityIdentifier("watch.search")

            if chrome.showsConnectedFeatures {
                NavigationLink(value: WatchNav.phonePlaylists) {
                    WatchCollectionRow(title: String(localized: "Playlists"), subtitle: String(localized: "Browse on iPhone"),
                                       systemImage: "music.note.list")
                }
                .accessibilityIdentifier("watch.playlists")

                NavigationLink(value: WatchNav.downloads) {
                    WatchCollectionRow(title: String(localized: "Downloads"), subtitle: downloadsSubtitle,
                                       systemImage: "arrow.down.circle")
                }
                .accessibilityIdentifier("watch.downloads")
            } else {
                offlineDownloadRows
            }
        }
#if os(watchOS)
        .listStyle(.carousel)
#else
        .listStyle(.plain)
#endif
        .navigationTitle("Platterhead")
        .accessibilityIdentifier("watch.root")
        .task { await model.refresh() }
    }

    @ViewBuilder
    private var offlineDownloadRows: some View {
        NavigationLink(value: WatchNav.playlists) {
            WatchCollectionRow(title: String(localized: "Playlists"), subtitle: String(localized: "\(model.playlists.count) downloaded"),
                               systemImage: "music.note.list")
        }
        .accessibilityIdentifier("watch.playlists")

        NavigationLink(value: WatchNav.albums) {
            WatchCollectionRow(title: String(localized: "Albums"), subtitle: String(localized: "\(model.albums.count) downloaded"),
                               systemImage: "square.stack")
        }
        .accessibilityIdentifier("watch.albums")

        NavigationLink(value: WatchNav.songs) {
            WatchCollectionRow(title: String(localized: "Tracks"), subtitle: String(localized: "\(model.tracks.count) downloaded"),
                               systemImage: "music.note")
        }
        .accessibilityIdentifier("watch.songs")

        NavigationLink(value: WatchNav.storage) {
            WatchCollectionRow(title: String(localized: "Storage"), subtitle: storageSubtitle, systemImage: "internaldrive")
        }
        .accessibilityIdentifier("watch.downloads")
    }

    private var downloadsSubtitle: String {
        let bytes = model.storage?.readyBytes ?? 0
        return bytes > 0 ? String(localized: "\(model.tracks.count) tracks · \(WatchTimeFmt.megabytes(bytes))")
                         : String(localized: "\(model.tracks.count) tracks")
    }

    private var storageSubtitle: String {
        guard let storage = model.storage, storage.readyBytes > 0 else { return String(localized: "Manage storage") }
        return String(localized: "\(model.tracks.count) tracks · \(WatchTimeFmt.megabytes(storage.readyBytes))")
    }

}

/// The persistent Now Playing chip — the first row of the root list. It is its **own** `View` with
/// its own `@ObservedObject`s so that a churny remote/target update invalidates only the chip, not
/// `WatchRootView.body`: observing those objects from the root itself re-realised the `.carousel`
/// rows and dropped below-fold rows from the accessibility tree (Phase 9 deferral). The chip
/// reflects whichever engine owns transport — local (`thisWatch`) or the predicted iPhone state —
/// and tapping it reopens Now Playing for that target (§7.1).
struct WatchNowPlayingChip: View {
    @ObservedObject private var player = WatchPlayer.shared
    @ObservedObject private var remote = WatchRemotePlayer.shared
    @ObservedObject private var coordinator = WatchPlaybackCoordinator.shared

    var body: some View {
        if let chip = current {
            Button {
                player.navigateToNowPlaying()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: chip.glyph)
                        .font(WatchTypography.iconMedium)
                        .foregroundStyle(.tint)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(chip.title)
                            .font(.system(.caption, design: .default))
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        Text(chip.subtitle)
                            .font(.system(.caption2))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: chip.isPlaying ? "pause.fill" : "play.fill")
                        .font(WatchTypography.iconSmall)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("watch.nowPlaying")
            .accessibilityLabel("Now Playing, \(chip.title), \(chip.subtitle)")
            // Lets the watch smoke confirm playback survived a Close without reopening the sheet.
            .accessibilityValue(chip.isPlaying ? "playing" : "paused")
            .accessibilityHint("Opens Now Playing")
        }
    }

    private struct Chip {
        var title: String
        var subtitle: String
        var glyph: String
        var isPlaying: Bool
    }

    /// The chip follows whichever engine currently owns transport.
    private var current: Chip? {
        if coordinator.target == .iPhone, let item = remote.state?.currentItem {
            return Chip(title: item.title, subtitle: String(localized: "On iPhone"),
                        glyph: "iphone", isPlaying: remote.state?.isPlaying ?? false)
        }
        if let track = player.currentTrack {
            return Chip(title: track.title, subtitle: String(localized: "On Apple Watch"),
                        glyph: "applewatch", isPlaying: player.isPlaying)
        }
        return nil
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
