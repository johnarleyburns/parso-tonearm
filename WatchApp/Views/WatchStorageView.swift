import SwiftUI
import TonearmWatchCore
import TonearmWatchProtocol

/// Watch redesign §5 D2 — Storage & Diagnostics. A storage bar, a readable last-playback line
/// (the full redacted JSON stays one tap away as "Show Codes"), the connection state, and Remove
/// All with a confirmation.
struct WatchStorageView: View {
    @ObservedObject private var model = WatchAppAssembly.shared.model
    @ObservedObject private var player = WatchPlayer.shared
    @ObservedObject private var chrome = WatchAppAssembly.shared.chrome
    @State private var confirmRemoveAll = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Storage").font(.caption2).foregroundStyle(.secondary)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.18))
                            Capsule().fill(WatchPalette.accent).frame(width: geo.size.width * usedFraction)
                        }
                    }
                    .frame(height: 6)
                    HStack {
                        Text("\(WatchTimeFmt.megabytes(model.storage?.readyBytes ?? 0)) music")
                        Spacer()
                        if let free = model.storage?.freeBytes, free > 0 {
                            Text("\(WatchTimeFmt.megabytes(free)) free")
                        }
                    }
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
                .padding(.vertical, 4)
                .watchCardRow()
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("watch.downloads.storage")
            }

            Section("iPhone") {
                HStack(spacing: 6) {
                    Image(systemName: model.phoneReachable ? "iphone.radiowaves.left.and.right" : "iphone.slash")
                        .foregroundStyle(model.phoneReachable ? WatchPalette.success : .secondary)
                    (model.phoneReachable ? Text("Connected") : Text("Not reachable"))
                }
                .watchCardRow()
                .accessibilityIdentifier("watch.connection.status")
                .accessibilityValue(model.phoneReachable ? "connected" : "unreachable")
            }

            Section("Diagnostics") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last playback").font(.caption2).foregroundStyle(.secondary)
                    Text(lastPlaybackLine).font(WatchTypography.code)
                }
                .watchCardRow()
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("watch.storage.lastPlayback")
                NavigationLink {
                    WatchDiagnosticsView()
                } label: {
                    Label("Show Codes", systemImage: "waveform.path.ecg")
                }
                .watchCardRow()
                .accessibilityIdentifier("watch.storage.diagnostics")
            }

            if let notice = model.recoveryNotice {
                Section {
                    Text(notice).font(.caption2).foregroundStyle(.secondary)
                }
            }

            if !model.tracks.isEmpty {
                Section {
                    Button("Remove All Downloads", role: .destructive) { confirmRemoveAll = true }
                        .watchCardRow()
                        .disabled(!chrome.showsConnectedFeatures)
                        .accessibilityIdentifier("watch.storage.removeAll")
                } footer: {
                    if !chrome.showsConnectedFeatures {
                        Text("Your iPhone manages downloads. Bring it nearby to remove them.")
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Storage")
        .task { await model.refresh() }
        .confirmationDialog("Remove all downloads?", isPresented: $confirmRemoveAll, titleVisibility: .visible) {
            Button("Remove All", role: .destructive) {
                Task { await WatchAppAssembly.shared.controlDownloads(.stop) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All music is removed from this watch. You can download it again from your iPhone.")
        }
    }

    private var usedFraction: Double {
        guard let storage = model.storage else { return 0 }
        let total = Double(storage.readyBytes + max(0, storage.freeBytes))
        return total > 0 ? min(1, Double(storage.readyBytes) / total) : 0
    }

    private var lastPlaybackLine: String {
        if let code = player.lastPlaybackErrorCode { return code }
        switch player.playbackPhase {
        case .playing: return String(localized: "playing")
        case .paused: return String(localized: "paused")
        case .idle: return String(localized: "nothing played yet")
        default: return player.playbackPhase.rawValue
        }
    }
}
