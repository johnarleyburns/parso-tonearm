import SwiftUI
import TonearmWatchCore

/// Watch redesign §5 N3 — Now Playing › More. Switching device is a deliberate, named action
/// (never implied by which list you came from); download-to-watch with its ring; Shuffle and Repeat
/// as two pills; Go to Album.
struct WatchNowPlayingMoreView: View {
    let shown: WatchTarget
    @Binding var pendingDownloadTrackID: String?

    @ObservedObject private var player = WatchPlayer.shared
    @ObservedObject private var model = WatchAppAssembly.shared.model

    var body: some View {
        List {
            switchRow
            Section {
                HStack(spacing: 6) {
                    Button { toggleShuffle() } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .buttonStyle(WatchPillButtonStyle(kind: isShuffled ? .primary : .secondary, small: true))
                    .accessibilityValue(isShuffled ? "on" : "off")
                    .accessibilityIdentifier("watch.more.shuffle")
                    Button { cycleRepeat() } label: {
                        Label(repeatTitle, systemImage: repeatMode == .one ? "repeat.1" : "repeat")
                    }
                    .buttonStyle(WatchPillButtonStyle(kind: repeatMode == .off ? .secondary : .primary, small: true))
                    .accessibilityIdentifier("watch.more.repeat")
                }
                .listRowBackground(Color.clear)
            }
            if let album = albumRef {
                NavigationLink(value: album) {
                    Label("Go to Album", systemImage: "square.stack")
                }
                .accessibilityIdentifier("watch.more.album")
            }
        }
        .navigationTitle("More")
        .navigationDestination(for: WatchAlbumLink.self) { link in
            WatchAlbumDetailView(albumID: link.id)
        }
    }

    // MARK: Switch device

    private var switchRow: some View {
        Text("Playback is local to this Apple Watch.")
            .font(.caption2).foregroundStyle(.secondary)
    }

    // MARK: Shuffle / repeat

    private var isShuffled: Bool { player.isShuffled }

    private enum RepeatDisplay { case off, all, one }

    private var repeatMode: RepeatDisplay {
        switch player.repeatMode {
        case .off: return .off
        case .all: return .all
        case .one: return .one
        }
    }

    private var repeatTitle: LocalizedStringKey {
        switch repeatMode {
        case .off: "Repeat"
        case .all: "All"
        case .one: "One"
        }
    }

    private func toggleShuffle() { player.toggleShuffle() }

    private func cycleRepeat() { player.cycleRepeat() }

    private var albumRef: WatchAlbumLink? {
        guard shown == .thisWatch, let album = player.currentTrack?.albumTitle, !album.isEmpty,
              model.album(id: album) != nil else { return nil }
        return WatchAlbumLink(id: album)
    }
}

struct WatchAlbumLink: Hashable {
    let id: String
}
