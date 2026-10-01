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
            player.smartTransitionsEnabled = enabled
            if enabled { prep.prepare(rows: prepWindow, appState: appState) }
        }
        .onChange(of: enabled) { _, isEnabled in
            player.smartTransitionsEnabled = isEnabled
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
        let base = switch state {
        case .notPrepared: String(localized: "Not prepared")
        case .ready: String(localized: "Ready")
        case .queued: String(localized: "Queued")
        case .downloading(let progress), .analyzing(let progress): progress.formatted(.percent.precision(.fractionLength(0)))
        case .waitingForNetwork: String(localized: "Waiting for network")
        case .waitingForWiFi: String(localized: "Waiting for Wi-Fi")
        case .failed: String(localized: "Failed")
        case .cancelled: String(localized: "Stopped")
        }
        return since.map { String(localized: "\(base) · \(relativeAge($0))") } ?? base
    }

    private func relativeAge(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return String(localized: "since now") }
        let minutes = Duration.seconds(seconds / 60 * 60).formatted(.units(allowed: [.minutes], width: .narrow))
        return String(localized: "since \(minutes) ago")
    }
}
