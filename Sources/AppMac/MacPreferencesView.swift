// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tonearm (Platterhead DJ) — Copyright (C) 2026 John Arley Burns.
// See ../../LICENSE.

import SwiftUI
import TonearmCore

/// The `Settings { }` scene (⌘,) — a multi-pane Mac Settings window. Each
/// pane is the iPhone `SettingsView` restricted to one of its sections, so
/// the Mac has every setting the iPhone has and no duplicated settings logic.
struct MacPreferencesView: View {
    var body: some View {
        TabView {
            SettingsView(macPane: .playback)
                .tabItem { Label("Playback", systemImage: "play.circle") }
            SettingsView(macPane: .library)
                .tabItem { Label("Library", systemImage: "music.note.list") }
            SettingsView(macPane: .account)
                .tabItem { Label("General", systemImage: "gearshape") }
            SettingsView(macPane: .advanced)
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
        }
        .frame(width: 620, height: 640)
    }
}
