import SwiftUI
import TonearmCore

/// The manual two-deck DJ console: a full-screen cover (no tab bar, landscape-locked — see
/// `TonearmAppDelegate.application(_:supportedInterfaceOrientationsFor:)`), presented when
/// `AppTab.dj` is selected (RootView.swift intercepts that selection rather than ever rendering
/// this as inline tab content).
///
/// LOAD, play/pause, channel volume, PFL, split-cue routing and REC → FLAC → Mixes are all real
/// (Workstreams G/H/I). The platter, tempo knob, EQ, isolator, monitoring row and meters stay
/// purely cosmetic for now, wired up later one at a time, per the mockup at
/// ~/Downloads/djmockup.html.
struct DJConsoleView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer
    @StateObject private var model = DJConsoleModel()
    @State private var recordingTitle = ""

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                Color(red: 0x09 / 255, green: 0x0b / 255, blue: 0x12 / 255)
                    .ignoresSafeArea()

                HStack(spacing: 10) {
                    DeckView(side: .left)
                        .frame(maxWidth: .infinity)
                    MixerView()
                        .frame(width: 180)
                    DeckView(side: .right)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 14)
                .padding(.top, 36)
                .padding(.bottom, 10)
                .accessibilityIdentifier("dj.console")

                Button {
                    appState.showDJConsole = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white, .white.opacity(0.25))
                        .padding()
                }
                .accessibilityIdentifier("dj.close")
                .accessibilityLabel("Close")
            }
        }
        .environmentObject(model)
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
            recordingTitle = pending?.suggestedTitle ?? ""
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
}
