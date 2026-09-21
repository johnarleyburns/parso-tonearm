// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tonearm (Platterhead DJ) — Copyright (C) 2026 John Arley Burns.
// See ../../LICENSE.

import SwiftUI
import TonearmCore

/// The `Settings { }` scene (⌘,) — a real Mac Preferences window rather than
/// a sidebar destination (native-mac-app-plan.md §3). Reuses the existing
/// `SettingsView` content, which is already organized under the same three
/// section headers the plan calls for as separate panes (Playback; Library &
/// Storage; Account & About/Advanced) — hosting them together in one
/// scrollable pane for this pass rather than splitting `SettingsView`'s
/// private per-section subviews out into standalone panes.
struct MacPreferencesView: View {
    var body: some View {
        SettingsView()
            .frame(minWidth: 480, minHeight: 420)
    }
}
