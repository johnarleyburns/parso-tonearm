import ParsoAudioStreaming
import SwiftUI
import TonearmCore

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
    case privacy, thirdPartyNotices, musicLibraries, eq, tools, jamendoKey, cacheManagement, soundIndex
    var id: Self { self }
}

/// A real macOS Preferences pane (native-mac-app-plan.md §3: "its four
/// existing sections... become four preference panes unchanged") — matches
/// `SettingsView.body`'s own four groupings exactly. `nil` on iOS/iPadOS,
/// where `SettingsView` still renders every section in one scroll.
enum MacPreferencesPane {
    case playback, library, account, advanced
}

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    var macPane: MacPreferencesPane?

    @State private var cacheUsed: Int64 = 0
    @State private var cacheLimit: Int64 = SparseCacheStore.defaultLimit
    @State private var cachedCount: Int = 0
    @State private var customArtworkBytes: Int64 = 0
    @State private var activeSheet: SettingsSheet?
    @State private var showClearConfirm = false
    @State private var showClearCustomConfirm = false
    @State private var showCustomCacheLimit = false
    @State private var customCacheLimitMB = ""
    @State private var customCacheLimitMessage: String?
    @State private var icloudSync = SyncGating.isEnabled
    @State private var showWatchSettings = false
    @State private var advancedExpanded: Bool

    init(macPane: MacPreferencesPane? = nil) {
        self.macPane = macPane
        // A dedicated Advanced pane IS the disclosure's content — start
        // expanded rather than making the whole pane one collapsed row.
        _advancedExpanded = State(initialValue: macPane == .advanced)
    }

    private let presets: [(String, Int64)] = [
        ("200 MB", 200 * 1024 * 1024),
        ("500 MB", 500 * 1024 * 1024),
        ("2 GB", 2 * 1024 * 1024 * 1024),
        ("10 GB", 10 * 1024 * 1024 * 1024)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if macPane == nil {
                    Text("Settings").font(.system(size: 31, weight: .heavy)).kerning(-0.5)
                        .padding(.top, 8)
                }

                if macPane == nil || macPane == .playback {
                    sectionHeader("Playback")
                    behaviorCard
                    keepPlayingCard
                    #if os(iOS)
                    if macPane == nil {
                        SiriSettingsCard()
                    }
                    #endif
                }

                if macPane == nil || macPane == .library {
                    sectionHeader("Library & Storage")
                    musicLibrariesCard
                    soundIndexCard
                    cacheSummaryCard
                    watchCard
                    syncCard
                }

                if macPane == nil || macPane == .account {
                    sectionHeader("Account & About")
                    privacyCard
                    SupportDevelopmentCard()
                    aboutCard
                }

                if macPane == nil || macPane == .advanced {
                    advancedSection
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, macPane == nil ? 160 : 18)
        }
        .foregroundStyle(Palette.ink)
        .task { await refresh() }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .privacy: PrivacyView()
            case .thirdPartyNotices: ThirdPartyNoticesView()
            case .musicLibraries: SourcesView()
            case .eq: EQView()
            case .tools: ToolsView()
            case .jamendoKey: JamendoCredentialView()
            case .cacheManagement: cacheManagementSheet
            case .soundIndex: IndexStatusView(model: IndexStatusModel())
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
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Palette.ink3)
            .kerning(0.5)
            .padding(.top, 4)
    }

    /// Low-frequency actions moved out of the main scroll (docs/plans/
    /// ui-simplification-plan.md item 1) — everything here is still
    /// reachable, just behind one extra tap instead of always visible.
    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { advancedExpanded.toggle() } label: {
                HStack {
                    Text("Advanced").font(.system(size: 13.5, weight: .semibold))
                    Spacer()
                    Image(systemName: advancedExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink3)
                }
                .padding(15)
                // Real report: tapping this (and other Spacer-based row
                // labels below) did nothing at all on a real device. A
                // Button's plain-style label with a Spacer only makes its
                // VISIBLY DRAWN content (the Text/Image glyphs) tappable by
                // default — the Spacer's own flexible empty space, which is
                // most of a normal-width row, is not part of the hit area
                // unless explicitly claimed. `.contentShape(Rectangle())`
                // claims the whole padded frame instead.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.advanced")

            if advancedExpanded {
                VStack(spacing: 14) {
                    toolsCard
                    jamendoCard
                    clearCard
                    customArtworkCard
                }
                .padding(.horizontal, 15)
                .padding(.bottom, 15)
            }
        }
        .glassSurface(cornerRadius: 18)
    }

    private var appVersionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
    }

    private var cacheManagementSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    cacheCard
                }
                .padding(18)
            }
            .background(Palette.libraryBackground.ignoresSafeArea())
            .foregroundStyle(Palette.ink)
            .navigationTitle("Streaming Cache")
            .compactNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { activeSheet = nil }.tint(Palette.brass)
                }
            }
        }
        .alert("Custom Cache Limit", isPresented: $showCustomCacheLimit) {
            TextField("MB", text: $customCacheLimitMB)
                #if !os(macOS)
                .keyboardType(.numberPad)
                #endif
            Button("Cancel", role: .cancel) {}
            Button("Set") { applyCustomCacheLimit() }
        } message: {
            Text("Enter a limit in MB. Minimum 100 MB; maximum 80% of free disk.")
        }
    }

    /// Collapsed summary row (docs/plans/ui-simplification-plan.md item 2)
    /// — the full preset/custom-limit controls (`cacheCard`) move into a
    /// sheet opened from here; nothing about setting the limit changes.
    private var cacheSummaryCard: some View {
        Button { activeSheet = .cacheManagement } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Streaming Cache").font(.system(size: 13.5))
                    Text("\(TimeFmt.megabytes(cacheUsed)) of \(TimeFmt.megabytes(cacheLimit)) used")
                        .font(.system(size: 11)).foregroundStyle(Palette.ink3)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink3)
            }
            .padding(15)
            .glassSurface(cornerRadius: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.cache")
    }

    private var cacheCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Streaming Cache").font(.system(size: 13, weight: .bold))
                Spacer()
                Text("\(TimeFmt.megabytes(cacheUsed)) of \(TimeFmt.megabytes(cacheLimit))")
                    .font(.system(size: 11)).foregroundStyle(Palette.ink3)
            }
            .padding(.bottom, 11)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule().fill(LinearGradient(colors: [Color(hex: 0xCF8F34), Palette.brass],
                                                  startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * fillFraction)
                }
            }
            .frame(height: 10)

            HStack {
                Text("\(cachedCount) tracks cached").font(.system(size: 10.5))
                Spacer()
                Text("oldest evicted first").font(.system(size: 10.5))
            }
            .foregroundStyle(Palette.ink3)
            .padding(.top, 8)

            HStack(spacing: 6) {
                ForEach(presets, id: \.0) { label, bytes in
                    presetButton(label, bytes)
                }
                customPresetButton
            }
            .padding(.top, 12)

            if let customCacheLimitMessage {
                Text(customCacheLimitMessage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.ink3)
                    .padding(.top, 8)
            }
        }
        .padding(15)
        .glassSurface(cornerRadius: 18)
    }

    private func presetButton(_ label: String, _ bytes: Int64) -> some View {
        let selected = bytes == cacheLimit
        return Button {
            cacheLimit = bytes
            customCacheLimitMessage = nil
            Task { await AudioCache.setLimit(bytes); await refresh() }
        } label: {
            Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(selected ? .white : Palette.ink2)
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .background(selected ? Palette.brassDeep : Color.white.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 11))
        }
    }

    private var customPresetButton: some View {
        let presetValues = Set(presets.map(\.1))
        let selected = !presetValues.contains(cacheLimit)
        return Button {
            customCacheLimitMB = String(max(100, cacheLimit / 1024 / 1024))
            showCustomCacheLimit = true
        } label: {
            Text(selected ? TimeFmt.megabytes(cacheLimit) : "Custom")
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(selected ? .white : Palette.ink2)
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(selected ? Palette.brassDeep : Color.white.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 11))
        }
    }

    /// "Where does my music come from?" — moved here from its own root tab
    /// (docs/plans/UNIFIED_TONEARM_MY_MUSIC_TRANSITION_LAB_HANDOFF.md §6):
    /// source configuration is a low-frequency task, not a permanent
    /// bottom-tab destination.
    private var musicLibrariesCard: some View {
        Button { activeSheet = .musicLibraries } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Music Libraries").font(.system(size: 13.5))
                    Text(
                        appState.sources.isEmpty
                            ? "Local folders, servers & cloud"
                            : "\(appState.sources.count) connected"
                    )
                    .font(.system(size: 11)).foregroundStyle(Palette.ink3)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink3)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.musicLibraries")
        .padding(15)
        .glassSurface(cornerRadius: 18)
    }

    /// Moved off the main Music tab (real report: it shouldn't show there
    /// at all) into its own row here — same reachable status/controls
    /// (IndexStatusView), just not competing for space on the tab everyone
    /// opens constantly.
    private var soundIndexCard: some View {
        Button { activeSheet = .soundIndex } label: {
            HStack {
                Text("Sound Index").font(.system(size: 13.5))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink3)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.soundIndex")
        .padding(15)
        .glassSurface(cornerRadius: 18)
    }

    private var behaviorCard: some View {
        VStack(spacing: 0) {
            settingToggle(appState.streamOnCellular ? "Stream on cellular" : "Wi-Fi only",
                          "Off = Wi-Fi only; cached tracks always play",
                          $appState.streamOnCellular, id: "settings.streamOnCellular")
            Divider().overlay(Palette.hairline)
            settingToggle("Prefer FLAC over MP3", "Stream lossless when available (larger files)",
                          $appState.preferFLAC, id: "settings.preferFLAC")
            Divider().overlay(Palette.hairline)
            prefetchControl
            Divider().overlay(Palette.hairline)
            eqRow
            Divider().overlay(Palette.hairline)
            settingToggle("Look up missing artwork",
                          "Ask Apple's iTunes Search for covers your files lack",
                          $appState.artworkLookup, id: "settings.artworkLookup")
        }
        .padding(15)
        .glassSurface(cornerRadius: 18)
        .onChange(of: appState.streamOnCellular) { _, _ in appState.applySettingsToPlayer() }
        .onChange(of: appState.preferFLAC) { _, _ in appState.applySettingsToPlayer() }
        .onChange(of: appState.prefetchDepth) { _, _ in appState.applySettingsToPlayer() }
        .onChange(of: appState.artworkLookup) { _, _ in appState.applySettingsToPlayer() }
    }

    private var prefetchControl: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Prefetch next tracks").font(.system(size: 13.5))
                Text("Cache ahead while playing")
                    .font(.system(size: 11)).foregroundStyle(Palette.ink3)
            }
            Spacer()
            // Real report: "the +/- does nothing, I don't see any number
            // shown" — a Stepper's label closure is accessibility-only on
            // iOS; it is never rendered inline next to the control, however
            // it's used here (this was true before this change too — not a
            // new regression). The value needs its own always-visible Text.
            Text("\(appState.prefetchDepth)").font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
            Stepper("", value: $appState.prefetchDepth,
                    in: PrefetchDepthPolicy.minimum...PrefetchDepthPolicy.maximum)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.vertical, 6)
    }

    private var eqRow: some View {
        Button { activeSheet = .eq } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("10-band EQ").font(.system(size: 13.5))
                    Text("Presets and custom curves")
                        .font(.system(size: 11)).foregroundStyle(Palette.ink3)
                }
                Spacer()
                Image(systemName: "slider.vertical.3")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.ink3)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.eq")
    }

    /// iCloud sync — free for all users. Off by default; the engine runs when
    /// the toggle is on and an iCloud account is available.
    private var syncCard: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("iCloud Sync").font(.system(size: 13.5))
                    Text("Music, playlists & settings across your devices, using your own iCloud")
                        .font(.system(size: 11)).foregroundStyle(Palette.ink3)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { icloudSync },
                    set: { newValue in
                        icloudSync = newValue
                        SyncGating.isEnabled = newValue
                        if #available(iOS 17.0, *) {
                            Task { await CloudSyncEngine.shared.reconcile() }
                        }
                    }
                ))
                .labelsHidden().tint(Palette.brassDeep)
                .accessibilityIdentifier("settings.icloudSync")
            }
            .padding(.vertical, 8)

            if icloudSync, #available(iOS 17.0, *) {
                Divider().overlay(Palette.hairline)
                discoverySyncActivityRow
            }
        }
        .padding(15)
        .glassSurface(cornerRadius: 18)
    }

    /// docs/plans/macos-app-cloud-sync-plan.md §4 status surface — real
    /// counts from `CloudSyncEngine`'s most recent pull pass (CLAUDE.md "no
    /// silent/magic background work": a user turning this on should be able
    /// to see what it's actually doing, not just a spinner). `nil` counts
    /// (nothing synced yet this launch) show a plain waiting line instead
    /// of a fabricated "0 of 0".
    @available(iOS 17.0, *)
    private var discoverySyncActivityRow: some View {
        DiscoverySyncActivityRow()
    }

    private var watchCard: some View {
        Button { showWatchSettings = true } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Watch").font(.system(size: 13.5))
                    Text("Download music for offline playback on your watch")
                        .font(.system(size: 11)).foregroundStyle(Palette.ink3)
                }
                Spacer()
                Image(systemName: "applewatch")
                    .font(.system(size: 16))
                    .foregroundStyle(Palette.ink3)
            }
            .padding(15)
            .glassSurface(cornerRadius: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.watch")
        .sheet(isPresented: $showWatchSettings) {
            WatchSettingsView()
        }
    }


    /// §18A.2: the app's own Jamendo key ships in the binary so genre libraries
    /// need no account (FR-LIB-9); a user may supply their own instead, which
    /// then takes precedence (plan 6.3).
    private var jamendoCard: some View {
        Button { activeSheet = .jamendoKey } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Jamendo key").font(.system(size: 13.5))
                    Text("Use your own application key for genre libraries")
                        .font(.system(size: 11)).foregroundStyle(Palette.ink3)
                }
                Spacer()
                Image(systemName: "key")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.ink3)
            }
            .padding(15)
            .glassSurface(cornerRadius: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.jamendo.key")
    }

    private var toolsCard: some View {
        Button { activeSheet = .tools } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tools").font(.system(size: 13.5))
                    Text("Smart playlists, tags, duplicates, parametric EQ and more")
                        .font(.system(size: 11)).foregroundStyle(Palette.ink3)
                }
                Spacer()
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.ink3)
            }
            .padding(15)
            .glassSurface(cornerRadius: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.tools")
    }

    private func settingToggle(
        _ title: String, _ sub: String, _ binding: Binding<Bool>, id: String? = nil
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5))
                Text(sub).font(.system(size: 11)).foregroundStyle(Palette.ink3)
            }
            Spacer()
            // The identifier belongs on the Toggle itself, not the row — an
            // identifier on the surrounding HStack merges into a single
            // accessibility element whose reported control type/value is the
            // row's own (a StaticText), not the switch's, so UI-test taps
            // land on the row but state reads/writes never see the switch.
            Toggle("", isOn: binding)
                .labelsHidden().tint(Palette.brassDeep)
                .modifier(OptionalAccessibilityIdentifier(id: id))
        }
        .padding(.vertical, 8)
    }

    /// The Settings-level detail for Keep Playing (CLAUDE.md "let them drill
    /// down for more info in settings") — the primary discoverable toggle is
    /// in Now Playing's queue header (`UpNextView.keepPlayingToggle`), not
    /// here; this just explains how picking works and exposes the batch size.
    private var keepPlayingCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingToggle("Keep Playing",
                          "When your queue is about to end, keep music playing with similar-sounding tracks",
                          $appState.keepPlayingEnabled, id: "settings.keepPlaying")
            Divider().overlay(Palette.hairline)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tracks added per extension").font(.system(size: 13.5))
                    Text("Picked by sound similarity to what you just played, "
                        + "when the sound index is ready — otherwise shuffled from the same library/playlist")
                        .font(.system(size: 11)).foregroundStyle(Palette.ink3)
                }
                Spacer()
                // Same fix as `prefetchControl` — a Stepper's label closure
                // never renders inline on iOS, so the value needs its own
                // visible Text.
                Text("\(appState.keepPlayingBatchSize)").font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                Stepper("", value: $appState.keepPlayingBatchSize, in: 5...30, step: 5)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.vertical, 6)
            .opacity(appState.keepPlayingEnabled ? 1 : 0.4)
            .disabled(!appState.keepPlayingEnabled)
        }
        .padding(15)
        .glassSurface(cornerRadius: 18)
        .onChange(of: appState.keepPlayingEnabled) { _, _ in appState.applySettingsToPlayer() }
        .onChange(of: appState.keepPlayingBatchSize) { _, _ in appState.applySettingsToPlayer() }
    }

    private var clearCard: some View {
        Button { showClearConfirm = true } label: {
            HStack {
                Text("Clear Cache").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Palette.danger)
                Spacer()
                Text(TimeFmt.megabytes(cacheUsed)).font(.system(size: 13)).foregroundStyle(Palette.ink3)
            }
            .padding(15)
            .glassSurface(cornerRadius: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.clearCache")
    }

    private var customArtworkCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Custom Artwork").font(.system(size: 13, weight: .bold))
                Spacer()
                Text(TimeFmt.megabytes(customArtworkBytes))
                    .font(.system(size: 11)).foregroundStyle(Palette.ink3)
            }
            .padding(.bottom, 4)

            Text("Images you attach to tracks, albums, and libraries. Never auto-deleted.")
                .font(.system(size: 11)).foregroundStyle(Palette.ink3)
                .padding(.bottom, 12)

            Button {
                showClearCustomConfirm = true
            } label: {
                Text("Clear Custom Artwork")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.danger)
                    .frame(maxWidth: .infinity)
            }
            .disabled(customArtworkBytes == 0)
            .opacity(customArtworkBytes == 0 ? 0.4 : 1)
        }
        .padding(15)
        .glassSurface(cornerRadius: 18)
    }

    private var privacyCard: some View {
        Button { activeSheet = .privacy } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Privacy").font(.system(size: 13.5))
                    Text("No accounts of ours; optional Apple iCloud sync · no ads · no analytics · talks only to archive.org (URL only for public; Keychain for private lists), Apple artwork search, and libraries you explicitly connect")
                        .font(.system(size: 11)).foregroundStyle(Palette.ink3)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Palette.ink3)
            }
            .padding(15)
            .glassSurface(cornerRadius: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.privacy")
    }

    private var aboutCard: some View {
        VStack(spacing: 0) {
            Button { activeSheet = .thirdPartyNotices } label: {
                HStack {
                    aboutRow("Terms", "GPLv3+ · third-party notices")
                    Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Palette.ink3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.thirdPartyNotices")
            Divider().overlay(Palette.hairline)
            Link(destination: URL(string: "https://github.com/johnarleyburns/parso-tonearm")!) {
                HStack {
                    aboutRow("Source", "View on GitHub")
                    Image(systemName: "arrow.up.right").font(.system(size: 12)).foregroundStyle(Palette.ink3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider().overlay(Palette.hairline)
            aboutRow("About", "Platterhead \(appVersionString) — you bring the records")
        }
        .padding(15)
        .glassSurface(cornerRadius: 18)
    }

    private func aboutRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 13.5))
            Spacer()
            Text(value).font(.system(size: 12)).foregroundStyle(Palette.ink3)
        }
        .padding(.vertical, 8)
    }

    private var fillFraction: Double {
        guard cacheLimit > 0 else { return 0 }
        return min(1, Double(cacheUsed) / Double(cacheLimit))
    }

    private func refresh() async {
        cacheUsed = await AudioCache.shared.totalCachedBytes()
        cacheLimit = await AudioCache.shared.currentLimit()
        cachedCount = await AudioCache.shared.completeEntryCount(kind: "audio")
        customArtworkBytes = customArtworkSize()
    }

    private func applyCustomCacheLimit() {
        let mb = Int64(customCacheLimitMB.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let requested = mb * 1024 * 1024
        let result = CacheLimitPolicy.validate(requestedBytes: requested, freeDiskBytes: freeDiskBytes())
        cacheLimit = result.allowedBytes
        customCacheLimitMessage = result.reason
        Task { await AudioCache.setLimit(result.allowedBytes); await refresh() }
    }

    private func freeDiskBytes() -> Int64 {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    private func customArtworkSize() -> Int64 {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: false))
            .flatMap { $0.appendingPathComponent("Tonearm/Artwork") }
        guard let dir, let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return contents.reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init) ?? 0
            return total + size
        }
    }
}

struct PrivacyView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Platterhead collects nothing.")
                        .font(.system(size: 20, weight: .bold))
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
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.tint(Palette.brass)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func privacyPoint(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.brass)
            Text(body).font(.system(size: 13)).foregroundStyle(Palette.ink2)
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
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Third-party notices")
                        .font(.system(size: 20, weight: .bold))
                    privacyPoint("License — GNU GPL v3.0 or later",
                        "Platterhead DJ is free software: the complete source code is public at github.com/johnarleyburns/parso-tonearm, under the GNU General Public License v3.0 or later. Because the GPL's own terms conflict with the App Store's distribution terms, an additional permission under GPLv3 §7 specifically allows distributing Platterhead DJ through the App Store, provided the source of the exact version distributed stays publicly available under this License — which it does, at the address above. Full text, including that permission: the LICENSE file in the repository.")
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
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.tint(Palette.brass)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func privacyPoint(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.brass)
            Text(body).font(.system(size: 13)).foregroundStyle(Palette.ink2)
        }
    }
}

/// `.accessibilityIdentifier(id ?? "")` would set an empty (matchable-by-
/// substring, collision-prone) identifier for every unlabeled call site —
/// this only applies one when `id` is actually given, for shared helpers
/// like `settingToggle` used from many rows only some of which are
/// UI-regression-tested today.
private struct OptionalAccessibilityIdentifier: ViewModifier {
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
private struct DiscoverySyncActivityRow: View {
    @ObservedObject private var engine = CloudSyncEngine.shared

    var body: some View {
        let activity = engine.lastSyncActivity
        let total = activity.accepted + activity.rejectedKeepLocal + activity.rejectedRequeued
        return VStack(alignment: .leading, spacing: 4) {
            Text("Sound Index Sync").font(.system(size: 12, weight: .semibold))
            if total == 0 {
                Text("No indexing results received from another device yet.")
                    .font(.system(size: 11)).foregroundStyle(Palette.ink3)
            } else {
                Text("\(activity.accepted) received · \(activity.rejectedKeepLocal) already indexed here"
                    + (activity.rejectedRequeued > 0
                        ? " · \(activity.rejectedRequeued) incompatible, re-indexing here" : ""))
                    .font(.system(size: 11)).foregroundStyle(Palette.ink3)
            }
        }
        .padding(.top, 6)
        .accessibilityIdentifier("settings.icloudSync.discoveryActivity")
    }
}
