import SwiftUI

/// The manual two-deck DJ console: a full-screen cover (no tab bar, landscape-locked — see
/// `TonearmAppDelegate.application(_:supportedInterfaceOrientationsFor:)`), presented when
/// `AppTab.dj` is selected (RootView.swift intercepts that selection rather than ever rendering
/// this as inline tab content). Placeholder body for this commit — the real two-deck layout
/// (KnobView/DeckView/MixerView) lands next.
struct DJConsoleView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0x09 / 255, green: 0x0b / 255, blue: 0x12 / 255)
                .ignoresSafeArea()

            Text("DJ Console")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
}
