// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tonearm (Platterhead DJ) — Copyright (C) 2026 John Arley Burns.
// See ../../LICENSE.

import SwiftUI
import TonearmCore

/// The real system menu bar: `.commands { }` builds genuine `NSMenu` entries
/// for everything the iPhone app does from its tabs, sheets and Now Playing.
struct TonearmMacCommands: Commands {
    @ObservedObject var appState: AppState
    @ObservedObject var player: AudioPlayer
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Playlist…") { show { appState.showCreatePlaylist = true } }
                .keyboardShortcut("n", modifiers: .command)
            Button("Build a Mix…") { show { appState.requestBuildAMix() } }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Divider()
            Button("Add Local Folder…") { show { appState.pendingImport = .folder } }
                .keyboardShortcut("o", modifiers: .command)
            Button("Add Audio Files…") { show { appState.pendingImport = .files } }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Add Remote Library…") { show { appState.showAddRemoteLibrary = true } }
            Button("Add Internet Archive or Jamendo…") { show { appState.showAddSource = true } }
        }

        // ⌘F focuses the toolbar search field (My Music), like Music.app.
        CommandGroup(replacing: .textEditing) {
            Button("Find in My Music") {
                show { appState.macSearchFocusRequest &+= 1 }
            }
            .keyboardShortcut("f", modifiers: .command)
        }

        CommandGroup(before: .sidebar) {
            Button("Listen") { show { appState.tab = .listen } }
                .keyboardShortcut("1", modifiers: .command)
            Button("My Music") { show { appState.tab = .myMusic } }
                .keyboardShortcut("2", modifiers: .command)
            Divider()
            Button(appState.showNowPlaying ? "Hide Now Playing" : "Show Now Playing") {
                show { appState.showNowPlaying.toggle() }
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            Divider()
        }

        CommandMenu("Controls") {
            Button(player.isPlaying ? "Pause" : "Play") { player.togglePlayPause() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(player.currentTrack == nil)
            Button("Next Track") { player.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(player.currentTrack == nil)
            Button("Previous Track") { player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(player.currentTrack == nil)
            Divider()
            Toggle("Shuffle", isOn: Binding(
                get: { player.shuffle },
                set: { if $0 != player.shuffle { player.toggleShuffle() } }))
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button(repeatTitle) { player.cycleRepeatMode() }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Toggle("Keep Playing", isOn: $appState.keepPlayingEnabled)
            Divider()
            Button("Increase Volume") { player.adjustVolume(by: 0.1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Decrease Volume") { player.adjustVolume(by: -0.1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Divider()
            Menu("Sleep Timer") {
                Button("15 minutes") { player.applySleepTimer(.minutes(15)) }
                Button("30 minutes") { player.applySleepTimer(.minutes(30)) }
                Button("45 minutes") { player.applySleepTimer(.minutes(45)) }
                Button("1 hour") { player.applySleepTimer(.minutes(60)) }
                Button("End of track") { player.applySleepTimer(.endOfTrack) }
                if player.sleepTimerEndsAt != nil || player.sleepAtEndOfTrack {
                    Divider()
                    Button("Cancel Timer") { player.applySleepTimer(.cancel) }
                }
            }
        }
    }

    private var repeatTitle: String {
        switch player.repeatMode {
        case .off: String(localized: "Repeat: Off")
        case .all: String(localized: "Repeat: All")
        case .one: String(localized: "Repeat: One")
        }
    }

    /// Menu commands can run while the main window is closed (the app keeps
    /// playing from the menu bar); bring it back so the result is visible.
    private func show(_ action: () -> Void) {
        openWindow(id: TonearmMacApp.mainWindowID)
        action()
    }
}
