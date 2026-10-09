import SwiftUI
import TonearmWatchCore
import TonearmWatchProtocol

/// Watch redesign §5 N3 — Now Playing › More. Switching device is a deliberate, named action
/// (never implied by which list you came from); download-to-watch with its ring; Shuffle and Repeat
/// as two pills; Go to Album.
struct WatchNowPlayingMoreView: View {
    let shown: WatchTarget
    @Binding var pendingDownloadTrackID: String?

    @ObservedObject private var player = WatchPlayer.shared
    @ObservedObject private var remote = WatchRemotePlayer.shared
    @ObservedObject private var coordinator = WatchPlaybackCoordinator.shared
    @ObservedObject private var model = WatchAppAssembly.shared.model
    @Environment(\.dismiss) private var dismiss

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

    @ViewBuilder
    private var switchRow: some View {
        if shown == .iPhone {
            let local = localAlternative
            Button {
                Task { await moveToWatch(local) }
            } label: {
                rowLabel(systemImage: "applewatch", title: "Play on Apple Watch",
                         detail: local.isEmpty ? String(localized: "Not downloaded to this watch")
                                               : String(localized: "Continues from here, on this watch"))
            }
            .disabled(local.isEmpty)
            .accessibilityIdentifier("watch.more.switchTarget")
        } else {
            Text("Playback is local to this Apple Watch.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func rowLabel(systemImage: String, title: LocalizedStringKey, detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).frame(width: 22).foregroundStyle(WatchPalette.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// The phone's current queue window, mapped to what is downloaded here, starting at the current
    /// item — so "Play on Apple Watch" keeps your place where it can.
    private var localAlternative: [WatchTrackSnapshot] {
        guard let state = remote.state else { return [] }
        let start = max(0, state.queueIndex - state.queueWindowStartIndex)
        let window = state.queueWindow.dropFirst(min(start, state.queueWindow.count))
        return window.compactMap { model.track(id: $0.trackID.rawValue) }
    }

    private func moveToWatch(_ tracks: [WatchTrackSnapshot]) async {
        guard let first = tracks.first else { return }
        let elapsed = remote.state?.predictedElapsed(at: Date()) ?? 0
        let sameItem = remote.state?.currentItem?.trackID.rawValue == first.id
        remote.pause()
        WatchPlayer.shared.startLocalPlayback(tracks: tracks, selectedTrackID: first.id,
                                              seekTo: sameItem && elapsed > 0 ? elapsed : nil)
        dismiss()
    }


    // MARK: Shuffle / repeat (addresses the shown engine)

    private var isShuffled: Bool {
        shown == .iPhone ? (remote.state?.snapshot.shuffleEnabled ?? false) : player.isShuffled
    }

    /// One display enum for both engines (`TonearmWatchCore` and `TonearmWatchProtocol` each define
    /// a `WatchRepeatMode`).
    private enum RepeatDisplay { case off, all, one }

    private var repeatMode: RepeatDisplay {
        if shown == .iPhone {
            switch remote.state?.snapshot.repeatMode ?? .off {
            case .off: return .off
            case .all: return .all
            case .one: return .one
            }
        }
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

    private func toggleShuffle() {
        if shown == .iPhone { remote.setShuffle(!isShuffled) } else { player.toggleShuffle() }
    }

    private func cycleRepeat() {
        guard shown == .iPhone else { player.cycleRepeat(); return }
        let next: TonearmWatchProtocol.WatchRepeatMode = switch repeatMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
        remote.setRepeat(next)
    }

    private var albumRef: WatchAlbumLink? {
        guard shown == .thisWatch, let album = player.currentTrack?.albumTitle, !album.isEmpty,
              model.album(id: album) != nil else { return nil }
        return WatchAlbumLink(id: album)
    }
}

struct WatchAlbumLink: Hashable {
    let id: String
}
