import SwiftUI
import UIKit
import TonearmWatchCore
import TonearmWatchProtocol

/// W7 (iPhone-owned) / W8 (this-watch-owned) Now Playing. One transport layout, one engine at a
/// time, with the owner shown passively (§7.1). Laid out like Apple Music / Spotify on the watch: a vertical
/// `ScrollView` so nothing is clipped under the toolbar, artwork up top, then title/artist, the
/// scrubber, a roomy transport row, and a footer. Closing only dismisses the sheet (§7).
struct WatchNowPlayingView: View {
    @ObservedObject private var player = WatchPlayer.shared
    @ObservedObject private var remote = WatchRemotePlayer.shared
    @ObservedObject private var coordinator = WatchPlaybackCoordinator.shared
    @ObservedObject private var model = WatchAppAssembly.shared.model
    @Environment(\.dismiss) private var dismiss
    @State private var crownValue: Double = 0.5
    /// Track we asked the phone to download, so the row shows a spinner until it lands.
    @State private var pendingDownloadTrackID: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                ownerLabel
                #if DEBUG
                debugPlaybackState
                #endif
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
    }

    private var ownerLabel: some View {
        Label(coordinator.target == .iPhone ? "On iPhone" : "On Apple Watch",
              systemImage: coordinator.target == .iPhone ? "iphone" : "applewatch")
            .font(.system(.caption2, design: .rounded)).foregroundStyle(.secondary)
            .accessibilityIdentifier("watch.now.target")
            .accessibilityValue(coordinator.target == .iPhone ? "iPhone" : "Apple Watch")
    }

    @ViewBuilder
    private var debugPlaybackState: some View {
        VStack(spacing: 1) {
            Text("phase \(player.playbackPhase.rawValue)")
                .accessibilityIdentifier("watch.now.debugSession")
            Text("session \(player.sessionStatus)")
                .accessibilityIdentifier("watch.now.debugSessionStatus")
            Text("item \(player.itemReadiness.rawValue)")
                .accessibilityIdentifier("watch.now.debugItemState")
            Text("rate \(String(format: "%.2f", player.outputRate))")
                .accessibilityIdentifier("watch.now.debugRate")
            Text("duration \(String(format: "%.2f", player.duration))")
                .accessibilityIdentifier("watch.now.debugDuration")
            Text("generation \(player.playbackGenerationForDiagnostics)")
                .accessibilityIdentifier("watch.now.debugGeneration")
            if let code = player.lastPlaybackErrorCode {
                Text("error \(code)").accessibilityIdentifier("watch.now.debugError")
            }
        }
        .font(.system(size: 9)).foregroundStyle(.secondary)
        .accessibilityElement(children: .contain)
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
                downloadRow(for: item)
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

                // Local playback means the file is on the watch — show it, solid (§7 polish).
                Label("Downloaded", systemImage: "checkmark.circle.fill")
                    .font(.system(.caption2, design: .rounded)).foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
                    .accessibilityIdentifier("watch.now.download")
                    .accessibilityValue("downloaded")

                if let problem = player.audioRouteProblem {
                    routeProblemCard(problem)
                } else if let problem = player.playbackErrorMessage {
                    playbackProblemCard(problem)
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
                    HStack { upNextLink; Spacer() }
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

    private func playbackProblemCard(_ problem: String) -> some View {
        VStack(spacing: 8) {
            Label("Playback Failed", systemImage: "exclamationmark.triangle")
                .font(.system(.headline)).labelStyle(.titleAndIcon)
                .multilineTextAlignment(.center)
            Text(problem)
                .font(.system(.caption2)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                player.retryAudioRoute()
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
                    .font(.system(.caption)).frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("watch.now.retryPlayback")
        }
        .padding(.top, 4)
    }

    // MARK: - Download affordance (§7 polish)

    /// W7: the phone is playing this track and it may not be on the watch. Offer to download it —
    /// spinner while the phone works, solid check once it lands.
    @ViewBuilder
    private func downloadRow(for item: WatchTrackSummary) -> some View {
        if item.isDownloadedOnWatch {
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .font(.system(.caption2, design: .rounded)).foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
                .accessibilityIdentifier("watch.now.download")
                .accessibilityValue("downloaded")
        } else if let fraction = model.transferFraction(forTrackID: item.trackID.rawValue) {
            downloadingRing(fraction: fraction)
        } else if pendingDownloadTrackID == item.trackID.rawValue {
            downloadingRing(fraction: nil)
        } else {
            Button {
                requestDownload(of: item.trackID)
            } label: {
                Label("Download to Apple Watch", systemImage: "arrow.down.circle")
                    .font(.system(.caption)).frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("watch.now.download")
            .accessibilityValue("not downloaded")
        }
    }

    /// The closing byte-ring (or an indeterminate spinner before the first byte).
    private func downloadingRing(fraction: Double?) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().stroke(.secondary.opacity(0.25), lineWidth: 3)
                if let fraction {
                    Circle().trim(from: 0, to: max(0.02, min(1, fraction)))
                        .stroke(.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.35), value: fraction)
                } else {
                    ProgressView().scaleEffect(0.55)
                }
            }
            .frame(width: 20, height: 20)
            Text(fraction.map { "Downloading \(Int($0 * 100))%" } ?? "Downloading…")
                .font(.system(.caption2)).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("watch.now.download")
        .accessibilityValue(fraction.map { "downloading \(Int($0 * 100)) percent" } ?? "downloading")
    }

    private func requestDownload(of trackID: WatchTrackID) {
        pendingDownloadTrackID = trackID.rawValue
        Task { await WatchAppAssembly.shared.requestDownloadToThisWatch(trackID) }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            if pendingDownloadTrackID == trackID.rawValue,
               remote.state?.currentItem?.isDownloadedOnWatch != true {
                pendingDownloadTrackID = nil   // give the button back if it never landed
            }
        }
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
