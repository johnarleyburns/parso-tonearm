import SwiftUI
import WatchKit
import TonearmWatchCore
import TonearmWatchProtocol

/// Watch redesign §5 H1–H4 — Home. Now Playing first (the hero follows playback on *either*
/// device), then exactly four doors in a fixed order: Search, Playlists, Albums, On This Watch.
/// One layout in both scopes — with the phone away the same doors show what's on the watch. The
/// connection state is a quiet chip at the end, moving to the top only while it changes scope.
struct WatchRootView: View {
    @ObservedObject private var model = WatchAppAssembly.shared.model
    @ObservedObject private var chrome = WatchAppAssembly.shared.chrome

    var body: some View {
        List {
            if !connected {
                statusChip
                    .listRowBackground(Color.clear)
            }

            // Its own view with its own observers so churny playback updates invalidate only the
            // hero, not the whole list (see memory: carousel List + observers).
            WatchHomeHero()
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

            if model.tracks.isEmpty && model.playlists.isEmpty {
                firstRunCard
                    .listRowBackground(Color.clear)
            }

            door(.search, title: connected ? "Search" : "Search This Watch",
                 detail: nil, systemImage: "magnifyingglass", identifier: "watch.search")
            door(connected ? .phonePlaylists : .playlists, title: "Playlists",
                 detail: connected ? nil : String(localized: "\(model.playlists.count) on this watch"),
                 systemImage: "music.note.list", identifier: "watch.playlists")
            door(connected ? .phoneAlbums : .albums, title: "Albums",
                 detail: connected ? nil : String(localized: "\(model.albums.count) on this watch"),
                 systemImage: "square.stack", identifier: "watch.albums")
            door(.downloads, title: "On This Watch", detail: onWatchDetail,
                 systemImage: "applewatch", identifier: "watch.downloads")

            if connected {
                statusChip
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Platterhead")
        .accessibilityIdentifier("watch.root")
        .task { await model.refresh() }
    }

    private var connected: Bool { chrome.showsConnectedFeatures }

    private func door(_ nav: WatchNav, title: LocalizedStringKey, detail: String?,
                      systemImage: String, identifier: String) -> some View {
        NavigationLink(value: nav) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.callout)
                    .foregroundStyle(WatchPalette.accent)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body)
                    if let detail {
                        Text(detail).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .listRowBackground(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(WatchPalette.surface))
        .accessibilityIdentifier(identifier)
    }

    private var onWatchDetail: String {
        let count = model.tracks.count
        let bytes = model.storage?.readyBytes ?? 0
        if count == 0 { return String(localized: "Nothing downloaded") }
        let songs = String(localized: "\(count) songs")
        return bytes > 0 ? "\(songs) · \(WatchTimeFmt.megabytes(bytes))" : songs
    }

    @ViewBuilder
    private var statusChip: some View {
        switch chrome.banner {
        case .connected:
            WatchStatusChip(title: String(localized: "iPhone connected"), tone: .good)
                .accessibilityIdentifier("watch.status")
        case .temporarilyUnavailable:
            WatchStatusChip(title: String(localized: "Reconnecting to iPhone…"), tone: .warning)
                .accessibilityIdentifier("watch.status")
        case .unavailable:
            WatchStatusChip(title: String(localized: "iPhone not nearby"), tone: .warning)
                .accessibilityIdentifier("watch.status")
        case .incompatible:
            WatchStatusChip(title: String(localized: "Update Platterhead on iPhone"), tone: .failure)
                .accessibilityIdentifier("watch.status")
        }
    }

    /// H4 — empty states always end in an action.
    private var firstRunCard: some View {
        VStack(spacing: 6) {
            Image(systemName: "applewatch").font(.title3).foregroundStyle(WatchPalette.accent)
            Text("Nothing on this watch yet").font(.headline).multilineTextAlignment(.center)
            if connected {
                Text("Your iPhone is nearby — play from its library now, or download a playlist for runs.")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                NavigationLink(value: WatchNav.phonePlaylists) { Text("Browse iPhone") }
                    .buttonStyle(.watchPrimarySmall)
                    .accessibilityIdentifier("watch.home.browsePhone")
            } else {
                Text("On iPhone, open Platterhead › Settings › Apple Watch and choose music to download.")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(WatchPalette.surface))
        .accessibilityIdentifier("watch.home.empty")
    }
}

/// H1 hero — the player in miniature. Shown while anything is loaded on either engine; follows
/// `WatchNowPlayingResolver`, and its play/pause addresses the engine it shows. Tap → Now Playing.
struct WatchHomeHero: View {
    @ObservedObject private var player = WatchPlayer.shared
    @ObservedObject private var remote = WatchRemotePlayer.shared
    @ObservedObject private var coordinator = WatchPlaybackCoordinator.shared

    var body: some View {
        if let hero = current {
            HStack(alignment: .top, spacing: 6) {
                Button {
                    player.navigateToNowPlaying()
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            WatchArtTile(image: hero.image, tint: hero.tint, size: 38)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(hero.title).font(.headline).lineLimit(1)
                                Text(hero.subtitle).font(.caption2)
                                    .foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        HStack(spacing: 6) {
                            WatchTargetChip(systemImage: hero.target == .iPhone ? "iphone" : "applewatch",
                                            title: hero.target == .iPhone ? String(localized: "iPhone")
                                                                          : String(localized: "Watch"),
                                            tone: .onArtwork)
                            WatchProgressHairline(elapsed: hero.elapsed, duration: hero.duration, showsTimes: false)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("watch.nowPlaying")
                .accessibilityLabel(Text("Now Playing, \(hero.title), \(hero.target == .iPhone ? String(localized: "on iPhone") : String(localized: "on Apple Watch"))"))
                .accessibilityValue(hero.isPlaying ? "playing" : "paused")
                .accessibilityHint(Text("Opens Now Playing"))

                Button {
                    WKInterfaceDevice.current().play(.click)
                    hero.toggle()
                } label: {
                    Image(systemName: hero.isPlaying ? "pause.fill" : "play.fill")
                        .font(.callout.weight(.bold))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.white.opacity(0.22)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(hero.isPlaying ? "Pause" : "Play"))
                .accessibilityIdentifier("watch.home.heroPlayPause")
                .handGestureShortcut(.primaryAction)
            }
            .padding(10)
            .background(
                LinearGradient(colors: [hero.tint.opacity(0.9), hero.tint.opacity(0.35)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private struct Hero {
        var title: String
        var subtitle: String
        var target: WatchTarget
        var isPlaying: Bool
        var elapsed: Double
        var duration: Double
        var tint: Color
        var image: UIImage?
        var toggle: () -> Void
    }

    private var current: Hero? {
        let shown = WatchNowPlayingResolver.shown(
            local: .init(hasItem: player.currentTrack != nil, isPlaying: player.isPlaying),
            remote: .init(hasItem: remote.state?.currentItem != nil, isPlaying: remote.state?.isPlaying ?? false),
            target: coordinator.target)
        switch shown {
        case .iPhone:
            guard let state = remote.state, let item = state.currentItem else { return nil }
            return Hero(title: item.title, subtitle: item.artist.isEmpty ? (state.collectionTitle ?? "") : item.artist,
                        target: .iPhone, isPlaying: state.isPlaying,
                        elapsed: state.predictedElapsed(at: Date()), duration: item.durationSeconds ?? 0,
                        tint: Color(watchHex: state.snapshot.artworkColorHex) ?? WatchPalette.accent,
                        image: nil, toggle: { remote.togglePlayPause() })
        case .thisWatch:
            guard let track = player.currentTrack else { return nil }
            return Hero(title: track.title, subtitle: track.artist, target: .thisWatch,
                        isPlaying: player.isPlaying, elapsed: player.elapsed, duration: player.duration,
                        tint: player.artworkTint ?? WatchPalette.accent, image: player.artwork,
                        toggle: { player.togglePlayPause() })
        case nil:
            return nil
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
    case phoneAlbums
    case phoneCollection(WatchCollectionRef)
    case recovery
}
