import SwiftUI
import TonearmCore

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    @State private var cacheUsed: Int64 = 0
    @State private var cacheLimit: Int64 = CacheStore.defaultLimit
    @State private var cachedCount: Int = 0
    @State private var customArtworkBytes: Int64 = 0
    @State private var showPrivacy = false
    @State private var showClearConfirm = false
    @State private var showClearCustomConfirm = false
    @State private var showPaywall = false
    @State private var showEQ = false
    @State private var showTools = false
    @State private var showCustomCacheLimit = false
    @State private var customCacheLimitMB = ""
    @State private var customCacheLimitMessage: String?
    @State private var icloudSync = SyncGating.isEnabled

    private let presets: [(String, Int64)] = [
        ("200 MB", 200 * 1024 * 1024),
        ("500 MB", 500 * 1024 * 1024),
        ("2 GB", 2 * 1024 * 1024 * 1024),
        ("10 GB", 10 * 1024 * 1024 * 1024)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Settings").font(.system(size: 31, weight: .heavy)).kerning(-0.5)
                    .padding(.top, 8)

                cacheCard
                behaviorCard
                toolsCard
                syncCard
                clearCard
                customArtworkCard
                privacyCard
                aboutCard
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 160)
        }
        .foregroundStyle(Palette.ink)
        .task { await refresh() }
        .sheet(isPresented: $showPrivacy) { PrivacyView() }
        .sheet(isPresented: $showPaywall) { ProPaywallView() }
        .sheet(isPresented: $showEQ) { EQView() }
        .sheet(isPresented: $showTools) { ProToolsView() }
        .confirmationDialog("Clear \(TimeFmt.megabytes(cacheUsed)) of cached audio?",
                            isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Clear Cache", role: .destructive) {
                Task {
                    await CacheStore.shared.clearAll()
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
                    if let ids = try? await appState.store.allCustomArtworkIds() {
                        for aid in ids { await ArtworkStore.shared.delete(id: aid) }
                    }
                    try? await appState.store.clearAllCustomArtwork()
                    await refresh()
                }
            }
        } message: {
            Text("Custom artwork you've uploaded will be permanently lost. This cannot be undone.")
        }
        .alert("Custom Cache Limit", isPresented: $showCustomCacheLimit) {
            TextField("MB", text: $customCacheLimitMB)
                .keyboardType(.numberPad)
            Button("Cancel", role: .cancel) {}
            Button("Set") { applyCustomCacheLimit() }
        } message: {
            Text("Enter a limit in MB. Minimum 100 MB; maximum 80% of free disk.")
        }
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
            Task { await CacheStore.shared.setLimit(bytes); await refresh() }
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

    private var behaviorCard: some View {
        VStack(spacing: 0) {
            settingToggle(appState.streamOnCellular ? "Stream on cellular" : "Wi-Fi only",
                          "Off = Wi-Fi only; cached tracks always play",
                          $appState.streamOnCellular)
            Divider().overlay(Palette.hairline)
            settingToggle("Prefer FLAC over MP3", "Stream lossless when available (larger files)", $appState.preferFLAC)
            Divider().overlay(Palette.hairline)
            prefetchControl
            Divider().overlay(Palette.hairline)
            eqRow
            Divider().overlay(Palette.hairline)
            settingToggle("Look up missing artwork",
                          "Ask Apple's iTunes Search for covers your files lack",
                          $appState.artworkLookup)
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
            Stepper(value: $appState.prefetchDepth,
                    in: PrefetchDepthPolicy.minimum...PrefetchDepthPolicy.maximum) {
                Text("\(appState.prefetchDepth)").font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
            }
            .labelsHidden()
            .fixedSize()
        }
        .padding(.vertical, 6)
    }

    private var eqRow: some View {
        Button { showEQ = true } label: {
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
        }
        .buttonStyle(.plain)
    }

    /// iCloud sync (Pro, C1/C5). Off by default; a locked tap presents the paywall.
    /// The engine only runs when Pro + toggle + an iCloud account are present.
    private var syncCard: some View {
        let isPro = ProFeature.isEnabled(.icloudSync)
        return VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text("iCloud Sync").font(.system(size: 13.5))
                        if !isPro {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.brass)
                        }
                    }
                    Text("Library, playlists & settings across your devices, using your own iCloud")
                        .font(.system(size: 11)).foregroundStyle(Palette.ink3)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { icloudSync },
                    set: { newValue in
                        if !isPro {
                            showPaywall = true
                            return
                        }
                        icloudSync = newValue
                        SyncGating.isEnabled = newValue
                        if #available(iOS 17.0, *) {
                            Task { await CloudSyncEngine.shared.reconcile() }
                        }
                    }
                ))
                .labelsHidden().tint(Palette.brassDeep)
            }
            .padding(.vertical, 8)
        }
        .padding(15)
        .glassSurface(cornerRadius: 18)
    }

    private var toolsCard: some View {
        let isPro = ProEntitlement.isActive
        return Button {
            switch ProToolsAccessPolicy.decisionForToolsSurface(isPro: isPro) {
            case .allow:
                showTools = true
            case .requiresPro:
                showPaywall = true
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text("Tools").font(.system(size: 13.5))
                        if !isPro {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.brass)
                        }
                    }
                    Text("Smart playlists, tags, duplicates and Pro audio policy")
                        .font(.system(size: 11)).foregroundStyle(Palette.ink3)
                }
                Spacer()
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.ink3)
            }
            .padding(15)
            .glassSurface(cornerRadius: 18)
        }
        .buttonStyle(.plain)
    }

    private func settingToggle(_ title: String, _ sub: String, _ binding: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5))
                Text(sub).font(.system(size: 11)).foregroundStyle(Palette.ink3)
            }
            Spacer()
            Toggle("", isOn: binding).labelsHidden().tint(Palette.brassDeep)
        }
        .padding(.vertical, 8)
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
        }
        .buttonStyle(.plain)
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

            Text("Images you attach to tracks. Never auto-deleted.")
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
        Button { showPrivacy = true } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Privacy").font(.system(size: 13.5))
                    Text("No accounts of ours; optional Apple iCloud sync · no ads · no analytics · talks only to archive.org, Apple artwork search, and services you explicitly connect")
                        .font(.system(size: 11)).foregroundStyle(Palette.ink3)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Palette.ink3)
            }
            .padding(15)
            .glassSurface(cornerRadius: 18)
        }
        .buttonStyle(.plain)
    }

    private var aboutCard: some View {
        VStack(spacing: 0) {
            Button { showPaywall = true } label: {
                aboutRow("Tonearm Pro", "Remote libraries, sync, iPad + Mac")
            }
            .buttonStyle(.plain)
            Divider().overlay(Palette.hairline)
            aboutRow("Licenses", "GPLv3 + third-party")
            Divider().overlay(Palette.hairline)
            aboutRow("About", "Tonearm 0.1 — you bring the records")
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
        cacheUsed = await CacheStore.shared.totalCachedBytes()
        cacheLimit = await CacheStore.shared.currentLimit()
        cachedCount = await CacheStore.shared.cachedTrackCount()
        customArtworkBytes = customArtworkSize()
    }

    private func applyCustomCacheLimit() {
        let mb = Int64(customCacheLimitMB.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let requested = mb * 1024 * 1024
        let result = CacheLimitPolicy.validate(requestedBytes: requested, freeDiskBytes: freeDiskBytes())
        cacheLimit = result.allowedBytes
        customCacheLimitMessage = result.reason
        Task { await CacheStore.shared.setLimit(result.allowedBytes); await refresh() }
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
                    Text("Tonearm collects nothing.")
                        .font(.system(size: 20, weight: .bold))
                    privacyPoint("No accounts", "There is no sign-in and no server that belongs to Tonearm.")
                    privacyPoint("Optional iCloud sync", "A Pro feature, off by default. When you turn it on, your library, playlists, favorites, play history, custom artwork, and settings sync through your own iCloud account — not a Tonearm server. Only metadata, playlists, artwork, and settings sync; streamed cache audio is never uploaded, and local files stay on-device (they show as \"not on this device\" elsewhere until re-imported).")
                    privacyPoint("No ads, no analytics", "No tracking of any kind. OAuth tokens are used only for services you explicitly connect.")
                    privacyPoint("Network contact", "archive.org for sources you added by URL, Apple's iTunes Search for missing cover art, and remote-library providers you add yourself: \(RemoteConnectorCatalog.proDisplayList). Lyrics lookup and scrobbling stay off until you enable them; then Tonearm talks only to LRCLIB, Last.fm, or ListenBrainz for those features.")
                    privacyPoint("Your files stay yours", "Local music is referenced in place by secure bookmark and never uploaded.")
                    privacyPoint("The cache is temporary", "Streamed audio is kept in an LRU cache so recently played music works offline. It is evicted automatically and can be cleared anytime.")
                }
                .foregroundStyle(Palette.ink)
                .padding(20)
            }
            .background(Palette.libraryBackground.ignoresSafeArea())
            .navigationTitle("Privacy")
            .navigationBarTitleDisplayMode(.inline)
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
