import SwiftUI
import UIKit
import WatchKit
import TonearmWatchCore
import TonearmWatchProtocol

/// Watch redesign §5 N1/N2/S1–S5/T3/A1/A3 — one fixed, non-scrolling Now Playing face for both
/// engines. Artwork colours tint the background; the target chip names where the audio comes out;
/// big round transport; the Digital Crown is volume only (local or the iPhone's own player); a
/// bottom toolbar holds Output · Up Next · More. Failures replace the transport *in place* with a
/// Problem Card. Which engine is shown follows `WatchNowPlayingResolver` — playback started on the
/// iPhone appears here without silently switching the explicit target (§7.1).
struct WatchNowPlayingView: View {
    @ObservedObject private var player = WatchPlayer.shared
    @ObservedObject private var remote = WatchRemotePlayer.shared
    @ObservedObject private var coordinator = WatchPlaybackCoordinator.shared
    @ObservedObject private var model = WatchAppAssembly.shared.model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var crownValue: Double = 0.5
    @State private var crownTarget: WatchTarget?
    @State private var showingOutput = false
    @State private var choosingRoute = false
    /// Track we asked the phone to download, so the More row shows a spinner until it lands.
    @State private var pendingDownloadTrackID: String?

    var body: some View {
        ZStack {
            background
            VStack(spacing: 4) {
                chip
                content
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            // The close button and the clock share the top row; the chip gets its own row below
            // them (mockup N1) instead of sliding under both.
            .padding(.top, 8)
        }
        // UI-test diagnostics stay readable to XCUITest without taking layout space, so the
        // screen under test is the screen users see.
        .background(alignment: .top) {
            if showsDebugOverlay { debugPlaybackState.opacity(0.05).allowsHitTesting(false) }
        }
        .focusable(crownEnabled)
#if os(watchOS)
        .digitalCrownRotation($crownValue, from: 0.0, through: 1.0, by: 0.02,
                              sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true)
#endif
        .onChange(of: crownValue) { _, newValue in applyCrown(newValue) }
        .onAppear { syncCrown(); if shown == .iPhone { remote.startClock() } }
        .onDisappear { remote.stopClock() }
        .onChange(of: shown) { _, target in
            syncCrown()
            if target == .iPhone { remote.startClock() } else { remote.stopClock() }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(isPresented: $showingOutput) { WatchOutputSheet() }
    }

    // MARK: - Which engine

    private var shown: WatchTarget? { player.currentTrack == nil ? nil : .thisWatch }

    private var showsDebugOverlay: Bool {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        return args.contains("UI_TESTING") || args.contains("WATCH_DEBUG_OVERLAY")
        #else
        return false
        #endif
    }

    // MARK: - Background (artwork tint)

    private var background: some View {
        let colors = tintColors
        return RadialGradient(colors: [colors.0, colors.1, .black],
                              center: .top, startRadius: 0, endRadius: 210)
            .opacity(isLuminanceReduced ? 0.45 : 0.9)
            .ignoresSafeArea()
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: tintKey)
            .accessibilityElement()
            .accessibilityIdentifier("watch.now.artwork")
            .accessibilityLabel((hasArtwork ? Text("Artwork") : Text("No artwork")))
    }

    private var hasArtwork: Bool {
        shown == .iPhone ? remote.state?.snapshot.artworkColorHex != nil : player.artwork != nil
    }

    private var tintKey: String {
        shown == .iPhone ? (remote.state?.snapshot.artworkColorHex ?? "none") : (player.currentTrack?.id ?? "none")
    }

    private var tintColors: (Color, Color) {
        let base: Color
        if shown == .iPhone {
            base = Color(watchHex: remote.state?.snapshot.artworkColorHex) ?? WatchPalette.accent
        } else if let average = player.artworkTint {
            base = average
        } else {
            base = WatchPalette.accent
        }
        return (base.opacity(0.95), base.opacity(0.35))
    }

    // MARK: - Target chip

    private var chip: some View {
        let isPhone = shown == .iPhone
        let title: String
        if isPhone {
            title = String(localized: "iPhone")
        } else if let output = player.outputName {
            title = String(localized: "Apple Watch · \(output)")
        } else {
            title = String(localized: "Apple Watch")
        }
        let tone: WatchTargetChip.Tone = isPhone && !model.phoneReachable ? .warning : .onArtwork
        return WatchTargetChip(systemImage: isPhone ? "iphone" : "applewatch", title: title, tone: tone)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(isPhone ? "Playing on iPhone" : chipSpokenLocal))
            .accessibilityIdentifier("watch.now.target")
            .accessibilityValue(isPhone ? "iPhone" : "Apple Watch")
    }

    private var chipSpokenLocal: String {
        if let output = player.outputName {
            return String(localized: "Playing on Apple Watch through \(output)")
        }
        return String(localized: "Playing on Apple Watch")
    }

    // MARK: - Content per engine and state

    @ViewBuilder
    private var content: some View {
        if shown == .iPhone {
            remoteContent
        } else {
            localContent
        }
    }

    @ViewBuilder
    private var remoteContent: some View {
        if coordinator.continuePrompt != nil {
            continueOnWatchCard
        } else if let failure = remote.startFailure {
            phoneStartFailureCard(failure)
        } else if remote.isStarting {
            startingOnPhone
        } else if let state = remote.state, let item = state.currentItem {
            let now = Date()
            let elapsed = state.predictedElapsed(at: now)
            titles(item.title, subtitle: item.artist.isEmpty ? (state.collectionTitle ?? "") : item.artist)
            if isLuminanceReduced {
                alwaysOnElapsed(elapsed)
            } else {
                WatchProgressHairline(elapsed: elapsed, duration: item.durationSeconds ?? 0,
                                      showsTimes: dynamicTypeSize < .accessibility1)
                    .padding(.horizontal, 4)
                transport(isPlaying: state.isPlaying, isBusy: false,
                          previous: remote.previous, toggle: remote.togglePlayPause, next: remote.next)
                if state.isStale(at: now) {
                    Label("Updating…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption2).foregroundStyle(WatchPalette.accent)
                }
            }
        } else {
            emptyState(systemImage: "iphone", title: "Nothing Playing on iPhone",
                       message: model.phoneReachable ? nil : String(localized: "Your iPhone isn't reachable."))
        }
    }

    @ViewBuilder
    private var localContent: some View {
        if let track = player.currentTrack {
            titles(track.title, subtitle: localSubtitle(track))
            if let problem = player.audioRouteProblem {
                WatchProblemCard(
                    systemImage: "headphones", title: "Connect Headphones",
                    message: problem,
                    actions: [.init(title: "Choose Output", systemImage: "airplayaudio",
                                    isBusy: choosingRoute, identifier: "watch.now.chooseRoute") {
                        chooseRoute()
                    }],
                    code: player.lastPlaybackErrorCode)
            } else if let problem = player.playbackErrorMessage {
                WatchProblemCard(
                    systemImage: "exclamationmark.triangle", title: "Audio Didn't Start",
                    message: problem,
                    actions: [.init(title: "Try Again", systemImage: "arrow.clockwise",
                                    identifier: "watch.now.retryPlayback") { player.retryAudioRoute() }],
                    code: player.lastPlaybackErrorCode)
            } else if !isLuminanceReduced {
                WatchProgressHairline(elapsed: player.elapsed, duration: player.duration,
                                      showsTimes: dynamicTypeSize < .accessibility1)
                    .padding(.horizontal, 4)
                transport(isPlaying: player.isPlaying, isBusy: isLocalBusy,
                          previous: player.previous, toggle: player.togglePlayPause, next: player.next)
                if isLocalBusy {
                    Text(localStepLabel)
                        .font(.caption2).foregroundStyle(.secondary)
                        .accessibilityIdentifier("watch.now.step")
                } else if let hint = player.routeHint {
                    Label(hint, systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(WatchPalette.warning)
                        .accessibilityIdentifier("watch.now.routeHint")
                }
            } else {
                alwaysOnElapsed(player.elapsed)
            }
        } else {
            emptyState(systemImage: "music.note", title: "Nothing Playing", message: nil)
        }
    }

    /// S3: a play in flight shows a spinner in the play button and names the step — never a pause
    /// glyph before audio is confirmed.
    private var isLocalBusy: Bool {
        switch player.playbackPhase {
        case .activating, .loading, .ready: true
        default: false
        }
    }

    private var localStepLabel: String {
        switch player.playbackPhase {
        case .activating: String(localized: "Connecting to headphones…")
        case .loading: String(localized: "Loading from watch storage…")
        default: String(localized: "Starting…")
        }
    }

    /// A1 — wrist down: no transport, no ticking seconds; elapsed at minute granularity.
    private func alwaysOnElapsed(_ elapsed: Double) -> some View {
        TimelineView(.everyMinute) { _ in
            Text(WatchTimeFmt.mmss((elapsed / 60).rounded(.down) * 60))
                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.top, 8)
        }
    }

    private func titles(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.headline)
                .lineLimit(dynamicTypeSize >= .accessibility1 ? 2 : 1)
                .accessibilityIdentifier("watch.now.title")
            if !subtitle.isEmpty && dynamicTypeSize < .accessibility1 {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    private func transport(isPlaying: Bool, isBusy: Bool, previous: @escaping () -> Void,
                           toggle: @escaping () -> Void, next: @escaping () -> Void) -> some View {
        HStack {
            WatchTransportButton(systemImage: "backward.fill", label: Text("Previous"),
                                 diameterOverride: 40, action: previous)
                .accessibilityIdentifier("watch.now.previous")
            Spacer(minLength: 4)
            WatchTransportButton(systemImage: isPlaying ? "pause.fill" : "play.fill",
                                 label: isPlaying ? Text("Pause") : Text("Play"), role: .primary,
                                 isBusy: isBusy, diameterOverride: 50, action: toggle)
                .accessibilityIdentifier("watch.now.playPause")
                .accessibilityValue(isPlaying ? "playing" : "paused")
                .handGestureShortcut(.primaryAction)
            Spacer(minLength: 4)
            WatchTransportButton(systemImage: "forward.fill", label: Text("Next"),
                                 diameterOverride: 40, action: next)
                .accessibilityIdentifier("watch.now.next")
        }
        .padding(.horizontal, 2)
        .padding(.top, 2)
    }

    private func emptyState(systemImage: String, title: LocalizedStringKey, message: String?) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage).font(.title2).foregroundStyle(.secondary)
            Text(title).font(.headline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let message {
                Text(message).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(.top, 18)
    }

    // MARK: - T3 / S4 / S5 (iPhone)

    private var startingOnPhone: some View {
        VStack(spacing: 6) {
            Image(systemName: "iphone").font(.title2)
            Text("Starting on iPhone…").font(.headline)
            if let title = remote.startingTitle {
                Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            ProgressView().padding(.top, 4)
        }
        .padding(.top, 14)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("watch.now.starting")
    }

    private func phoneStartFailureCard(_ failure: WatchRemotePlayer.StartFailure) -> some View {
        let downloaded = failure.downloadedAlternativeCount
        let action = downloaded > 0
            ? WatchProblemCard.Action(title: "Play on Watch", isPrimary: true,
                                      identifier: "watch.now.playHereInstead") {
                Task { await WatchAppAssembly.shared.playLocalAlternative(for: failure.command) }
            }
            : nil
        return WatchProblemCard(systemImage: "applewatch.slash", title: "Track Isn't on This Watch",
                                message: String(localized: "Only downloaded audio can play here. Send music from Platterhead on your iPhone."),
                                actions: action.map { [$0] } ?? [], code: failure.code)
    }

    private var continueOnWatchCard: some View {
        let title = remote.state?.currentItem?.title
        let message = title.map { String(localized: "“\($0)” is on this watch. Continue here?") }
            ?? String(localized: "This track is on this watch. Continue here?")
        return WatchProblemCard(
            systemImage: "applewatch", title: "iPhone Went Away", message: message,
            actions: [
                .init(title: "Continue on Watch", identifier: "watch.now.continue") { coordinator.acceptContinue() },
                .init(title: "Keep Waiting", isPrimary: false, identifier: "watch.now.keepWaiting") {
                    coordinator.dismissContinue()
                }
            ])
    }

    private var showsProblemCard: Bool {
        if shown == .iPhone { return remote.startFailure != nil }
        return player.currentTrack != nil && (player.audioRouteProblem != nil || player.playbackErrorMessage != nil)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            // Closing only dismisses — playback continues on whichever engine owns it (§7).
            Button { dismiss() } label: { Image(systemName: "chevron.down") }
                .accessibilityLabel(Text("Close"))
        }
        // A Problem Card owns the screen's actions (S3); the tool row would cover them.
        if !isLuminanceReduced && !showsProblemCard {
            ToolbarItemGroup(placement: .bottomBar) {
                WatchToolButton(systemImage: "airplayaudio", label: Text("Output")) { showingOutput = true }
                    .accessibilityIdentifier("watch.now.output")
                Spacer()
                NavigationLink { WatchUpNextView() } label: {
                    Image(systemName: "list.bullet")
                        .font(.caption.weight(.semibold))
                        .frame(width: WatchMetrics.toolButton, height: WatchMetrics.toolButton)
                        .background(Circle().fill(WatchPalette.control))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Up Next"))
                .accessibilityIdentifier("watch.now.upNext")
                Spacer()
                NavigationLink {
                    WatchNowPlayingMoreView(shown: shown ?? coordinator.target,
                                            pendingDownloadTrackID: $pendingDownloadTrackID)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.caption.weight(.semibold))
                        .frame(width: WatchMetrics.toolButton, height: WatchMetrics.toolButton)
                        .background(Circle().fill(WatchPalette.control))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("More"))
                .accessibilityIdentifier("watch.now.more")
            }
        }
    }

    // MARK: - Crown volume

    private var crownEnabled: Bool {
        guard !isLuminanceReduced else { return false }
        if shown == .iPhone { return remote.supportsVolume && remote.state?.currentItem != nil }
        return player.currentTrack != nil && player.audioRouteProblem == nil
    }

    private func syncCrown() {
        crownTarget = shown
        crownValue = shown == .iPhone ? remote.volume : player.volume
    }

    private func applyCrown(_ value: Double) {
        guard crownTarget == shown else { return }
        if shown == .iPhone {
            if abs(value - remote.volume) > 0.005 { remote.setVolume(value) }
        } else if abs(value - player.volume) > 0.005 {
            player.volume = value
        }
    }

    private func chooseRoute() {
        choosingRoute = true
        player.retryAudioRoute()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            choosingRoute = false
        }
    }

    private func localSubtitle(_ track: WatchTrackSnapshot) -> String {
        var parts: [String] = []
        if !track.artist.isEmpty { parts.append(track.artist) }
        if !track.albumTitle.isEmpty { parts.append(track.albumTitle) }
        return parts.joined(separator: " — ")
    }

    // MARK: - Debug (UI smoke only)

    private var debugPlaybackState: some View {
        VStack(spacing: 0) {
            Text(verbatim: "phase \(player.playbackPhase.rawValue)")
                .accessibilityIdentifier("watch.now.debugSession")
            Text(verbatim: "session \(player.sessionStatus)")
                .accessibilityIdentifier("watch.now.debugSessionStatus")
            Text(verbatim: "item \(player.itemReadiness.rawValue)")
                .accessibilityIdentifier("watch.now.debugItemState")
            Text(verbatim: "rate \(String(format: "%.2f", player.outputRate))")
                .accessibilityIdentifier("watch.now.debugRate")
            Text(verbatim: "duration \(String(format: "%.2f", player.duration))")
                .accessibilityIdentifier("watch.now.debugDuration")
            Text(verbatim: "generation \(player.playbackGenerationForDiagnostics)")
                .accessibilityIdentifier("watch.now.debugGeneration")
            if let code = player.lastPlaybackErrorCode {
                Text(verbatim: "error \(code)").accessibilityIdentifier("watch.now.debugError")
            }
        }
        .font(.system(size: 7, design: .monospaced))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .contain)
    }
}

/// The Output button (§5 N1): watchOS has no route-picker view, so this hosts the system
/// `NowPlayingView`, whose AirPlay button switches the output for whichever device is playing.
struct WatchOutputSheet: View {
    @ObservedObject private var player = WatchPlayer.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 4) {
                if let name = player.outputName {
                    Text("Now: \(name)").font(.caption2).foregroundStyle(.secondary)
                }
                NowPlayingView()
            }
            .navigationTitle(Text("Output"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .accessibilityIdentifier("watch.now.outputSheet")
    }
}

extension UIImage {
    /// Average colour of the image, for the Now Playing tint. Cheap: renders into a 1×1 bitmap.
    var watchAverageColor: Color? {
        guard let cg = cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Color(red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255)
    }
}
