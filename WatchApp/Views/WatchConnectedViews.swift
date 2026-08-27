import SwiftUI
import TonearmWatchCore
import TonearmWatchProtocol

/// The "Downloads" scope reached from the connected home — the same local library the offline home
/// shows directly.
struct WatchDownloadsView: View {
    @ObservedObject private var model = WatchAppAssembly.shared.model

    var body: some View {
        List {
            NavigationLink(value: WatchNav.playlists) {
                WatchCollectionRow(title: "Playlists", subtitle: "\(model.playlists.count) downloaded",
                                   systemImage: "music.note.list")
            }
            NavigationLink(value: WatchNav.albums) {
                WatchCollectionRow(title: "Albums", subtitle: "\(model.albums.count) downloaded",
                                   systemImage: "square.stack")
            }
            NavigationLink(value: WatchNav.songs) {
                WatchCollectionRow(title: "Tracks", subtitle: "\(model.tracks.count) downloaded",
                                   systemImage: "music.note")
            }
            NavigationLink(value: WatchNav.storage) {
                WatchCollectionRow(title: "Storage",
                                   subtitle: WatchTimeFmt.megabytes(model.storage?.readyBytes ?? 0),
                                   systemImage: "internaldrive")
            }
        }
        .listStyle(.carousel)
        .navigationTitle("Downloads")
        .task { await model.refresh() }
    }
}

/// W1 → "Playlists · Browse on iPhone" — the connected playlist index, paged from the phone.
struct WatchPhonePlaylistsView: View {
    @State private var rows: [WatchResultRow] = []
    @State private var loaded = false

    var body: some View {
        List {
            if !loaded {
                HStack { ProgressView(); Text("Loading…").font(.system(.caption2)) }
            } else if rows.isEmpty {
                WatchEmptyStateView(icon: "music.note.list", title: "No Playlists",
                                    message: "Playlists on your iPhone will appear here.")
            } else {
                ForEach(rows) { row in
                    if let ref = row.collectionRef {
                        NavigationLink(value: WatchNav.phoneCollection(ref)) {
                            WatchCollectionRow(title: row.title,
                                               subtitle: row.trackCount.map { "\($0) tracks" } ?? "Playlist",
                                               systemImage: "music.note.list")
                        }
                    }
                }
            }
        }
        .listStyle(.carousel)
        .navigationTitle("Playlists")
        .task {
            rows = await WatchAppAssembly.shared.browsePhonePlaylists()
            loaded = true
        }
    }
}

/// W3 — a phone collection viewed from the watch. Play and Download are distinct, explicit actions;
/// the primary action always says "Play on iPhone" so a connected row never implies watch audio.
struct WatchPhoneCollectionView: View {
    let ref: WatchCollectionRef

    @ObservedObject private var player = WatchPlayer.shared
    @State private var response: WatchCollectionResponse?
    @State private var loaded = false
    @State private var showDownloadNote = false

    var body: some View {
        List {
            if !loaded {
                HStack { ProgressView(); Text("Loading…").font(.system(.caption2)) }
            } else if let response {
                Button {
                    Task { await WatchAppAssembly.shared.playOnPhone(.playCollection(ref)) }
                } label: {
                    actionLabel("play.fill", "Play on iPhone", bold: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("watch.collection.playPhone")

                Button {
                    showDownloadNote = true
                } label: {
                    actionLabel("arrow.down.circle", "Download to Apple Watch")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("watch.collection.download")

                ForEach(response.tracks) { track in
                    Button {
                        if let index = response.tracks.firstIndex(where: { $0.id == track.id }) {
                            Task { await WatchAppAssembly.shared.playOnPhone(
                                .playTrack(track.trackID, in: ref)) }
                            _ = index
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: track.isDownloadedOnWatch ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 11))
                                .foregroundStyle(track.isDownloadedOnWatch ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title).font(.system(.body)).lineLimit(1)
                                if !track.artist.isEmpty {
                                    Text(track.artist).font(.system(.caption2))
                                        .foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 4)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("watch.track.\(track.trackID.rawValue)")
                }
            } else {
                WatchEmptyStateView(icon: "iphone.slash", title: "Couldn't Load",
                                    message: "The iPhone could not be reached.")
            }
        }
        .listStyle(.carousel)
        .navigationTitle(response?.title ?? "Collection")
        .task {
            response = await WatchAppAssembly.shared.loadPhoneCollection(ref)
            loaded = true
        }
        .alert("Manage on iPhone", isPresented: $showDownloadNote) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Download this collection to your watch from Platterhead on your iPhone.")
        }
    }

    private func actionLabel(_ icon: String, _ title: String, bold: Bool = false) -> some View {
        HStack {
            Image(systemName: icon).font(.system(size: 14))
            Text(title).font(.system(.body, design: .default)).fontWeight(bold ? .semibold : .regular)
            Spacer()
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

/// W12 — store recovery / incompatibility / empty. Never a dead end; diagnostics are state codes
/// and byte counts only, never titles or paths.
struct WatchRecoveryView: View {
    @ObservedObject private var model = WatchAppAssembly.shared.model
    @Environment(\.dismiss) private var dismiss
    @State private var showDetails = false

    private var launchState: WatchStoreLaunchState { WatchAppAssembly.shared.launchState }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 32)).foregroundStyle(.tint)
            Text(title).font(.system(.headline, design: .default)).multilineTextAlignment(.center)
            if let notice = model.recoveryNotice {
                Text(notice)
                    .font(.system(.caption2)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Continue") { dismiss() }
                .accessibilityIdentifier("watch.store.continue")
            Button("View Details") { showDetails = true }
                .accessibilityIdentifier("watch.store.details")
                .font(.system(.caption2))
        }
        .padding(.horizontal, 12)
        .navigationTitle("Recovery")
        .accessibilityIdentifier("watch.store.recovery")
        .alert("Diagnostics", isPresented: $showDetails) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("State: \(launchState.rawValue)\nDownloads: \(model.tracks.count)")
        }
    }

    private var symbol: String {
        switch launchState {
        case .recovered: "checkmark.circle"
        case .degraded: "exclamationmark.triangle"
        case .opening, .ready: "internaldrive"
        }
    }

    private var title: String {
        switch launchState {
        case .recovered: "Library Recovered"
        case .degraded: "Library Unavailable"
        case .opening, .ready: "Watch Library"
        }
    }
}
