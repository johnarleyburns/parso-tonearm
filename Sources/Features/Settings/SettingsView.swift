import ParsoAudioStreaming
import SwiftUI
import TonearmCore
#if canImport(UIKit)
import UIKit
#endif

/// Real report: "clicking Settings -> Music Libraries does nothing" — tapping
/// worked and set its own `@State` bool, but the sheet never presented.
/// Root cause (confirmed via the UI regression suite's captured accessibility
/// snapshot: the tap registered, the screen never changed): SwiftUI's
/// well-known reliability problem with many `.sheet(isPresented:)` modifiers
/// boolean-driven and chained on the same view — only some of them reliably
/// present, and which ones is not deterministic from the modifier order alone.
/// A single `.sheet(item:)` bound to one optional value doesn't have this
/// failure mode, since there is only ever one sheet identity to track.
enum SettingsSheet: Identifiable {
    case eq, tools, jamendoKey, cacheManagement, soundIndex
    var id: Self { self }
}

/// A real macOS Settings pane (⌘,) — the same four groupings as
/// `SettingsView.body`, each shown in its own tab of the Mac `Settings`
/// scene. `nil` on iPhone, where `SettingsView` renders every section in one
/// scroll.
enum MacPreferencesPane {
    case playback, library, account, advanced
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer
    var macPane: MacPreferencesPane?
    @State var cacheUsed: Int64 = 0
    @State var cacheLimit: Int64 = SparseCacheStore.defaultLimit
    @State var cachedCount: Int = 0
    @State var customArtworkBytes: Int64 = 0
    @State var activeSheet: SettingsSheet?
    @State var showClearConfirm = false
    @State var showClearCustomConfirm = false
    @State var showCustomCacheLimit = false
    @State var customCacheLimitMB = ""
    @State var customCacheLimitMessage: String?
    @State var icloudSync = SyncGating.isEnabled
    @State var showWatchSettings = false
    @AppStorage("appearanceMode") var appearanceMode = AppearanceMode.system.rawValue
    let presets: [(String, Int64)] = [
        ("200 MB", 200 * 1024 * 1024),
        ("500 MB", 500 * 1024 * 1024),
        ("2 GB", 2 * 1024 * 1024 * 1024),
        ("10 GB", 10 * 1024 * 1024 * 1024)
    ]

    private func shows(_ pane: MacPreferencesPane) -> Bool {
        macPane == nil || macPane == pane
    }

    var body: some View {
        NavigationStack {
            settingsLayout {
                #if os(iOS)
                Section { watchCard }
                #endif
                if shows(.playback) {
                    settingsSection("Playback", identifier: "settings.section.playback") {
                        behaviorCard
                        keepPlayingCard
                        #if os(iOS)
                        SiriSettingsCard()
                        #endif
                    }
                }
                if shows(.library) {
                    settingsSection("Library & Storage", identifier: "settings.section.library") {
                        if appState.starterMerge != nil { starterMergeCard }
                        musicLibrariesCard
                        soundIndexCard
                        cacheSummaryCard
                        syncCard
                    }
                }
                if shows(.account) {
                    settingsSection("Account & About", identifier: "settings.section.account") {
                        appearanceCard
                        privacyCard
                        SupportDevelopmentCard()
                        aboutCard
                    }
                }
                if shows(.advanced) {
                    Section {
                        advancedSection
                    }
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .foregroundStyle(Palette.ink)
            .scrollContentBackground(.hidden)
            .background(Palette.libraryBackground.ignoresSafeArea())
            .navigationTitle("Settings")
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("settings.done")
                }
            }
            #endif
        }
        .task { await refresh() }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .eq: EQView()
            case .tools: ToolsView()
            case .jamendoKey: JamendoCredentialView()
            case .cacheManagement: cacheManagementSheet
            case .soundIndex: SoundIndexSheet()
            }
        }
        .confirmationDialog("Clear \(TimeFmt.megabytes(cacheUsed)) of cached audio?",
                            isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Clear Cache", role: .destructive) {
                Task {
                    await AudioCache.shared.clearAll()
                    await ArtworkService.shared.clearAll()
                    try? await appState.store.clearAllCacheEntries()
                    await refresh()
                }
            }
        }
        .sensoryFeedback(.warning, trigger: showClearConfirm)
        .alert("Delete all custom artwork?", isPresented: $showClearCustomConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive) {
                Task {
                    var allIDs: [String] = []
                    if let ids = try? await appState.store.allCustomArtworkIds() { allIDs += ids }
                    if let ids = try? await appState.store.allAlbumCustomArtworkIds() { allIDs += ids }
                    if let ids = try? await appState.store.allSourceCustomArtworkIds() { allIDs += ids }
                    for aid in Set(allIDs) { await ArtworkStore.shared.delete(id: aid) }
                    try? await appState.store.clearAllCustomArtwork()
                    try? await appState.store.clearAllAlbumCustomArtwork()
                    try? await appState.store.clearAllSourceCustomArtwork()
                    ArtworkInvalidation.shared.invalidate()
                    await refresh()
                }
            }
        } message: {
            Text("Custom artwork you've uploaded — for tracks, albums, and libraries — will be permanently lost. This cannot be undone.")
        }
        .sensoryFeedback(.warning, trigger: showClearCustomConfirm)
    }

    @ViewBuilder
    private func settingsLayout<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(macOS)
        Form { content() }
        #else
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content() }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 48)
        }
        #endif
    }

    /// A flat, always-visible section (matching `../parso-voxglass`'s Settings
    /// layout) — a plain header above its content, no expand/collapse. Settings
    /// used to hide each group behind a tap; the owner found that an
    /// unnecessary extra step, so every row here is reachable without first
    /// expanding anything.
    @ViewBuilder
    private func settingsSection<Content: View>(_ title: LocalizedStringKey,
        identifier: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        if macPane == nil {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: sectionIcon(identifier)).foregroundStyle(Palette.accent)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(Typography.headline)
                        Text(sectionDetail(identifier)).font(Typography.caption)
                            .foregroundStyle(Palette.inkTertiary)
                    }
                    Spacer()
                }
                .padding(15)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(identifier)
                Divider().overlay(Palette.hairline).padding(.horizontal, 15)
                VStack(alignment: .leading, spacing: 14) { content() }
                    .padding(15)
            }
            .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 18))
        } else {
            Section(title, content: content)
        }
    }

    private func sectionIcon(_ id: String) -> String {
        switch id {
        case "settings.section.playback": "play.circle"
        case "settings.section.library": "externaldrive"
        default: "person.crop.circle"
        }
    }

    private func sectionDetail(_ id: String) -> LocalizedStringKey {
        switch id {
        case "settings.section.playback": "Listening, crossfade and Siri"
        case "settings.section.library": "Sources, indexing and storage"
        default: "Appearance, privacy and support"
        }
    }

}

struct PrivacyView: View {
    @Environment(\.dismiss) private var dismiss
    /// Settings pushes this (it already owns a `NavigationStack`) rather than presenting it as a
    /// sheet — same reasoning as `SourcesView.ownsNavigationStack`.
    var ownsNavigationStack = true

    var body: some View {
        Group {
            if ownsNavigationStack {
                NavigationStack { content }
            } else {
                content
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Platterhead collects nothing.")
                    .font(Typography.headline)
                privacyPoint("No accounts", "There is no sign-in and no server that belongs to Platterhead.")
                privacyPoint("Optional iCloud sync", "Free for everyone, off by default. When you turn it on, your Music, playlists, favorites, play history, custom artwork, and settings sync through your own iCloud account — not a Platterhead server. Only metadata, playlists, artwork, and settings sync; streamed cache audio is never uploaded, and local files stay on-device (they show as \"not on this device\" elsewhere until re-imported).")
                privacyPoint("No ads, no analytics", "No tracking of any kind. OAuth tokens are used only for services you explicitly connect.")
                privacyPoint("Network contact", "Jamendo for the built-in Creative Commons mood-starter library and its own genre libraries, archive.org for libraries you added by URL (public items, lists, and collections require only the URL; private lists require your archive.org username/password stored locally in Keychain), Apple's iTunes Search for missing cover art, and remote-library providers you add yourself: \(RemoteConnectorCatalog.proDisplayList).")
                privacyPoint("Your files stay yours", "Local music is referenced in place by secure bookmark and never uploaded.")
                privacyPoint("The cache is temporary", "Streamed audio is kept in an LRU cache so recently played music works offline. It is evicted automatically and can be cleared anytime.")
            }
            .foregroundStyle(Palette.ink)
            .padding(20)
        }
        .background(Palette.libraryBackground.ignoresSafeArea())
        .navigationTitle("Privacy")
        .compactNavigationTitle()
        .toolbar {
            if ownsNavigationStack {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.tint(Palette.accent)
                }
            }
        }
    }

    private func privacyPoint(_ title: LocalizedStringKey, _ body: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Typography.body).foregroundStyle(Palette.accent)
            Text(body).font(Typography.callout).foregroundStyle(Palette.inkSecondary)
        }
    }
}

/// Third-party model/library notices (Settings → Terms). Stem separation in
/// particular gets its own, non-buried explanation — see
/// `parso-audio-engine`'s README "On-device neural: CLAP search, and stem
/// separation" and `current_status.md` "Phase 7" for the full citation trail
/// behind these determinations.
struct ThirdPartyNoticesView: View {
    @Environment(\.dismiss) private var dismiss
    /// Settings pushes this (it already owns a `NavigationStack`) rather than presenting it as a
    /// sheet — same reasoning as `SourcesView.ownsNavigationStack`.
    var ownsNavigationStack = true

    var body: some View {
        Group {
            if ownsNavigationStack {
                NavigationStack { content }
            } else {
                content
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Third-party notices")
                    .font(Typography.headline)
                privacyPoint("License — GNU GPL v3.0 or later",
                    "Platterhead is free software: the complete source code is public at github.com/johnarleyburns/parso-tonearm, under the GNU General Public License v3.0 or later. Because the GPL's own terms conflict with the App Store's distribution terms, an additional permission under GPLv3 §7 specifically allows distributing Platterhead through the App Store, provided the source of the exact version distributed stays publicly available under this License — which it does, at the address above. Full text, including that permission: the LICENSE file in the repository.")
                privacyPoint("Semantic / vibe search",
                    "Vibe search uses LAION CLAP (music_audioset_epoch_15_esc_90.14, HTSAT-base), licensed Apache-2.0.")
                privacyPoint("Stem separation — Demucs (current default)",
                    "Splitting a track into vocals/drums/bass/other uses Demucs/htdemucs (Meta). Spleeter (Deezer, MIT code and weights) ships alongside it as a fallback backend. Demucs's pretrained weights are not established as commercially clean — Meta's own maintainers have stated on record that the released weights are provided for scientific purposes only — so shipping Demucs as the default here reflects this app's own licensing determination, made independently of parso-audio-engine's own stance (that engine still recommends Spleeter as its default for anyone who hasn't made that determination themselves). See docs/GPL-BACKENDS.md in this app's source for the full reasoning and how to switch back.")
                privacyPoint("MP3 export — LAME",
                    "The optional \"Also export MP3\" option on a finished recording uses LAME 3.100 (libmp3lame), licensed LGPL-2.1-or-later. LAME's source is vendored in this app's own source tree (Sources/CLAMEBridge) — parso-audio-engine itself never links or depends on LAME; it only declares the protocol this app's LAME wrapper implements. Recordings themselves are always saved as M4A/AAC; MP3 is produced only as an additional copy at export time. See docs/GPL-BACKENDS.md and docs/BYO-CODEC.md (parso-audio-engine) for how this works.")
                privacyPoint("Vendored audio/DSP libraries",
                    "Platterhead's audio engine vendors permissively-licensed open-source libraries for decode/encode and DSP (libFLAC, libebur128, libsamplerate, libogg/libopus, and others) — BSD, MIT, and public-domain terms. See parso-audio-engine's ATTRIBUTION.md for the complete per-file list.")
                privacyPoint("GRDB.swift", "SQLite access, MIT licensed.")
                privacyPoint("Jamendo — Creative Commons music",
                    "The built-in Mood Starter library and every Jamendo genre library you add stream Creative Commons-licensed tracks from Jamendo (jamendo.com). Each track keeps its own real license (shown on its library's detail screen) exactly as Jamendo publishes it — Platterhead adds no restrictions of its own and changes no track's license.")
            }
            .foregroundStyle(Palette.ink)
            .padding(20)
        }
        .background(Palette.libraryBackground.ignoresSafeArea())
        .navigationTitle("Terms & Notices")
        .compactNavigationTitle()
        .toolbar {
            if ownsNavigationStack {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.tint(Palette.accent)
                }
            }
        }
    }

    private func privacyPoint(_ title: LocalizedStringKey, _ body: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Typography.body).foregroundStyle(Palette.accent)
            Text(body).font(Typography.callout).foregroundStyle(Palette.inkSecondary)
        }
    }
}

/// `.accessibilityIdentifier(id ?? "")` would set an empty (matchable-by-
/// substring, collision-prone) identifier for every unlabeled call site —
/// this only applies one when `id` is actually given, for shared helpers
/// like `settingToggle` used from many rows only some of which are
/// UI-regression-tested today.
struct OptionalAccessibilityIdentifier: ViewModifier {
    let id: String?
    func body(content: Content) -> some View {
        if let id {
            content.accessibilityIdentifier(id)
        } else {
            content
        }
    }
}

/// docs/plans/macos-app-cloud-sync-plan.md §4 status surface (CLAUDE.md "no
/// silent/magic background work") — real counts from `CloudSyncEngine`'s
/// most recent pull pass. A separate view (rather than a computed property
/// on `SettingsView`) so `@ObservedObject` can actually subscribe to
/// `CloudSyncEngine`'s `@Published lastSyncActivity` — a computed property
/// re-reads a plain value once per parent render, which would leave this
/// stuck at whatever it read when Settings first appeared instead of
/// updating live as sync passes complete while the screen is open.
@available(iOS 17.0, *)
struct DiscoverySyncActivityRow: View {
    @ObservedObject private var engine = CloudSyncEngine.shared

    var body: some View {
        let activity = engine.lastSyncActivity
        let total = activity.accepted + activity.rejectedKeepLocal + activity.rejectedRequeued
        return VStack(alignment: .leading, spacing: 4) {
            Text("Sound Index Sync").font(Typography.caption)
            if activity.pendingTrackImport > 0 {
                Text("\(activity.pendingTrackImport) indexing results from your other devices are waiting for those tracks to be added here.")
                    .font(Typography.caption).foregroundStyle(Palette.inkTertiary)
                if let oldest = activity.pendingOldestDate {
                    Text("Oldest waiting result: \(oldest.formatted(date: .abbreviated, time: .shortened))")
                        .font(Typography.caption).foregroundStyle(Palette.inkTertiary)
                }
                HStack {
                    Button("Retry matching") { Task { await engine.retryPending() } }
                    Button("Discard waiting results", role: .destructive) {
                        Task {
                            try? await LibraryStore.shared.discardPendingSyncRecords()
                            await engine.refreshPendingActivity()
                        }
                    }
                }
                .font(Typography.caption)
            } else if total == 0 {
                Text("No indexing results received from another device yet.")
                    .font(Typography.caption).foregroundStyle(Palette.inkTertiary)
            } else {
                Text("\(activity.accepted) received · \(activity.rejectedKeepLocal) already indexed here"
                    + (activity.rejectedRequeued > 0
                        ? " · \(activity.rejectedRequeued) incompatible, re-indexing here" : ""))
                    .font(Typography.caption).foregroundStyle(Palette.inkTertiary)
            }
            if activity.prunedPendingCount > 0 {
                Text("Automatically removed \(activity.prunedPendingCount) waiting result(s) older than 90 days.")
                    .font(Typography.caption).foregroundStyle(Palette.inkTertiary)
            }
        }
        .padding(.top, 6)
        .accessibilityIdentifier("settings.icloudSync.discoveryActivity")
    }
}


/// Owns the Sound Index model for the lifetime of the sheet. Constructing
/// `IndexStatusModel()` inline in the sheet builder would create a fresh
/// model (and coordinator) on every re-evaluation, dropping the last good
/// snapshot and orphaning the in-flight read.
private struct SoundIndexSheet: View {
    @StateObject private var model = IndexStatusModel()
    var body: some View { IndexStatusView(model: model) }
}
