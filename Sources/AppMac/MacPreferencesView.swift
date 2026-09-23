// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tonearm (Platterhead DJ) — Copyright (C) 2026 John Arley Burns.
// See ../../LICENSE.

import SwiftUI
import TonearmCore

/// The `Settings { }` scene (⌘,) — a real multi-pane Mac Preferences window
/// (native-mac-app-plan.md §3: "its four existing sections... become four
/// preference panes unchanged"), not `SettingsView`'s single iOS scroll.
/// Each tab hosts the same `SettingsView` reusing its real card content via
/// `MacPreferencesPane` — no duplicated settings logic, just which section
/// of the one real implementation a given pane shows.
struct MacPreferencesView: View {
    var body: some View {
        TabView {
            SettingsView(macPane: .playback)
                .tabItem { Label("Playback", systemImage: "play.circle") }
            SettingsView(macPane: .library)
                .tabItem { Label("Library", systemImage: "music.note.list") }
            SettingsView(macPane: .account)
                .tabItem { Label("Account", systemImage: "person.circle") }
            SettingsView(macPane: .advanced)
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
        }
        .frame(minWidth: 480, minHeight: 420)
    }
}
