import SwiftUI
import TonearmWatchCore
import TonearmWatchProtocol

/// W12 — store recovery / incompatibility / empty. Never a dead end; diagnostics are state codes
/// and byte counts only, never titles or paths.
struct WatchRecoveryView: View {
    @ObservedObject private var model = WatchAppAssembly.shared.model
    @Environment(\.dismiss) private var dismiss
    @State private var showDetails = false

    private var launchState: WatchStoreLaunchState { WatchAppAssembly.shared.launchState }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(WatchTypography.iconLarge).foregroundStyle(.tint)
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
        case .recovered: String(localized: "Library Recovered")
        case .degraded: String(localized: "Library Unavailable")
        case .opening, .ready: String(localized: "Watch Library")
        }
    }
}
