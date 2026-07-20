import SwiftUI
import TonearmCore

struct WatchSettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var onWatchTrackCount: Int = 0
    @State private var onWatchBytes: Int64 = 0
    @State private var transferCount: Int = 0
    @State private var failedCount: Int = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    headerCard
                    onWatchCard
                    transferCard
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
        }
        .preferredColorScheme(.dark)
        .task { await refresh() }
    }

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
        }
        .padding(15)
        .glassSurface(cornerRadius: 18)
    }

    private var onWatchCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("On Watch").font(.system(size: 13, weight: .bold))
                Spacer()
                Text(TimeFmt.megabytes(onWatchBytes))
                    .font(.system(size: 11)).foregroundStyle(Palette.ink3)
            }
            .padding(.bottom, 11)

            HStack(spacing: 12) {
                statCell(value: "\(onWatchTrackCount)", label: "Tracks")
                statCell(value: TimeFmt.megabytes(onWatchBytes), label: "Used")
            }
        }
        .padding(15)
        .glassSurface(cornerRadius: 18)
    }

    private var transferCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transfer Queue").font(.system(size: 13, weight: .bold))
                Spacer()
                if transferCount > 0 {
                    Text("\(transferCount) pending")
                        .font(.system(size: 11)).foregroundStyle(Palette.ink3)
                }
            }
            .padding(.bottom, transferCount > 0 ? 8 : 2)

            if transferCount > 0 {
                Text("\(transferCount) tracks waiting to transfer, \(failedCount) failed")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.ink3)
                    .padding(.bottom, 8)
            } else {
                Text("No pending transfers")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.ink3)
                    .padding(.bottom, 2)
            }
        }
        .padding(15)
        .glassSurface(cornerRadius: 18)
    }

    private var managementCard: some View {
        VStack(spacing: 0) {
            Button {
                Task { await appState.resendCatalogToWatch() }
            } label: {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.brass)
                    Text("Re-send Catalog to Watch")
                        .font(.system(size: 13.5))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink3)
                }
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            Divider().overlay(Palette.hairline)
            Button {
                Task { await appState.removeAllFromWatch(); await refresh() }
            } label: {
                HStack {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.danger)
                    Text("Remove All from Watch")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Palette.danger)
                    Spacer()
                }
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
        }
        .padding(15)
        .glassSurface(cornerRadius: 18)
    }

    private func statCell(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 17, weight: .bold))
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Palette.ink3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .glassSurface(cornerRadius: 8)
    }

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
        case .reachable: return "Watch Connected"
        case .installedNotReachable: return "Watch Paired — Not Reachable"
        case .notInstalled: return "Watch Not Paired"
        case .unsupported: return "Watch Unavailable"
        }
    }

    private var statusDetail: String? {
        switch appState.watchSessionState {
        case .reachable: return "Your Apple Watch is connected and ready."
        case .installedNotReachable: return "Watch is paired but not currently reachable. Transfers will resume when in range."
        case .notInstalled: return "Pair an Apple Watch to sync music for offline playback."
        case .unsupported: return "This device does not support Apple Watch."
        }
    }

    private func refresh() async {
        await appState.refreshWatchState()
        let records: [WatchManifestRecord] = (try? await appState.store.dbQueue.read { db in
            try WatchManifestRecord.fetchAll(db)
        }) ?? []
        onWatchTrackCount = records.count
        onWatchBytes = records.reduce(0) { $0 + $1.bytes }
        let transfers: [WatchTransferRecord] = (try? await appState.store.dbQueue.read { db in
            try WatchTransferRecord.fetchAll(db)
        }) ?? []
        transferCount = transfers.filter { $0.state == "queued" || $0.state == "sending" }.count
        failedCount = transfers.filter { $0.state == "failed" }.count
    }
}
