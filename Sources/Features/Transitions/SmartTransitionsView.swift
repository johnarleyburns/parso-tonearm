import SwiftUI
import TonearmCore

struct SmartTransitionsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var player: AudioPlayer
    @StateObject private var prep = TransitionPrepService()
    @AppStorage("smartTransitionsEnabled") private var enabled = true
    @AppStorage("smartTransitionsEverywhere") private var everywhere = false
    @AppStorage("smartTransitionsWiFiOnly") private var wifiOnly = true

    private var prepWindow: [TrackRow] {
        Array(([player.currentTrack].compactMap { $0 } + player.upNextTracks).prefix(3))
    }

    var body: some View {
        Section("Smart transitions") {
            Toggle("Use Smart transitions", isOn: $enabled)
            Toggle("Use for everything", isOn: $everywhere)
                .disabled(!enabled)
            Toggle("Prepare remote tracks on Wi-Fi only", isOn: $wifiOnly)
                .disabled(!enabled)
            Text("On for mixes by default. Platterhead prepares the current track and the next two one at a time.")
                .font(Typography.caption)
                .foregroundStyle(Palette.inkSecondary)
            ForEach(prepWindow, id: \.id) { row in
                if let id = row.track.id {
                    LabeledContent(row.track.title,
                                   value: stateLabel(prep.transitionPrepState(for: id),
                                                     since: prep.transitionPrepSince(for: id)))
                }
            }
            HStack {
                Button("Prepare whole mix now") { prep.prepare(rows: prepWindow, appState: appState) }
                Button("Retry failed") { prep.retryFailed(rows: prepWindow, appState: appState) }
                Spacer()
                if !player.upNextTracks.isEmpty { Button("Stop") { prep.stop() } }
            }
        }
        .task {
            prep.wifiOnly = wifiOnly
            if enabled { prep.prepare(rows: prepWindow, appState: appState) }
        }
        .onChange(of: enabled) { _, isEnabled in
            guard isEnabled else { prep.stop(); return }
            prep.prepare(rows: prepWindow, appState: appState)
        }
        .onChange(of: wifiOnly) { _, value in prep.wifiOnly = value }
        .onChange(of: prepWindow.map { $0.track.id }) { _, _ in
            guard enabled else { return }
            prep.prepare(rows: prepWindow, appState: appState)
        }
    }

    private func stateLabel(_ state: GridPrepState, since: Date?) -> String {
        let age = since.map { " · \(relativeAge($0))" } ?? ""
        return switch state {
        case .ready: "Ready\(age)"
        case .queued: "Queued\(age)"
        case .downloading(let progress), .analyzing(let progress): "\(Int(progress * 100))%\(age)"
        case .waitingForNetwork: "Waiting for network\(age)"
        case .waitingForWiFi: "Waiting for Wi-Fi\(age)"
        case .failed: "Failed\(age)"
        case .cancelled: "Stopped\(age)"
        }
    }

    private func relativeAge(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "since now" }
        return "since \(seconds / 60)m ago"
    }
}
