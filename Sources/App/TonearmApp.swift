// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tonearm (Platterhead DJ) — Copyright (C) 2026 John Arley Burns.
// Licensed under the GNU General Public License v3.0 or later, with an
// additional permission under GPLv3 §7 allowing distribution through
// Apple's App Store. Full text, including that permission: ../../LICENSE.
// Source: https://github.com/johnarleyburns/parso-tonearm

import SwiftUI
import TonearmCore
import TonearmDJ

@main
struct TonearmApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var player = AudioPlayer.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var didCompleteBootstrap = false

    init() {
        let launchArguments = ProcessInfo.processInfo.arguments
        let isUITesting = launchArguments.contains("UI_TESTING")

        if launchArguments.contains("-resetLibrary") {
            Self.resetLibraryForRegression()
        }
        if isUITesting {
            UserDefaults.standard.set(true, forKey: "didOnboard")
        }
        // Everything is free — no Pro entitlement, no paywall (see
        // docs/plans/unified-my-music-transition-lab-status.md §11). The one
        // remaining purchase — "Contribute to Development" — unlocks nothing;
        // it only sets the permanent Supporter badge flag.
        SupportDevelopmentStore.shared.start()
        AudioPlayer.shared.attachPlatformBridge(SystemPlaybackBridge())
        AudioPlayer.shared.persistor.cloudBackend = CloudPlaybackBackend()

        // Discovery/CLAP indexing (IMPLEMENT_CLAP_PLAN.md §7): the BGTask
        // handler must be registered before the app finishes launching, from a
        // controller reachable in a headless launch.
        DiscoveryRuntimeController.shared.registerBackgroundTask()
    }

    /// The `-resetLibrary` harness hook (dj-regression-suite §8.1): wipe the
    /// app's library state so a regression run always starts from the same
    /// empty slate — the main store, the DJ database (tracks, crates, the
    /// mixes journal), recorded mixes, genre-crate downloads and the DJ caches.
    /// Runs before any store is opened, so it is safe to delete the DB files.
    private static func resetLibraryForRegression() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for suffix in ["", "-shm", "-wal"] {
            try? fm.removeItem(at: appSupport.appendingPathComponent("library\(suffix).sqlite"))
        }
        guard let djDatabase = try? DJDatabase.defaultDatabaseURL() else { return }
        for suffix in ["", "-shm", "-wal"] {
            try? fm.removeItem(at: URL(fileURLWithPath: djDatabase.path + suffix))
        }
        try? fm.removeItem(at: DJDatabase.mixesDirectory)
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? fm.removeItem(at: documents.appendingPathComponent("GenreCrates", isDirectory: true))
        try? fm.removeItem(at: DJDatabase.cachesDirectory)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(player)
                .preferredColorScheme(.dark)
                .task {
                    await appState.bootstrap()
                    didCompleteBootstrap = true
                    await DiscoveryRuntimeController.shared.startAfterBootstrap()
                }
                .onOpenURL { url in
                    Task { await appState.handleIncomingURL(url) }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                DiscoveryRuntimeController.shared.scenePhaseChanged(toBackground: false)
                guard didCompleteBootstrap else { return }
                Task {
                    let added = await FolderWatchService.shared.rescanWatchedFolders(store: appState.store)
                    if added > 0 { await appState.reload() }
                }
            case .background, .inactive:
                if phase == .background {
                    DiscoveryRuntimeController.shared.scenePhaseChanged(toBackground: true)
                }
                AudioPlayer.shared.persistNow()
            default:
                break
            }
        }
    }
}
