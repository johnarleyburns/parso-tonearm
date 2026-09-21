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

        CommandMenu("Playback") {
            Button(player.isPlaying ? "Pause" : "Play") { player.togglePlayPause() }
                .keyboardShortcut(.space, modifiers: [])
            Button("Next Track") { player.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Previous Track") { player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
        }
    }
}
