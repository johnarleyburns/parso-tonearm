import SwiftUI
import TonearmCore

/// The manual two-deck DJ console: an immersive full-screen cover with no tab bar and, while
/// actually in landscape, no close button at all — there's nowhere to float a permanent chrome
/// button without it sitting on top of the mockup's layout. Closing instead happens from the
/// portrait fallback below.
///
/// Orientation is never locked (a real report: the earlier hard landscape lock meant portrait
/// could never be *reached* at all, so a "rotate to landscape" message could never show).
/// `isLandscape`, from this view's own measured size, decides which of the two bodies renders —
/// rotating the device between them works exactly the way it would in a game or video app.
///
/// `model` is injected from `AppPresentations.swift` (`appState.djConsoleModel`), not owned here
/// as a `@StateObject` — a real report: closing and reopening the DJ tab reset every loaded
/// track, knob and setting, because a `@StateObject` inside a `.fullScreenCover`'s own content
/// view is recreated every time the cover is dismissed and re-presented. Only the engine's own
/// `start()`/`stop()` (its `AVAudioEngine`, not any loaded/control state — see
/// `DJConsoleModel.stop()`) follow this view's appear/disappear.
///
/// LOAD, play/pause, channel volume, PFL, split-cue routing and REC → FLAC → Mixes are all real
/// (Workstreams G/H/I). The platter, tempo knob, EQ, isolator, monitoring row and meters stay
/// purely cosmetic for now, wired up later one at a time, per the mockup at
/// ~/Downloads/djmockup.html.
struct DJConsoleView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var model: DJConsoleModel
    @State private var recordingTitle = ""

    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            ZStack {
                Color(red: 0x09 / 255, green: 0x0b / 255, blue: 0x12 / 255)
                    .ignoresSafeArea()
                if isLandscape {
                    landscapeConsole(in: geo.size)
                } else {
                    rotatePrompt
                }
            }
            .statusBarHidden(isLandscape)
        }
        .onAppear {
            // A second, independent AVAudioEngine — pause ordinary playback rather than risk
            // both engines fighting over the audio session at once.
            player.pausePlayback()
            model.start()
        }
        .onDisappear {
            model.stop()
        }
        .onChange(of: model.pendingRecording) { _, pending in
            // Never pre-filled — the owner picks the name. An empty submission still falls back
            // to `pending.suggestedTitle` inside `savePendingRecording`, so a mix is never
            // silently saved with a blank title.
            if pending != nil { recordingTitle = "" }
        }
        .alert("Save Mix", isPresented: Binding(
            get: { model.pendingRecording != nil },
            set: { shown in if !shown { model.discardPendingRecording() } }
        )) {
            TextField("Mix name", text: $recordingTitle)
            Button("Save") {
                model.savePendingRecording(title: recordingTitle, into: appState.mixRecordingRepository)
            }
            Button("Discard", role: .destructive) {
                model.discardPendingRecording()
            }
        } message: {
            Text(model.pendingRecording.map { "Recorded \(MixesView.duration($0.durationSec))." } ?? "")
        }
        .alert("Recording Issue", isPresented: Binding(
            get: { model.recordingError != nil },
            set: { shown in if !shown { model.recordingError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.recordingError ?? "")
        }
    }

    /// A single scale factor derived from the available size, applied to every fixed-size piece
    /// of the console (platter, knobs, spacing) so the whole layout fits within the screen on a
    /// compact landscape height (e.g. iPhone SE, ~375pt) as readily as a large one (iPad, Pro Max)
    /// — a real report: the platter and mixer went off-screen because nothing scaled at all.
    /// `760×360` is this layout's own design size (two ~290pt deck columns either side of a
    /// 180pt mixer, platter-driven height); never shrinks below 0.55 or grows past 1.3.
    private func scale(for size: CGSize) -> CGFloat {
        max(0.55, min(1.3, min(size.width / 760, size.height / 360)))
    }

    private func landscapeConsole(in size: CGSize) -> some View {
        let s = scale(for: size)
        let spacing: CGFloat = 10 * s
        let horizontalPadding: CGFloat = 12 * s
        let verticalPadding: CGFloat = 8 * s
        let mixerWidth = max(130, min(220, 180 * s))
        let deckWidth = max(150, (size.width - horizontalPadding * 2 - spacing * 2 - mixerWidth) / 2)
        return HStack(spacing: spacing) {
            DeckView(side: .left, scale: s)
                .frame(width: deckWidth)
            MixerView(scale: s)
                .frame(width: mixerWidth)
            DeckView(side: .right, scale: s)
                .frame(width: deckWidth)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .accessibilityIdentifier("dj.console")
    }

    private var rotatePrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "rotate.right")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.6))
            Text("Rotate to landscape for DJ mode")
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Button("Close") {
                appState.showDJConsole = false
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .accessibilityIdentifier("dj.rotatePrompt.close")
        }
        .padding(32)
        .accessibilityIdentifier("dj.rotatePrompt")
    }
}
