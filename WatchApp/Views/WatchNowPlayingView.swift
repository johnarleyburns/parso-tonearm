import SwiftUI
import UIKit
import TonearmWatchCore
import TonearmWatchProtocol

/// W7 (iPhone target) / W8 (this-watch target) Now Playing. One transport layout, one engine at a
/// time, target always visible (§7.1). Laid out like Apple Music / Spotify on the watch: a vertical
/// `ScrollView` so nothing is clipped under the toolbar, artwork up top, then title/artist, the
/// scrubber, a roomy transport row, and a footer. Closing only dismisses the sheet (§7).
struct WatchNowPlayingView: View {
    @ObservedObject private var player = WatchPlayer.shared
    @ObservedObject private var remote = WatchRemotePlayer.shared
    @ObservedObject private var coordinator = WatchPlaybackCoordinator.shared
    @ObservedObject private var model = WatchAppAssembly.shared.model
    @Environment(\.dismiss) private var dismiss
    @State private var crownValue: Double = 0.5
    @State private var showTargetSwitch = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                #if DEBUG
                // Surfaces AVPlayer's transport rate (0 paused / ~1 playing) for the on-device
                // audio-output pass — the simulator has no audio hardware. DEBUG + UI_TESTING only.
                if ProcessInfo.processInfo.arguments.contains("UI_TESTING") {
                    Text("rate \(String(format: "%.2f", player.outputRate))")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("watch.now.debugRate")
                }
                #endif
                targetPill
                Group {
                    if coordinator.target == .iPhone {
                        remoteBody
                    } else {
                        localBody
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)
            .padding(.bottom, 14)
        }
        .onAppear { if coordinator.target == .iPhone { remote.startClock() } }
        .onDisappear { remote.stopClock() }
        .onChange(of: coordinator.target) { _, target in
            if target == .iPhone { remote.startClock() } else { remote.stopClock() }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                // Close only dismisses the sheet — playback continues on whichever target owns it,
                // and the root's Now Playing chip stays available to reopen it (§7).
                Button("Close") { dismiss() }
            }
        }
        .confirmationDialog("Playback Target", isPresented: $showTargetSwitch) {
            if canOfferOtherTarget {
                Button(otherTargetTitle) { coordinator.setTarget(coordinator.target.other) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(otherTargetUnavailableReason ?? "Choose where playback runs.")
        }
    }

    // MARK: - Target pill (always visible, §7.1)

    private var targetPill: some View {
        Button {
            showTargetSwitch = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: coordinator.target == .iPhone ? "iphone" : "applewatch")
                    .font(.system(size: 11))
                Text(coordinator.target == .iPhone ? "iPhone" : "Apple Watch")
                    .font(.system(.caption2, design: .rounded)).fontWeight(.medium)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("watch.now.target")
        .accessibilityLabel("Playback target")
        .accessibilityValue(coordinator.target == .iPhone ? "iPhone" : "Apple Watch")
        .accessibilityHint("Switches between iPhone and Apple Watch")
    }

    private var canOfferOtherTarget: Bool { otherTargetUnavailableReason == nil }

    private var otherTargetTitle: String {
        coordinator.target == .iPhone ? "Switch to Apple Watch" : "Switch to iPhone"
    }

    /// Why the other target can't be chosen right now, or `nil` when it can.
    private var otherTargetUnavailableReason: String? {
        switch coordinator.target {
        case .iPhone:
            if remote.state?.currentItem?.isDownloadedOnWatch == true { return nil }
            if player.currentTrack != nil { return nil }
            return "This track isn't downloaded on your watch."
        case .thisWatch:
            return model.phoneReachable ? nil : "Your iPhone isn't reachable."
        }
    }

    // MARK: - W7 — iPhone target (remote)

    @ViewBuilder
    private var remoteBody: some View {
        if coordinator.continuePrompt != nil {
            continueOnWatchCard
        } else if let state = remote.state, let item = state.currentItem {
            // `remote.clockTick` — a @Published Int the W7 timer bumps each second — re-invokes this
            // body so the predicted elapsed below stays current without a new snapshot.
            let now = Date()
            let elapsed = state.predictedElapsed(at: now)
            let duration = item.durationSeconds ?? 0
            VStack(spacing: 12) {
                artwork(nil)
                trackTitles(title: item.title,
                            subtitle: item.artist.isEmpty ? (state.collectionTitle ?? "iPhone") : item.artist)
                scrubber(elapsed: elapsed, duration: duration)
                transport(isPlaying: state.isPlaying,
                          previous: remote.previous, toggle: remote.togglePlayPause, next: remote.next)
                HStack(spacing: 12) {
                    upNextLink
                    Spacer()
                    if state.isStale(at: now) {
                        Label("Updating…", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(.caption2)).foregroundStyle(.orange)
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "iphone").font(.system(size: 26)).foregroundStyle(.secondary)
                Text("Nothing Playing on iPhone")
                    .font(.system(.headline)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if !model.phoneReachable {
                    Text("Your iPhone isn't reachable.")
                        .font(.system(.caption2)).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 24)
        }
    }

    /// §7.5 — the phone dropped mid-playback and its track is downloaded here.
    private var continueOnWatchCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "iphone.slash").font(.system(size: 24)).foregroundStyle(.orange)
            Text("iPhone Unavailable")
                .font(.system(.headline)).multilineTextAlignment(.center)
            if let title = coordinator.continuePrompt.flatMap({ _ in remote.state?.currentItem?.title }) {
                Text(title).font(.system(.caption2)).foregroundStyle(.secondary).lineLimit(2)
            }
            Text("This track is downloaded.")
                .font(.system(.caption2)).foregroundStyle(.secondary)
            Button {
                coordinator.acceptContinue()
            } label: {
                Label("Continue on Apple Watch", systemImage: "play.fill")
                    .font(.system(.caption)).frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("watch.now.continue")
            Button("Keep Waiting") { coordinator.dismissContinue() }
                .font(.system(.caption2))
        }
        .padding(.top, 6)
    }

    // MARK: - W8 — this-watch target (local)

    @ViewBuilder
    private var localBody: some View {
        if let track = player.currentTrack {
            VStack(spacing: 12) {
                artwork(player.artwork)
                trackTitles(title: track.title, subtitle: subtitle(for: track))

                if let problem = player.audioRouteProblem {
                    routeProblemCard(problem)
                } else {
                    if let hint = player.routeHint {
                        Label(hint, systemImage: "exclamationmark.triangle")
                            .font(.system(.caption2)).foregroundStyle(.orange)
                            .labelStyle(.titleAndIcon).multilineTextAlignment(.center)
                            .accessibilityIdentifier("watch.now.routeHint")
                    }
                    scrubber(elapsed: player.elapsed, duration: player.duration)
                    transport(isPlaying: player.isPlaying,
                              previous: player.previous, toggle: player.togglePlayPause, next: player.next)
                    HStack(spacing: 12) {
                        upNextLink
                        Spacer()
                        volumeControl
                    }
                }
            }
            .onAppear { crownValue = player.volume }
            .focusable(player.audioRouteProblem == nil)
            .digitalCrownRotation($crownValue, from: 0.0, through: 1.0, by: 0.02,
                                  sensitivity: .low, isContinuous: true)
            .onChange(of: crownValue) { _, newValue in player.volume = newValue }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "music.note").font(.system(size: 26)).foregroundStyle(.secondary)
                Text("Nothing Playing").font(.system(.headline)).foregroundStyle(.secondary)
            }
            .padding(.top, 28)
        }
    }

    private func routeProblemCard(_ problem: String) -> some View {
        VStack(spacing: 8) {
            Label("Choose an Audio Output", systemImage: "airpods")
                .font(.system(.headline)).labelStyle(.titleAndIcon)
                .multilineTextAlignment(.center)
            Text(problem)
                .font(.system(.caption2)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                player.retryAudioRoute()
            } label: {
                Label("Choose Output", systemImage: "airplayaudio")
                    .font(.system(.caption)).frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("watch.now.chooseRoute")
            Text("Playback stays paused. Your queue is safe.")
                .font(.system(.caption2)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 4)
    }

    // MARK: - Shared building blocks

    private func artwork(_ image: UIImage?) -> some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [.blue.opacity(0.35), .purple.opacity(0.35)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.system(size: 28)).foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .frame(width: 104, height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityIdentifier("watch.now.artwork")
        .accessibilityLabel(image == nil ? "No artwork" : "Artwork")
    }

    private func trackTitles(title: String, subtitle: String) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.system(.headline, design: .rounded)).fontWeight(.semibold)
                .lineLimit(2).multilineTextAlignment(.center)
                .accessibilityIdentifier("watch.now.title")
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(.caption2)).foregroundStyle(.secondary)
                    .lineLimit(1).multilineTextAlignment(.center)
            }
        }
    }

    private func scrubber(elapsed: Double, duration: Double) -> some View {
        VStack(spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.3))
                    Capsule().fill(.tint)
                        .frame(width: max(0, geo.size.width * fraction(elapsed, duration)))
                }
            }
            .frame(height: 4)
            HStack {
                Text(WatchTimeFmt.mmss(elapsed)).accessibilityIdentifier("watch.now.elapsed")
                    .accessibilityValue(WatchTimeFmt.mmss(elapsed))
                Spacer()
                Text("-\(WatchTimeFmt.mmss(max(0, duration - elapsed)))")
                    .accessibilityIdentifier("watch.now.remaining")
            }
            .font(.system(.caption2)).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func transport(isPlaying: Bool, previous: @escaping () -> Void,
                           toggle: @escaping () -> Void, next: @escaping () -> Void) -> some View {
        HStack(spacing: 26) {
            Button(action: previous) {
                Image(systemName: "backward.fill").font(.system(size: 22))
            }
            .accessibilityIdentifier("watch.now.previous")
            .accessibilityLabel("Previous")

            Button(action: toggle) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(.system(size: 34))
            }
            .accessibilityIdentifier("watch.now.playPause")
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            .accessibilityValue(isPlaying ? "playing" : "paused")

            Button(action: next) {
                Image(systemName: "forward.fill").font(.system(size: 22))
            }
            .accessibilityIdentifier("watch.now.next")
            .accessibilityLabel("Next")
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }

    private var upNextLink: some View {
        NavigationLink(destination: WatchUpNextView()) {
            Image(systemName: "list.bullet").font(.system(size: 15))
        }
        .accessibilityIdentifier("watch.now.upNext")
        .accessibilityLabel("Up Next")
    }

    private var volumeControl: some View {
        HStack(spacing: 4) {
            Image(systemName: "speaker.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(value: $player.volume, in: 0...1).tint(.white.opacity(0.5)).frame(width: 64)
                .accessibilityLabel("Volume")
        }
    }

    private func fraction(_ elapsed: Double, _ duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, elapsed / duration))
    }

    private func subtitle(for track: WatchTrackSnapshot) -> String {
        var parts: [String] = []
        if !track.artist.isEmpty { parts.append(track.artist) }
        if !track.albumTitle.isEmpty { parts.append(track.albumTitle) }
        return parts.joined(separator: " · ")
    }
}
