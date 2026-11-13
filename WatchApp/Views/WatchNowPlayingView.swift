import SwiftUI
import UIKit
import WatchKit
import TonearmWatchCore

/// AVPlayer.volume is only a multiplier. Let watchOS control the actual output volume and
/// respect the user's crown orientation; never force the system volume to maximum.
struct WatchSystemVolumeControl: WKInterfaceObjectRepresentable {
    let enabled: Bool

    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
        WKInterfaceVolumeControl(origin: .local)
    }

    func updateWKInterfaceObject(_ control: WKInterfaceVolumeControl, context: Context) {
        if enabled { control.focus() } else { control.resignFocus() }
    }

    static func dismantleWKInterfaceObject(_ control: WKInterfaceVolumeControl, coordinator: ()) {
        control.resignFocus()
    }
}

/// Watch redesign §5 N1/N2/S1–S5/T3/A1/A3 — one fixed, non-scrolling Now Playing face for this
/// watch's local playback. Artwork colours tint the background; the target chip names where the
/// audio comes out; big round transport; the Digital Crown controls native watch output volume; a
/// bottom toolbar holds Output · Up Next · More. Failures replace the transport *in place* with a
/// Problem Card.
struct WatchNowPlayingView: View {
    @ObservedObject private var player = WatchPlayer.shared
    @ObservedObject private var coordinator = WatchPlaybackCoordinator.shared
    @ObservedObject private var model = WatchAppAssembly.shared.model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingOutput = false
    @State private var choosingRoute = false
    /// Track we asked the phone to download, so the More row shows a spinner until it lands.
    @State private var pendingDownloadTrackID: String?

    var body: some View {
        ZStack {
            background
            VStack(spacing: 4) {
                chip
                localContent
                WatchSystemVolumeControl(enabled: crownEnabled)
                    .frame(height: 24)
                    .accessibilityIdentifier("watch.now.volume")
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
        .onChange(of: model.tracks) { _, _ in player.refreshLocalArtwork() }
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

    private var hasArtwork: Bool { player.artwork != nil }

    private var tintKey: String { player.currentTrack?.id ?? "none" }

    private var tintColors: (Color, Color) {
        let base = player.artworkTint ?? WatchPalette.accent
        return (base.opacity(0.95), base.opacity(0.35))
    }

    // MARK: - Target chip

    private var chip: some View {
        let title = player.outputName.map { String(localized: "Apple Watch · \($0)") }
            ?? String(localized: "Apple Watch")
        return WatchTargetChip(systemImage: "applewatch", title: title, tone: .onArtwork)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(chipSpokenLocal))
            .accessibilityIdentifier("watch.now.target")
            .accessibilityValue("Apple Watch")
    }

    private var chipSpokenLocal: String {
        if let output = player.outputName {
            return String(localized: "Playing on Apple Watch through \(output)")
        }
        return String(localized: "Playing on Apple Watch")
    }

    // MARK: - Content

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
                WatchProgressHairline(
                    elapsed: player.elapsed, duration: player.duration,
                    showsTimes: dynamicTypeSize < .accessibility1,
                    onSeek: WatchScrubPolicy.isInteractive(
                        duration: player.duration, isLocal: true, isBusy: isLocalBusy,
                        isLuminanceReduced: isLuminanceReduced) ? { player.seek(to: $0) } : nil)
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
        HStack(spacing: 6) {
            if let artwork = player.artwork {
                Image(uiImage: artwork).resizable().scaledToFill()
                    .frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 5))
                    .accessibilityLabel("Cover artwork")
            }
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

    private var showsProblemCard: Bool {
        player.currentTrack != nil && (player.audioRouteProblem != nil || player.playbackErrorMessage != nil)
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
        return player.currentTrack != nil && player.audioRouteProblem == nil
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
