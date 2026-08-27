import SwiftUI
import TonearmCore

/// Watch rearchitecture Phase 8 — Settings › Apple Watch (§9 P2/P3/P4).
///
/// The iPhone owns desired downloads and makes every transfer understandable without opening the
/// watch app: real pairing state, watch-*reported* storage, the live download activity, and the
/// downloaded collections with reference-aware removal.
struct WatchSettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemoveAll = false

    private var snapshot: PhoneWatchManagementPresenter.Snapshot { appState.watchManagement }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    headerCard
                    if let shortfall = snapshot.storage?.spaceShortfall {
                        shortfallCard(shortfall)
                    }
                    if !snapshot.activity.isEmpty { downloadingCard }
                    if !snapshot.collections.isEmpty { collectionsCard }
                    if snapshot.isEmpty && snapshot.pairing.isPaired { emptyCard }
                    managementCard
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 160)
            }
            .foregroundStyle(Palette.ink)
            .background(Palette.libraryBackground.ignoresSafeArea())
            .navigationTitle("Apple Watch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.tint(Palette.brass)
                }
            }
            .accessibilityIdentifier("settings.watch")
        }
        .preferredColorScheme(.dark)
        .task { await appState.refreshWatchState() }
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: statusIcon)
                    .font(.system(size: 18))
                    .foregroundStyle(statusColor)
                Text(statusText)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            if let detail = statusDetail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink3)
            }
            if let storage = snapshot.storage {
                Divider().overlay(Palette.hairline).padding(.vertical, 2)
                Text("Downloaded \(storage.trackCount) \(storage.trackCount == 1 ? "track" : "tracks") · \(bytes(storage.installedBytes))")
                    .font(.system(size: 12.5, weight: .medium))
                if let fraction = storage.usedFraction {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: fraction)
                            .tint(fraction > 0.9 ? Palette.danger : Palette.brass)
                        Text("Watch storage used \(Int((fraction * 100).rounded()))%")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.ink3)
                    }
                    .padding(.top, 2)
                } else if storage.freeBytes > 0 {
                    Text("\(bytes(storage.freeBytes)) free on Apple Watch")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.ink3)
                }
            }
        }
        .padding(15)
        .glassSurface(cornerRadius: 18)
        .accessibilityIdentifier("settings.watch.storage")
    }

    private func shortfallCard(_ shortfall: PhoneWatchManagementPresenter.SpaceShortfall) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.danger)
                Text("Not enough space on Apple Watch").font(.system(size: 13.5, weight: .semibold))
            }
            Text("The remaining downloads need about \(bytes(shortfall.requiredBytes)) plus a \(bytes(shortfall.reserveBytes)) reserve; \(bytes(shortfall.freeBytes)) is free. Remove a collection below to make room.")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.ink3)
        }
        .padding(15)
        .glassSurface(cornerRadius: 18)
    }

    // MARK: - Downloading

    private var downloadingCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloading").font(.system(size: 13, weight: .bold))
                Spacer()
                NavigationLink {
                    WatchDownloadQueueView()
                } label: {
                    Text("Queue").font(.system(size: 11.5)).foregroundStyle(Palette.brass)
                }
                .accessibilityIdentifier("settings.watch.queue")
            }
            .padding(.bottom, 10)

            ForEach(Array(snapshot.activity.prefix(4))) { row in
                WatchActivityRowView(row: row)
                if row.id != snapshot.activity.prefix(4).last?.id {
                    Divider().overlay(Palette.hairline).padding(.vertical, 8)
                }
            }
            if snapshot.activity.count > 4 {
                Text("+ \(snapshot.activity.count - 4) more")
                    .font(.system(size: 11)).foregroundStyle(Palette.ink3)
                    .padding(.top, 8)
            }
        }
        .padding(15)
        .glassSurface(cornerRadius: 18)
    }

    // MARK: - Collections

    private var collectionsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Downloaded Collections")
                .font(.system(size: 13, weight: .bold))
                .padding(.bottom, 10)

            ForEach(snapshot.collections) { row in
                NavigationLink {
                    WatchDownloadedCollectionDetailView(rootID: row.rootID, title: row.title)
                } label: {
                    WatchCollectionRowView(row: row)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("watchRoot.\(row.rootID)")
                if row.id != snapshot.collections.last?.id {
                    Divider().overlay(Palette.hairline).padding(.vertical, 8)
                }
            }
        }
        .padding(15)
        .glassSurface(cornerRadius: 18)
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No downloads yet").font(.system(size: 13.5, weight: .semibold))
            Text("Use “Download to Apple Watch” from a track, album, or playlist to keep music for offline playback.")
                .font(.system(size: 11.5)).foregroundStyle(Palette.ink3)
        }
        .padding(15)
        .glassSurface(cornerRadius: 18)
    }

    // MARK: - Management

    private var managementCard: some View {
        VStack(spacing: 0) {
            Button {
                Task { await appState.resendCatalogToWatch() }
            } label: {
                managementRow(icon: "arrow.triangle.2.circlepath", tint: Palette.brass,
                              title: "Reconcile with Apple Watch", chevron: true)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.watch.reconcile")

            if !snapshot.collections.isEmpty || !snapshot.activity.isEmpty {
                Divider().overlay(Palette.hairline)
                Button(role: .destructive) {
                    confirmRemoveAll = true
                } label: {
                    managementRow(icon: "trash", tint: Palette.danger,
                                  title: "Remove All from Apple Watch", chevron: false)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.watch.removeAll")
            }
        }
        .padding(15)
        .glassSurface(cornerRadius: 18)
        .confirmationDialog("Remove all downloads from Apple Watch?",
                            isPresented: $confirmRemoveAll, titleVisibility: .visible) {
            Button("Remove All", role: .destructive) {
                Task { await appState.removeAllFromWatch(); await appState.refreshWatchState() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Music remains in Platterhead on this iPhone. Only the watch copies are removed.")
        }
    }

    private func managementRow(icon: String, tint: Color, title: String, chevron: Bool) -> some View {
        HStack {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(tint)
            Text(title).font(.system(size: 13.5)).foregroundStyle(tint == Palette.danger ? Palette.danger : Palette.ink)
            Spacer()
            if chevron {
                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Palette.ink3)
            }
        }
        .padding(.vertical, 10)
    }

    // MARK: - Status strings

    private var statusIcon: String {
        switch appState.watchSessionState {
        case .reachable: return "applewatch.radiowaves.left.and.right"
        case .installedNotReachable: return "applewatch"
        case .notInstalled: return "applewatch.slash"
        case .unsupported: return "xmark.applewatch"
        }
    }

    private var statusColor: Color {
        switch appState.watchSessionState {
        case .reachable: return Palette.ok
        case .installedNotReachable: return Palette.brass
        case .notInstalled, .unsupported: return Palette.ink3
        }
    }

    private var statusText: String {
        switch appState.watchSessionState {
        case .reachable: return "Connected"
        case .installedNotReachable: return "Paired — Not Reachable"
        case .notInstalled: return "Watch Not Paired"
        case .unsupported: return "Watch Unavailable"
        }
    }

    private var statusDetail: String? {
        switch appState.watchSessionState {
        case .reachable:
            if let seconds = snapshot.connectedForSeconds, seconds < 90 {
                return "Connected just now."
            }
            return "Your Apple Watch is connected and ready."
        case .installedNotReachable:
            return "Watch is paired but not currently reachable. Transfers resume when it is in range."
        case .notInstalled:
            return "Pair an Apple Watch to sync music for offline playback."
        case .unsupported:
            return "This device does not support Apple Watch."
        }
    }

    private func bytes(_ value: Int64) -> String { WatchByteFormat.string(value) }
}

// MARK: - Shared helpers

enum WatchByteFormat {
    static func string(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file)
    }
}

enum WatchStageCopy {
    static func text(_ stage: PhoneWatchManagementPresenter.ActivityStage) -> String {
        switch stage {
        case .queued: return "Queued"
        case .resolving: return "Preparing"
        case .transferring: return "Transferring"
        case .waitingForWiFi: return "Waiting for Wi-Fi"
        case .failed: return "Failed"
        case .paused: return "Paused"
        }
    }

    static func icon(_ stage: PhoneWatchManagementPresenter.ActivityStage) -> String {
        switch stage {
        case .queued, .resolving: return "clock"
        case .transferring: return "arrow.down.circle"
        case .waitingForWiFi: return "wifi.slash"
        case .failed: return "exclamationmark.circle"
        case .paused: return "pause.circle"
        }
    }

    static func tint(_ stage: PhoneWatchManagementPresenter.ActivityStage) -> Color {
        switch stage {
        case .failed: return Palette.danger
        case .waitingForWiFi, .paused: return Palette.brass
        default: return Palette.ink2
        }
    }
}

// MARK: - Rows

private struct WatchActivityRowView: View {
    let row: PhoneWatchManagementPresenter.ActivityRow
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: WatchStageCopy.icon(row.stage))
                    .font(.system(size: 12))
                    .foregroundStyle(WatchStageCopy.tint(row.stage))
                Text(row.title).font(.system(size: 12.5)).lineLimit(1)
                Spacer()
                Text(WatchStageCopy.text(row.stage))
                    .font(.system(size: 10.5))
                    .foregroundStyle(WatchStageCopy.tint(row.stage))
            }
            if let message = row.failureMessage {
                Text(message).font(.system(size: 10.5)).foregroundStyle(Palette.ink3).lineLimit(2)
            }
            HStack(spacing: 14) {
                if row.canRetry {
                    Button("Try Again") { Task { await appState.retryWatchJob(row.requestID) } }
                        .font(.system(size: 11, weight: .semibold)).tint(Palette.brass)
                }
                if row.canCancel {
                    Button("Cancel", role: .destructive) { Task { await appState.cancelWatchJob(row.requestID) } }
                        .font(.system(size: 11)).tint(Palette.ink3)
                } else if row.canRetry {
                    Button("Remove from Queue", role: .destructive) {
                        Task { await appState.cancelWatchJob(row.requestID) }
                    }
                    .font(.system(size: 11)).tint(Palette.ink3)
                }
            }
            .buttonStyle(.plain)
        }
        .accessibilityIdentifier("watchJob.\(row.requestID)")
    }
}

private struct WatchCollectionRowView: View {
    let row: PhoneWatchManagementPresenter.CollectionRow

    private var subtitle: String {
        if row.paused { return "Paused · \(row.readyCount) of \(row.desiredCount) downloaded" }
        var parts: [String] = []
        switch row.kind {
        case .track: parts.append("Track")
        case .album: parts.append("Album · \(row.desiredCount) tracks")
        case .playlist: parts.append("\(row.desiredCount) tracks")
        }
        if row.isFullyReady {
            parts.append(row.kind == .playlist ? "Kept in sync" : "Downloaded")
        } else if row.isPartial {
            parts.append("\(row.readyCount) downloaded")
        }
        if row.failedCount > 0 { parts.append("\(row.failedCount) failed") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.paused ? "pause.circle" : iconName)
                .font(.system(size: 14))
                .foregroundStyle(row.paused ? Palette.brass : Palette.ink2)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.system(size: 13)).lineLimit(1)
                Text(subtitle).font(.system(size: 10.5)).foregroundStyle(Palette.ink3).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Palette.ink3)
        }
        .contentShape(Rectangle())
    }

    private var iconName: String {
        switch row.kind {
        case .track: return "music.note"
        case .album: return "square.stack"
        case .playlist: return "music.note.list"
        }
    }
}
