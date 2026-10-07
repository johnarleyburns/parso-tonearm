import SwiftUI
import TonearmWatchCore
import TonearmWatchProtocol

/// Watch redesign §5 D1 — "On This Watch": everything downloaded and everything downloading, on
/// one screen. Active transfers come first with real progress, the specific reason they're
/// waiting, and Pause / Resume / Stop / Retry on the same surface (CLAUDE.md: background work is
/// always visible and in the user's control). Replaces the Downloads → Playlists/Albums/Tracks/
/// Storage maze.
struct WatchDownloadsView: View {
    @ObservedObject private var model = WatchAppAssembly.shared.model
    @ObservedObject private var chrome = WatchAppAssembly.shared.chrome
    @State private var confirmStop: WatchDownloadRootStatus?
    @State private var pendingControl: Set<String> = []

    var body: some View {
        List {
            if !model.activeDownloadRoots.isEmpty {
                Section {
                    ForEach(model.activeDownloadRoots) { root in
                        downloadRow(root)
                    }
                    if model.activeDownloadRoots.count > 1 {
                        HStack(spacing: 6) {
                            if allPaused {
                                Button("Resume All") { control(.resume, rootID: nil) }
                                    .buttonStyle(.watchSecondarySmall)
                            } else {
                                Button("Pause All") { control(.pause, rootID: nil) }
                                    .buttonStyle(.watchSecondarySmall)
                            }
                        }
                        .listRowBackground(Color.clear)
                        .disabled(!chrome.showsConnectedFeatures)
                    }
                } header: {
                    Text(downloadingHeader)
                }
                if !chrome.showsConnectedFeatures {
                    Text("Downloads continue when your iPhone is nearby. Controls are sent when it reconnects.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }

            Section {
                NavigationLink(value: WatchNav.songs) {
                    WatchCollectionRowLabel(title: String(localized: "Songs"),
                                            detail: String(localized: "\(model.tracks.filter(\.isReady).count) playable tracks"),
                                            tintKey: "songs")
                }
                .watchCardRow()
                .accessibilityIdentifier("watch.songs")
            } header: {
                Text("Downloaded audio")
            } footer: {
                Text("Only downloaded tracks can play without your iPhone.")
            }

            Section {
                NavigationLink(value: WatchNav.playlists) {
                    WatchCollectionRowLabel(title: String(localized: "Playlists"),
                                            detail: String(localized: "\(model.playlists.count) playlists"),
                                            tintKey: "playlists")
                }
                .watchCardRow()
                .accessibilityIdentifier("watch.downloads.playlists")
                NavigationLink(value: WatchNav.albums) {
                    WatchCollectionRowLabel(title: String(localized: "Albums"),
                                            detail: String(localized: "\(model.albums.count) albums"),
                                            tintKey: "albums")
                }
                .watchCardRow()
                .accessibilityIdentifier("watch.downloads.albums")
            } header: {
                Text("Catalog on this watch")
            } footer: {
                Text("Playlist and album listings do not mean their audio is downloaded.")
            }

            Section {
                NavigationLink(value: WatchNav.storage) {
                    Label("Storage & Diagnostics", systemImage: "internaldrive")
                }
                .watchCardRow()
                .accessibilityIdentifier("watch.downloads.storage")
            }
        }
        .listStyle(.plain)
        .navigationTitle("On This Watch")
        .task { await model.refresh() }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirmStop != nil },
                                                               set: { if !$0 { confirmStop = nil } }),
                            titleVisibility: .visible) {
            Button("Stop and Remove", role: .destructive) {
                if let root = confirmStop { control(.stop, rootID: root.rootID) }
                confirmStop = nil
            }
            Button("Cancel", role: .cancel) { confirmStop = nil }
        } message: {
            Text("Songs from this download that no other download needs are removed from the watch. You can download it again from your iPhone.")
        }
    }

    // MARK: Rows

    private func downloadRow(_ root: WatchDownloadRootStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                WatchTransferRing(fraction: root.state == .queued && root.readyCount == 0 ? nil : root.fraction)
                VStack(alignment: .leading, spacing: 1) {
                    Text(root.title.isEmpty ? String(localized: "Download") : root.title).font(.body).lineLimit(1)
                    Text(statusLine(root)).font(.caption2).foregroundStyle(statusColor(root)).lineLimit(2)
                }
            }
            HStack(spacing: 6) {
                switch root.state {
                case .paused:
                    Button("Resume") { control(.resume, rootID: root.rootID) }
                        .buttonStyle(.watchPrimarySmall)
                case .failed:
                    Button("Retry") { control(.retryFailed, rootID: root.rootID) }
                        .buttonStyle(.watchPrimarySmall)
                default:
                    Button("Pause") { control(.pause, rootID: root.rootID) }
                        .buttonStyle(.watchSecondarySmall)
                }
                Button("Stop") { confirmStop = root }
                    .buttonStyle(.watchDestructiveSmall)
            }
            .disabled(pendingControl.contains(root.rootID))
            if root.failedCount > 0 && root.state != .failed {
                Button("Retry \(root.failedCount) failed") { control(.retryFailed, rootID: root.rootID) }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundStyle(WatchPalette.accent)
            }
        }
        .padding(.vertical, 4)
        .watchCardRow()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("watch.downloads.root.\(root.rootID)")
    }

    private func statusLine(_ root: WatchDownloadRootStatus) -> String {
        let progress = String(localized: "\(root.readyCount) of \(root.desiredCount) songs")
        let reason: String = switch root.state {
        case .downloading: String(localized: "Downloading")
        case .queued: String(localized: "Transfer queued")
        case .waitingForWiFi: String(localized: "Waiting for Wi-Fi")
        case .paused: String(localized: "Paused")
        case .failed: String(localized: "Failed — tap Retry")
        case .complete: String(localized: "Done")
        }
        return "\(reason) · \(progress)"
    }

    private func statusColor(_ root: WatchDownloadRootStatus) -> Color {
        switch root.state {
        case .failed: WatchPalette.failure
        case .paused, .waitingForWiFi: WatchPalette.warning
        default: .secondary
        }
    }

    private var allPaused: Bool { model.activeDownloadRoots.allSatisfy { $0.state == .paused } }

    private var downloadingHeader: String {
        let roots = model.activeDownloadRoots
        let done = roots.reduce(0) { $0 + $1.readyCount }
        let total = roots.reduce(0) { $0 + $1.desiredCount }
        return String(localized: "Downloading · \(done) of \(total)")
    }

    private var confirmTitle: String {
        guard let root = confirmStop else { return "" }
        return String(localized: "Stop “\(root.title)”?")
    }

    private func control(_ action: WatchDownloadControlAction, rootID: String?) {
        if let rootID { pendingControl.insert(rootID) }
        Task {
            await WatchAppAssembly.shared.controlDownloads(action, rootID: rootID)
            try? await Task.sleep(for: .seconds(2))
            if let rootID { pendingControl.remove(rootID) }
        }
    }
}
