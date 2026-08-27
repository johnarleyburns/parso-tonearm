import SwiftUI
import TonearmCore

/// Watch rearchitecture Phase 8 — the P3 download queue and P4 storage-management detail.

// MARK: - P3 — Download queue

struct WatchDownloadQueueView: View {
    @EnvironmentObject var appState: AppState

    private var activity: [PhoneWatchManagementPresenter.ActivityRow] { appState.watchManagement.activity }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let banner = appState.watchManagement.banner {
                    Text(queueSummary(banner))
                        .font(.system(size: 12)).foregroundStyle(Palette.ink3)
                }
                if activity.isEmpty {
                    Text("Nothing in the queue. Every download has been installed or removed.")
                        .font(.system(size: 12.5)).foregroundStyle(Palette.ink3)
                        .padding(.top, 8)
                }
                ForEach(activity) { row in
                    WatchQueueRow(row: row)
                        .padding(14)
                        .glassSurface(cornerRadius: 14)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 140)
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.libraryBackground.ignoresSafeArea())
        .navigationTitle("Download Queue")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .task { await appState.refreshWatchState() }
    }

    private func queueSummary(_ b: PhoneWatchManagementPresenter.TransferBanner) -> String {
        var parts: [String] = []
        if b.activeCount > 0 { parts.append("\(b.activeCount) transferring") }
        if b.failedCount > 0 { parts.append("\(b.failedCount) failed") }
        return parts.isEmpty ? "Queue is idle" : parts.joined(separator: " · ")
    }
}

private struct WatchQueueRow: View {
    let row: PhoneWatchManagementPresenter.ActivityRow
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: WatchStageCopy.icon(row.stage))
                    .font(.system(size: 13)).foregroundStyle(WatchStageCopy.tint(row.stage))
                Text(row.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer()
                Text(WatchStageCopy.text(row.stage))
                    .font(.system(size: 11)).foregroundStyle(WatchStageCopy.tint(row.stage))
            }
            if let message = row.failureMessage {
                Text(message).font(.system(size: 11)).foregroundStyle(Palette.ink3)
            }
            HStack(spacing: 16) {
                if row.canRetry {
                    Button("Try Again") { Task { await appState.retryWatchJob(row.requestID) } }
                        .font(.system(size: 12, weight: .semibold)).tint(Palette.brass)
                }
                if row.canCancel {
                    Button("Cancel", role: .destructive) { Task { await appState.cancelWatchJob(row.requestID) } }
                        .font(.system(size: 12)).tint(Palette.ink3)
                } else if row.canRetry {
                    Button("Remove from Queue", role: .destructive) {
                        Task { await appState.cancelWatchJob(row.requestID) }
                    }
                    .font(.system(size: 12)).tint(Palette.ink3)
                }
                Spacer()
            }
            .buttonStyle(.plain)
        }
        .accessibilityIdentifier("watchJob.\(row.requestID)")
    }
}

// MARK: - P4 — Storage management / collection detail

struct WatchDownloadedCollectionDetailView: View {
    let rootID: String
    let title: String

    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var detail: PhoneWatchManagementPresenter.CollectionDetail?
    @State private var confirmRemove = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let detail {
                    keepCard(detail)
                    statusCard(detail)
                    removeCard(detail)
                } else {
                    ProgressView().tint(Palette.brass).padding(.top, 40)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 140)
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.libraryBackground.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .task { await reload() }
        .accessibilityIdentifier("watchRoot.\(rootID)")
    }

    private func reload() async {
        await appState.refreshWatchState()
        detail = await appState.watchCollectionDetail(rootID)
    }

    private func keepCard(_ d: PhoneWatchManagementPresenter.CollectionDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { !d.paused },
                set: { keep in
                    Task {
                        if keep { await appState.resumeWatchCollection(rootID) }
                        else { await appState.pauseWatchCollection(rootID) }
                        await reload()
                    }
                })) {
                    Text("Keep this \(kindWord(d.kind)) on Apple Watch")
                        .font(.system(size: 13.5, weight: .medium))
                }
                .tint(Palette.brass)

            if d.autoSyncs {
                Text("New playlist tracks download automatically.")
                    .font(.system(size: 11)).foregroundStyle(Palette.ink3)
            }
            if d.estimatedRemainingCount > 0 {
                Text("Estimated download · \(d.estimatedRemainingCount) \(d.estimatedRemainingCount == 1 ? "track" : "tracks")\(d.estimatedRemainingBytes > 0 ? " · \(WatchByteFormat.string(d.estimatedRemainingBytes))" : "")")
                    .font(.system(size: 11)).foregroundStyle(Palette.ink3)
            }
        }
        .padding(15)
        .glassSurface(cornerRadius: 18)
    }

    private func statusCard(_ d: PhoneWatchManagementPresenter.CollectionDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Status").font(.system(size: 13, weight: .bold))
            statusRow(color: Palette.ok, text: "Ready on Apple Watch",
                      count: d.readyCount, suffix: d.readyCount == 1 ? "track" : "tracks")
            if d.waitingForWiFiCount > 0 {
                statusRow(color: Palette.brass, text: "Waiting for Wi-Fi",
                          count: d.waitingForWiFiCount, suffix: d.waitingForWiFiCount == 1 ? "track" : "tracks")
            }
            if d.failedCount > 0 {
                statusRow(color: Palette.danger, text: "Failed — retry from the queue",
                          count: d.failedCount, suffix: d.failedCount == 1 ? "track" : "tracks")
            }
            if d.unavailableCount > 0 {
                VStack(alignment: .leading, spacing: 2) {
                    statusRow(color: Palette.danger, text: "Unavailable at source",
                              count: d.unavailableCount, suffix: d.unavailableCount == 1 ? "track" : "tracks")
                    if let reason = d.unavailableReason {
                        Text(reason).font(.system(size: 10.5)).foregroundStyle(Palette.ink3)
                            .padding(.leading, 16)
                    }
                }
            }
        }
        .padding(15)
        .glassSurface(cornerRadius: 18)
        .accessibilityIdentifier("settings.watch.storage")
    }

    private func statusRow(color: Color, text: String, count: Int, suffix: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 12))
            Spacer()
            Text("\(count) \(suffix)").font(.system(size: 11)).foregroundStyle(Palette.ink3)
        }
    }

    private func removeCard(_ d: PhoneWatchManagementPresenter.CollectionDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(role: .destructive) { confirmRemove = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "trash").font(.system(size: 14))
                    Text("Remove \(kindWord(d.kind).capitalized) from Apple Watch")
                        .font(.system(size: 13.5))
                    Spacer()
                }
                .foregroundStyle(Palette.danger)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            Text(removalNote(d))
                .font(.system(size: 10.5)).foregroundStyle(Palette.ink3)
        }
        .padding(15)
        .glassSurface(cornerRadius: 18)
        .confirmationDialog("Remove “\(title)” from Apple Watch?",
                            isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task { await appState.removeWatchCollection(rootID); dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removalNote(d))
        }
    }

    private func removalNote(_ d: PhoneWatchManagementPresenter.CollectionDetail) -> String {
        var note = "Music remains in Platterhead on this iPhone."
        if d.retainedSharedTrackCount > 0 {
            note += " \(d.retainedSharedTrackCount) \(d.retainedSharedTrackCount == 1 ? "track" : "tracks") required by other downloads stay on the watch."
        }
        return note
    }

    private func kindWord(_ kind: PhoneWatchManagementPresenter.CollectionKind) -> String {
        switch kind {
        case .track: return "track"
        case .album: return "album"
        case .playlist: return "playlist"
        }
    }
}
