// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tonearm (Platterhead DJ) — Copyright (C) 2026 John Arley Burns.
// Licensed under the GNU General Public License v3.0 or later, with an
// additional permission under GPLv3 §7 allowing distribution through
// Apple's App Store. Full text, including that permission: ../../LICENSE.
// Source: https://github.com/johnarleyburns/parso-tonearm

import AppKit
import SwiftUI
import TonearmCore

/// The native Mac app's entry point — a real `NSWindow`-backed SwiftUI app,
/// not UIKit-on-Mac. It shares every business-logic layer and every
/// platform-agnostic SwiftUI view with the iPhone `Tonearm` target; only the
/// app-shell chrome in `Sources/AppMac` is Mac-specific
/// (docs/plans/native-mac-parity.md).
@main
struct TonearmMacApp: App {
    @NSApplicationDelegateAdaptor(TonearmMacAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var player = AudioPlayer.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var didCompleteBootstrap = false
    @AppStorage("appearanceMode") private var appearanceMode = AppearanceMode.system.rawValue

    static let mainWindowID = "main"

    init() {
        // Everything is free — the one purchase, "Contribute to Development",
        // unlocks nothing (same as iPhone).
        SupportDevelopmentStore.shared.start()
        AudioPlayer.shared.attachPlatformBridge(MacPlaybackBridge())
        AudioPlayer.shared.persistor.cloudBackend = CloudPlaybackBackend()
        DiscoveryRuntimeController.shared.registerBackgroundTask()
    }

    var body: some Scene {
        Window("Platterhead", id: Self.mainWindowID) {
            MacRootView()
                .environmentObject(appState)
                .environmentObject(player)
                .preferredColorScheme(colorScheme)
                .task {
                    await appState.bootstrap()
                    didCompleteBootstrap = true
                    await DiscoveryRuntimeController.shared.startAfterBootstrap()
                }
                .onOpenURL { url in
                    Task { await appState.handleIncomingURL(url) }
                }
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            TonearmMacCommands(appState: appState, player: player)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                guard didCompleteBootstrap else { return }
                Task {
                    let added = await FolderWatchService.shared.rescanWatchedFolders(store: appState.store)
                    if added > 0 { await appState.reload() }
                }
            case .background, .inactive:
                AudioPlayer.shared.persistNow()
            default:
                break
            }
        }

        MenuBarExtra {
            MacNowPlayingMenuView()
                .environmentObject(appState)
                .environmentObject(player)
                .preferredColorScheme(colorScheme)
        } label: {
            Image(systemName: player.isPlaying ? "waveform" : "music.note")
                .accessibilityLabel("Platterhead")
        }
        .menuBarExtraStyle(.window)

        Settings {
            MacPreferencesView()
                .environmentObject(appState)
                .environmentObject(player)
                .environmentObject(appState.transitionPrepService)
                .preferredColorScheme(colorScheme)
        }
    }

    private var colorScheme: ColorScheme? {
        AppearanceMode(rawValue: appearanceMode)?.colorScheme
    }
}

/// Keeps the last-played queue and position when the app quits, and keeps
/// playing music in the menu bar after the window closes.
final class TonearmMacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AudioPlayer.shared.persistNow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
