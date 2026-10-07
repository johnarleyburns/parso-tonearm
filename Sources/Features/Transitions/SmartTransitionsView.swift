import SwiftUI
import TonearmCore

struct SmartTransitionsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var prep: TransitionPrepService
    @AppStorage("smartTransitionsEnabled") private var enabled = true
    @AppStorage("smartTransitionsEverywhere") private var everywhere = false
    @AppStorage("smartTransitionsWiFiOnly") private var wifiOnly = true

    private var prepWindow: [TrackRow] {
        Array(player.queue.dropFirst(max(0, player.index)))
    }

    var body: some View {
        Section("Smart transitions") {
            Toggle("Use Smart transitions", isOn: $enabled)
            Toggle("Use for everything", isOn: $everywhere)
                .disabled(!enabled)
            Toggle("Prepare remote tracks on Wi-Fi only", isOn: $wifiOnly)
                .disabled(!enabled)
            Text("On for mixes by default. Platterhead prepares every track in the current queue one at a time.")
                .font(Typography.caption)
                .foregroundStyle(Palette.inkSecondary)
            HStack {
                Button("Prepare whole mix now") { prep.prepare(rows: prepWindow, appState: appState) }
                Button("Retry failed") { prep.retryFailed(rows: prepWindow, appState: appState) }
                Spacer()
                if !player.upNextTracks.isEmpty { Button("Stop") { prep.stop() } }
            }
        }
        .task {
            player.smartTransitionsEnabled = enabled
            if enabled { prep.prepare(rows: prepWindow, appState: appState) }
        }
        .onChange(of: enabled) { _, isEnabled in
            player.smartTransitionsEnabled = isEnabled
            guard isEnabled else { prep.stop(); return }
            prep.prepare(rows: prepWindow, appState: appState)
        }
        // The prep service reads this setting itself; re-run so a change applies at once.
        .onChange(of: wifiOnly) { _, _ in
            guard enabled else { return }
            prep.prepare(rows: prepWindow, appState: appState)
        }
        .onChange(of: prepWindow.map { $0.track.id }) { _, _ in
            guard enabled else { return }
            prep.prepare(rows: prepWindow, appState: appState)
        }
    }

}
