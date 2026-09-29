import SwiftUI
import TonearmCore

struct SmartTransitionsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var player: AudioPlayer
    @StateObject private var prep = TransitionPrepService()
    @AppStorage("smartTransitionsEnabled") private var enabled = true
    @AppStorage("smartTransitionsEverywhere") private var everywhere = false

    private var prepWindow: [TrackRow] {
        Array(([player.currentTrack].compactMap { $0 } + player.upNextTracks).prefix(3))
    }

    var body: some View {
        Section("Smart transitions") {
            Toggle("Use Smart transitions", isOn: $enabled)
            Toggle("Use for everything", isOn: $everywhere)
                .disabled(!enabled)
            Text("On for mixes by default. Platterhead prepares the current track and the next two one at a time.")
                .font(Typography.caption)
                .foregroundStyle(Palette.inkSecondary)
            ForEach(prepWindow, id: \.id) { row in
                if let id = row.track.id {
                    LabeledContent(row.track.title, value: stateLabel(prep.transitionPrepState(for: id)))
                }
            }
            HStack {
                Button("Prepare whole mix now") { prep.prepare(rows: prepWindow, appState: appState) }
                Button("Retry failed") { prep.retryFailed(rows: prepWindow, appState: appState) }
                Spacer()
                if !player.upNextTracks.isEmpty { Button("Stop") { prep.stop() } }
            }
        }
        .task { if enabled { prep.prepare(rows: prepWindow, appState: appState) } }
        .onChange(of: enabled) { _, isEnabled in
            guard isEnabled else { prep.stop(); return }
            prep.prepare(rows: prepWindow, appState: appState)
        }
    }

    private func stateLabel(_ state: GridPrepState) -> String {
        switch state {
        case .ready: "Ready"
        case .queued: "Queued"
        case .downloading(let progress), .analyzing(let progress): "\(Int(progress * 100))%"
        case .waitingForNetwork: "Waiting for network"
        case .waitingForWiFi: "Waiting for Wi-Fi"
        case .failed: "Failed"
        case .cancelled: "Stopped"
        }
    }
}
