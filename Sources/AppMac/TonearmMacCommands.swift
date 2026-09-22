// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tonearm (Platterhead DJ) — Copyright (C) 2026 John Arley Burns.
// See ../../LICENSE.

import SwiftUI
import TonearmCore

/// The real system menu bar (native-mac-app-plan.md §3, mockups
/// §m-file/§m-edit/§m-playback): `.commands { }` builds genuine `NSMenu`
/// entries, not a Catalyst UIKit-flavored substitute.
struct TonearmMacCommands: Commands {
    @ObservedObject var appState: AppState
    @ObservedObject var player: AudioPlayer

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Music Folder…") { appState.showAddSource = true }
                .keyboardShortcut("o", modifiers: .command)
            Button("Add Server…") { appState.showAddRemoteLibrary = true }
            Divider()
            Button("New Playlist…") { appState.showCreatePlaylist = true }
                .keyboardShortcut("n", modifiers: .command)
        }

        CommandGroup(after: .toolbar) {
            Button("Show Now Playing") { appState.showNowPlaying = true }
                .keyboardShortcut("d", modifiers: [.command, .shift])
        }

        // Mockup §m-edit shows "Find in Library ⌘F" / "Find Next ⌘G". Only
        // Find is real here — the app has no concept of stepping through
        // multiple search matches (LibraryView's search filters the whole
        // list, it doesn't select/advance a "current match"), and inventing
        // one just to fill the menu slot would be exactly the kind of fake
        // affordance CLAUDE.md's "no silent/magic behavior" rule warns
        // against. ⌘F jumps to My Music, where the real search field lives.
        CommandGroup(replacing: .textEditing) {
            Button("Find in Library") { appState.tab = .myMusic }
                .keyboardShortcut("f", modifiers: .command)
        }

        CommandMenu("Playback") {
            Button(player.isPlaying ? "Pause" : "Play") { player.togglePlayPause() }
                .keyboardShortcut(.space, modifiers: [])
            Button("Next Track") { player.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Previous Track") { player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Divider()
            Button("Shuffle") { player.toggleShuffle() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Repeat") { player.cycleRepeatMode() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Increase Volume") { player.adjustVolume(by: 0.1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Decrease Volume") { player.adjustVolume(by: -0.1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
        }
    }
}
