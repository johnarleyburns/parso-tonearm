// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tonearm (Platterhead DJ) — Copyright (C) 2026 John Arley Burns.
// Licensed under the GNU General Public License v3.0 or later, with an
// additional permission under GPLv3 §7 allowing distribution through
// Apple's App Store. Full text, including that permission: ../../LICENSE.
// Source: https://github.com/johnarleyburns/parso-tonearm

import SwiftUI
import TonearmCore

/// The native Mac app's own entry point (docs/plans/native-mac-app-plan.md
/// §1) — a real `NSWindow`-backed SwiftUI app, not UIKit-on-Mac. Shares
/// every business-logic layer (`TonearmCore`/`TonearmDiscovery`,
/// `ParsoAudioStreaming`/`ParsoAudioPlayback`) and every SwiftUI view file
/// that's already platform-agnostic with the iOS `Tonearm` target directly —
/// only the app-shell chrome here is Mac-specific.
@main
struct TonearmMacApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var player = AudioPlayer.shared

    init() {
        SupportDevelopmentStore.shared.start()
        AudioPlayer.shared.attachPlatformBridge(MacPlaybackBridge())
        AudioPlayer.shared.persistor.cloudBackend = CloudPlaybackBackend()
        DiscoveryRuntimeController.shared.registerBackgroundTask()
    }

    var body: some Scene {
        WindowGroup {
            MacRootView()
                .environmentObject(appState)
                .environmentObject(player)
                .task {
                    await appState.bootstrap()
                    await DiscoveryRuntimeController.shared.startAfterBootstrap()
                }
        }
        .commands {
            TonearmMacCommands(appState: appState, player: player)
        }

        MenuBarExtra {
            MacNowPlayingMenuView()
                .environmentObject(appState)
                .environmentObject(player)
        } label: {
            Image(systemName: player.isPlaying ? "waveform" : "music.note")
        }

        Settings {
            MacPreferencesView()
                .environmentObject(appState)
                .environmentObject(player)
        }
    }
}
