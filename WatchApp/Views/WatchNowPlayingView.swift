import SwiftUI
import TonearmWatchCore
import TonearmWatchProtocol

struct WatchNowPlayingView: View {
    @ObservedObject private var player = WatchPlayer.shared
    @ObservedObject private var remote = WatchRemotePlayer.shared
    @ObservedObject private var coordinator = WatchPlaybackCoordinator.shared
    @ObservedObject private var model = WatchAppAssembly.shared.model
    @Environment(\.dismiss) private var dismiss
    @State private var crownValue: Double = 0.5
    @State private var showTargetSwitch = false

    var body: some View {
        VStack(spacing: 0) {
            targetRow
            Divider().padding(.vertical, 2)
            Group {
                if coordinator.target == .iPhone {
                    remoteBody
                } else {
                    localBody
                }
            }
        }
        .onAppear { if coordinator.target == .iPhone { remote.startClock() } }
        .onDisappear { remote.stopClock() }
        .onChange(of: coordinator.target) { _, target in
            if target == .iPhone { remote.startClock() } else { remote.stopClock() }
        }
        .navigationTitle("Now Playing")
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

    // MARK: - Target row (always visible, §7.1)

    private var targetRow: some View {
        Button {
            showTargetSwitch = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: coordinator.target == .iPhone ? "iphone" : "applewatch")
                    .font(.system(size: 12))
                Text(coordinator.target == .iPhone ? "Playing on iPhone" : "Playing on Apple Watch")
                    .font(.system(.caption2))
                Spacer()
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("watch.now.target")
        .accessibilityValue(coordinator.target == .iPhone ? "iPhone" : "Apple Watch")
    }

    private var canOfferOtherTarget: Bool { otherTargetUnavailableReason == nil }

    private var otherTargetTitle: String {
        coordinator.target == .iPhone ? "Switch to Apple Watch" : "Switch to iPhone"
    }

    /// Why the other target can't be chosen right now, or `nil` when it can.
    private var otherTargetUnavailableReason: String? {
        switch coordinator.target {
        case .iPhone:
            // Moving to the watch needs the current track downloaded here.
            if remote.state?.currentItem?.isDownloadedOnWatch == true { return nil }
            if player.currentTrack != nil { return nil }  // a local queue already exists
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
            // `remote.clockTick` — a @Published Int the W7 timer bumps each second — re-invokes
            // this body so `Date()` and the predicted elapsed below stay current without a new
            // snapshot.
            let now = Date()
            let elapsed = state.predictedElapsed(at: now)
            let duration = item.durationSeconds ?? 0
            VStack(spacing: 0) {
                Text(item.title)
                    .font(.system(.headline)).fontWeight(.semibold)
                    .lineLimit(2).multilineTextAlignment(.center)
                    .padding(.horizontal, 12).padding(.top, 8)
                    .accessibilityIdentifier("watch.now.title")
                Text(item.artist.isEmpty ? (state.collectionTitle ?? "iPhone") : item.artist)
                    .font(.system(.caption2)).foregroundStyle(.secondary).lineLimit(1).padding(.top, 4)

                Spacer(minLength: 8)

                progressBar(fraction: duration > 0 ? elapsed / duration : 0)
                    .padding(.horizontal, 16)
                HStack {
                    Text(WatchTimeFmt.mmss(elapsed)).accessibilityIdentifier("watch.now.elapsed")
                    Spacer()
                    Text("-\(WatchTimeFmt.mmss(max(0, duration - elapsed)))")
                        .accessibilityIdentifier("watch.now.remaining")
                }
                .font(.system(.caption2)).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.top, 2)

                HStack(spacing: 24) {
                    Button { remote.previous() } label: {
                        Image(systemName: "backward.fill").font(.system(size: 22))
                    }
                    .accessibilityIdentifier("watch.now.previous")
                    Button { remote.togglePlayPause() } label: {
                        Image(systemName: state.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 30))
                    }
                    .accessibilityIdentifier("watch.now.playPause")
                    .accessibilityValue(state.isPlaying ? "playing" : "paused")
                    Button { remote.next() } label: {
                        Image(systemName: "forward.fill").font(.system(size: 22))
                    }
                    .accessibilityIdentifier("watch.now.next")
                }
                .buttonStyle(.plain).frame(maxWidth: .infinity).padding(.vertical, 8)

                HStack(spacing: 12) {
                    NavigationLink(destination: WatchUpNextView()) {
                        Image(systemName: "list.bullet").font(.system(size: 14))
                    }
                    .accessibilityIdentifier("watch.now.upNext")
                    Spacer()
                    if state.isStale(at: now) {
                        Text("Updating…").font(.system(.caption2)).foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal, 16)
            }
        } else {
            VStack(spacing: 8) {
                Text("Nothing Playing on iPhone")
                    .font(.system(.headline)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if !model.phoneReachable {
                    Text("Your iPhone isn't reachable.")
                        .font(.system(.caption2)).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 32).padding(.horizontal, 12)
        }
    }

    /// §7.5 — the phone dropped mid-playback and its track is downloaded here. Explicit choice,
    /// never an automatic handoff, never a claim of gapless playback.
    private var continueOnWatchCard: some View {
        VStack(spacing: 8) {
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
        .padding(.horizontal, 12).padding(.top, 12)
    }

    // MARK: - W8 — this-watch target (local)

    @ViewBuilder
    private var localBody: some View {
        if let track = player.currentTrack {
            VStack(spacing: 0) {
                if let hint = player.routeHint {
                    Text(hint)
                        .font(.system(.caption2)).foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12).padding(.top, 8)
                        .accessibilityIdentifier("watch.now.routeHint")
                }
                Text(track.title)
                    .font(.system(.headline, design: .default)).fontWeight(.semibold)
                    .lineLimit(2).multilineTextAlignment(.center)
                    .padding(.horizontal, 12).padding(.top, 12)
                    .accessibilityIdentifier("watch.now.title")

                Text(subtitle(for: track))
                    .font(.system(.caption2)).foregroundStyle(.secondary).lineLimit(1).padding(.top, 4)

                Spacer(minLength: 8)

                progressBar(fraction: player.duration > 0 ? player.elapsed / player.duration : 0)
                    .padding(.horizontal, 16)

                HStack {
                    Text(WatchTimeFmt.mmss(player.elapsed))
                        .accessibilityIdentifier("watch.now.elapsed")
                        .accessibilityValue(WatchTimeFmt.mmss(player.elapsed))
                    Spacer()
                    Text("-\(WatchTimeFmt.mmss(max(0, player.duration - player.elapsed)))")
                        .accessibilityIdentifier("watch.now.remaining")
                }
                .font(.system(.caption2)).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.top, 2)

                transport
                    .padding(.top, 8).padding(.bottom, 8)

                HStack(spacing: 12) {
                    NavigationLink(destination: WatchUpNextView()) {
                        Image(systemName: "list.bullet").font(.system(size: 14))
                    }
                    .accessibilityIdentifier("watch.now.upNext")

                    Spacer()

                    volumeControl
                }
                .padding(.horizontal, 16)
            }
            .onAppear { crownValue = player.volume }
            .focusable(true)
            .digitalCrownRotation($crownValue, from: 0.0, through: 1.0, by: 0.02,
                                  sensitivity: .low, isContinuous: true)
            .onChange(of: crownValue) { _, newValue in player.volume = newValue }
        } else {
            Text("Nothing Playing")
                .font(.system(.headline, design: .default))
                .foregroundStyle(.secondary)
                .padding(.top, 40)
        }
    }

    // MARK: - Shared bits

    private func progressBar(fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.3)).frame(height: 4)
                Capsule().fill(.tint)
                    .frame(width: max(0, geo.size.width * min(1, max(0, fraction))), height: 4)
            }
        }
        .frame(height: 4)
    }

    private var transport: some View {
        HStack(spacing: 24) {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 24))
            }
            .accessibilityIdentifier("watch.now.previous")

            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 32))
            }
            .accessibilityIdentifier("watch.now.playPause")
            .accessibilityValue(player.isPlaying ? "playing" : "paused")

            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 24))
            }
            .accessibilityIdentifier("watch.now.next")
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private var volumeControl: some View {
        HStack(spacing: 4) {
            Image(systemName: "speaker.fill").font(.system(size: 10)).foregroundStyle(.secondary)
            Slider(value: $player.volume, in: 0...1).tint(.white.opacity(0.5)).frame(width: 60)
        }
    }

    private func subtitle(for track: WatchTrackSnapshot) -> String {
        var parts: [String] = []
        if !track.artist.isEmpty { parts.append(track.artist) }
        if let d = track.durationSeconds { parts.append(WatchTimeFmt.mmss(d)) }
        return parts.joined(separator: " · ")
    }
}
