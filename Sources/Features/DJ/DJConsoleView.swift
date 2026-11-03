import SwiftUI
import TonearmCore

/// The manual two-deck DJ console: a full-screen cover (no tab bar, landscape-locked — see
/// `TonearmAppDelegate.application(_:supportedInterfaceOrientationsFor:)`), presented when
/// `AppTab.dj` is selected (RootView.swift intercepts that selection rather than ever rendering
/// this as inline tab content).
///
/// LOAD, play/pause, channel volume and PFL are real (Workstream G); Split L/Split R/Stereo and
/// REC land in later commits. The platter, tempo knob, EQ, isolator, monitoring row and meters
/// stay purely cosmetic for now, wired up later one at a time, per the mockup at
/// ~/Downloads/djmockup.html.
struct DJConsoleView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer
    @StateObject private var model = DJConsoleModel()

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
    }
}
