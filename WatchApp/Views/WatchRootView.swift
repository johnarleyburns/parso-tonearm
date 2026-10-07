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
    @ObservedObject private var player = WatchPlayer.shared

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

            ForEach(homeDoors) { item in
                door(item.nav, title: item.title, detail: item.detail,
                     systemImage: item.systemImage, identifier: item.identifier)
            }

            if connected {
                statusChip
                    .listRowBackground(Color.clear)
            }

            door(.syncStatus, title: "Sync Status", detail: nil,
                 systemImage: "arrow.triangle.2.circlepath", identifier: "watch.syncStatus")

            Button {
                player.navigationPath.append(WatchNav.about)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle")
                        .font(.callout)
                        .foregroundStyle(WatchPalette.accent)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    Text("About")
                }
                .padding(.vertical, 6)
            }
            .accessibilityIdentifier("watch.about")
        }
        .listStyle(.plain)
        .navigationTitle("Platterhead")
        .accessibilityIdentifier("watch.root")
        .task { await model.refresh() }
    }

    private var connected: Bool { chrome.showsConnectedFeatures }

    private var homeDoors: [HomeDoor] {
        [
            HomeDoor(nav: .search, title: "Search All Music", detail: nil,
                     systemImage: "magnifyingglass", identifier: "watch.search"),
            HomeDoor(nav: .searchThisWatch, title: "Search This Watch",
                     detail: String(localized: "\(model.tracks.filter(\.isReady).count) downloaded"),
                     systemImage: "applewatch", identifier: "watch.search.thisWatch"),
            HomeDoor(nav: .playlists, title: "Playlists",
                     detail: String(localized: "\(model.playlists.count) in catalog"),
                     systemImage: "music.note.list", identifier: "watch.playlists"),
            HomeDoor(nav: .albums, title: "Albums",
                     detail: String(localized: "\(model.albums.count) in catalog"),
                     systemImage: "square.stack", identifier: "watch.albums"),
            HomeDoor(nav: .downloads, title: "On This Watch", detail: onWatchDetail,
                     systemImage: "applewatch", identifier: "watch.downloads")
        ]
    }

    private func door(_ nav: WatchNav, title: LocalizedStringKey, detail: String?,
                      systemImage: String, identifier: String) -> some View {
        Button {
            player.navigationPath.append(nav)
        } label: {
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

    private struct HomeDoor: Identifiable {
        let nav: WatchNav
        let title: LocalizedStringKey
        let detail: String?
        let systemImage: String
        let identifier: String

        var id: String { identifier }
    }

    private var onWatchDetail: String {
        let count = model.tracks.filter(\.isReady).count
        let bytes = model.storage?.readyBytes ?? 0
        if count == 0 { return String(localized: "Nothing downloaded") }
        let songs = String(localized: "\(count) songs")
        return bytes > 0 ? "\(songs) · \(WatchTimeFmt.megabytes(bytes))" : songs
    }

    @ViewBuilder
    private var statusChip: some View {
        switch chrome.banner {
        case .connected:
            WatchStatusChip(title: String(localized: "iPhone app reachable"), tone: .good)
                .accessibilityIdentifier("watch.status")
        case .temporarilyUnavailable:
            WatchStatusChip(title: String(localized: "Reconnecting to iPhone…"), tone: .warning)
                .accessibilityIdentifier("watch.status")
        case .unavailable:
            WatchStatusChip(title: String(localized: "iPhone app unavailable"), tone: .warning)
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
                Text("Your iPhone can sync music here. Downloaded tracks play directly on this watch.")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                NavigationLink(value: WatchNav.playlists) { Text("Browse synced catalog") }
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

/// H1 hero — the local watch player in miniature. The phone player is never a watch playback target.
struct WatchHomeHero: View {
    @ObservedObject private var player = WatchPlayer.shared

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
                            WatchTargetChip(systemImage: "applewatch", title: String(localized: "On Watch"),
                                            tone: .onArtwork)
                            WatchProgressHairline(elapsed: hero.elapsed, duration: hero.duration, showsTimes: false)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("watch.nowPlaying")
                .accessibilityLabel(Text("Now Playing, \(hero.title), on Apple Watch"))
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
                .accessibilityLabel((hero.isPlaying ? Text("Pause") : Text("Play")))
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
        var isPlaying: Bool
        var elapsed: Double
        var duration: Double
        var tint: Color
        var image: UIImage?
        var toggle: () -> Void
    }

    private var current: Hero? {
        guard let track = player.currentTrack else { return nil }
        return Hero(title: track.title, subtitle: track.artist, isPlaying: player.isPlaying,
                    elapsed: player.elapsed, duration: player.duration,
                    tint: player.artworkTint ?? WatchPalette.accent, image: player.artwork,
                    toggle: { player.togglePlayPause() })
    }
}

enum WatchNav: Hashable {
    case search
    case searchThisWatch
    case downloads
    case playlists
    case albums
    case songs
    case storage
    case playlist(String)
    case album(String)
    case recovery
    case about
    case syncStatus
}

struct WatchAboutView: View {
    private var installedBuild: String {
        WatchBuildInfo.label(
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String)
    }

    var body: some View {
        List {
            Section {
                Label("Platterhead", systemImage: "music.note")
                Text(installedBuild)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("watch.about.build")
            }
        }
        .navigationTitle("About")
        .listStyle(.plain)
    }
}

struct WatchSyncStatusView: View {
    @ObservedObject private var model = WatchAppAssembly.shared.model
    @ObservedObject private var chrome = WatchAppAssembly.shared.chrome
    @ObservedObject private var state = WatchAppAssembly.shared.syncStatus

    var body: some View {
        List {
            Section("Connection") {
                Text(chrome.showsConnectedFeatures ? "iPhone app reachable" : "iPhone app not reachable")
                    .font(.caption).accessibilityIdentifier("watch.sync.connection")
                Text("Background downloads can still arrive when the iPhone app is not reachable.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section("Sync History") {
                history("Last catalog update", date: state.lastCatalogSyncAt)
                history("Last iPhone status", date: state.lastPhoneStatusAt)
                history("Last audio installed", date: state.lastAudioInstalledAt)
                if let report = state.downloads?.lastWatchReportAt {
                    history("Last watch report", date: report)
                }
                if let requested = state.lastRequestedAt { history("Sync requested", date: requested) }
            }
            Section("Downloads") {
                if state.isDownloadStatusStale(at: Date()) {
                    Text("iPhone progress report is out of date. Percentages below are last reported, not live progress.")
                        .font(.caption2).foregroundStyle(.orange)
                }
                count("Installed on this watch", value: model.tracks.filter(\.isReady).count)
                    .accessibilityIdentifier("watch.sync.installedCount")
                if let downloads = state.downloads {
                    let waiting = downloads.activities.filter {
                        [.queued, .waitingForDelivery, .awaitingInstallation, .awaitingChunkConfirmation].contains($0.stage)
                    }.count
                    count("Waiting", value: downloads.activities.isEmpty ? downloads.queuedCount : waiting)
                    count("Preparing", value: downloads.activities.filter { $0.stage == .preparing }.count)
                    count("Actively downloading", value: downloads.activeCount)
                    count("Waiting for Wi-Fi", value: downloads.waitingForWiFiCount)
                    count("Failed", value: downloads.failedCount)
                } else {
                    Text("No download report received from iPhone yet.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let downloads = state.downloads, !downloads.activities.isEmpty {
                Section("Track Activity") {
                    ForEach(downloads.activities) { activity in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(activity.title.isEmpty ? (model.track(id: activity.id)?.title ?? "Track") : activity.title)
                                .font(.caption).lineLimit(2)
                            Text(stageText(activity.stage)).font(.caption2).foregroundStyle(.secondary)
                            if let fraction = activity.fractionComplete, let count = activity.receivedChunkCount, let total = activity.totalChunkCount {
                                ProgressView(value: fraction)
                                Text("\(Int(fraction * 100))% saved · \(count)/\(total) chunks").font(.caption2)
                                Text("Resumes from saved chunks").font(.caption2).foregroundStyle(.secondary)
                            } else if activity.stage == .transferring, let fraction = activity.fractionComplete {
                                if state.isDownloadStatusStale(at: Date()) {
                                    Text("Last reported: \(Int(fraction * 100))% transferred").font(.caption2)
                                } else {
                                    ProgressView(value: fraction)
                                    Text("\(Int(fraction * 100))% transferred").font(.caption2)
                                }
                            }
                            if let message = activity.message {
                                Text(message).font(.caption2).foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            Section {
                Button("Refresh Sync") {
                    Task { await WatchAppAssembly.shared.requestSyncStatus() }
                }
                .accessibilityIdentifier("watch.sync.refresh")
                if let requested = state.lastRequestedAt {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Sync requested").font(.caption)
                        Text(requested.formatted(date: .omitted, time: .shortened))
                            .font(.caption2).foregroundStyle(.secondary)
                        Text("Queued for iPhone. Downloads are confirmed only after installation.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("watch.sync.requested")
                }
                if (state.downloads?.failedCount ?? 0) > 0 {
                    Button("Retry Failed Downloads") {
                        Task { await WatchAppAssembly.shared.controlDownloads(.retryFailed) }
                    }
                }
                NavigationLink(value: WatchNav.downloads) { Text("Manage Downloads") }
            }
        }
        .listStyle(.plain).navigationTitle("Sync Status")
        .accessibilityIdentifier("watch.sync.screen")
        .task {
            while !Task.isCancelled {
                await WatchAppAssembly.shared.refreshSyncReachability()
                await model.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func history(_ title: LocalizedStringKey, date: Date?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            if let date { Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption) }
            else { Text("Not yet").font(.caption) }
        }
    }

    private func count(_ title: LocalizedStringKey, value: Int) -> some View {
        HStack { Text(title).font(.caption2); Spacer(); Text("\(value)").font(.caption) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text("\(value)"))
    }

    private func stageText(_ stage: WatchDownloadActivity.Stage) -> LocalizedStringKey {
        switch stage {
        case .queued: "Queued on iPhone"
        case .preparing: "Preparing audio on iPhone"
        case .waitingForDelivery: "Waiting for iPhone to send file"
        case .transferring: "Downloading to this watch"
        case .awaitingInstallation: "Waiting for watch installation"
        case .awaitingChunkConfirmation: "Waiting for chunk confirmation"
        case .waitingForWiFi: "Waiting for Wi-Fi"
        case .failed: "Download failed"
        case .paused: "Paused"
        }
    }
}
