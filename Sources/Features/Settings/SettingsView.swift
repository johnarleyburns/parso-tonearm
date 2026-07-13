import SwiftUI

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
                presetButton("Custom", -1)
            }
            .padding(.top, 12)
        }
        .padding(15)
        .glassSurface(cornerRadius: 18)
    }

    private func presetButton(_ label: String, _ bytes: Int64) -> some View {
        let selected = bytes == cacheLimit
        let locked = bytes > 0 && ProGating.isCachePresetLocked(bytes, isPro: ProEntitlement.isActive)
        return Button {
            guard bytes > 0 else { return }
            if locked {
                showPaywall = true
                return
            }
            cacheLimit = bytes
            Task { await CacheStore.shared.setLimit(bytes); await refresh() }
        } label: {
            HStack(spacing: 4) {
                Text(label)
                if locked {
                    Image(systemName: "lock.fill").font(.system(size: 8, weight: .bold))
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(selected ? .white : (locked ? Palette.brass : Palette.ink2))
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .background(selected ? Palette.brassDeep : Color.white.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 11))
        }
    }

    private var behaviorCard: some View {
        VStack(spacing: 0) {
            settingToggle("Stream on cellular", "Off = Wi-Fi only; cached tracks always play",
                          $appState.streamOnCellular)
            Divider().overlay(Palette.hairline)
            settingToggle("Prefer FLAC over MP3", "Stream lossless when available (larger files)", $appState.preferFLAC)
            Divider().overlay(Palette.hairline)
            prefetchControl
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

    /// Free tier caps prefetch at depth 1 (powers near-gapless + Opus-when-ready,
    /// D7); Pro unlocks deeper values. A locked deeper tap presents the paywall.
    private var prefetchControl: some View {
        let isPro = ProEntitlement.isActive
        let maxDepth = isPro ? 5 : ProGating.freeMaxPrefetchDepth
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text("Prefetch next tracks").font(.system(size: 13.5))
                    if !isPro {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.brass)
                    }
                }
                Text(isPro ? "Cache ahead while playing"
                           : "Free caches 1 ahead · Pro caches more")
                    .font(.system(size: 11)).foregroundStyle(Palette.ink3)
            }
            Spacer()
            Stepper(value: Binding(
                get: { appState.prefetchDepth },
                set: { newValue in
                    if !isPro && newValue > ProGating.freeMaxPrefetchDepth {
                        showPaywall = true
                        return
                    }
                    appState.prefetchDepth = newValue
                }
            ), in: 0...maxDepth) {
                Text("\(appState.prefetchDepth)").font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
            }
            .labelsHidden()
            .fixedSize()
        }
        .padding(.vertical, 6)
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
                    Text("No accounts of ours; optional Apple iCloud sync · no ads · no analytics · talks to archive.org for your sources and Apple for missing artwork")
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
            aboutRow("Licenses", "GPLv3 + third-party")
            Divider().overlay(Palette.hairline)
            aboutRow("About", "Platterhead 0.1 — you bring the records")
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
                    privacyPoint("Optional iCloud sync", "A Pro feature, off by default. When you turn it on, your library, playlists, favorites, play history, custom artwork, and settings sync through your own iCloud account — not a Platterhead server. Only metadata, playlists, artwork, and settings sync; streamed cache audio is never uploaded, and local files stay on-device (they show as \"not on this device\" elsewhere until re-imported).")
                    privacyPoint("No ads, no analytics", "No third-party SDKs. No tracking of any kind.")
                    privacyPoint("Network contact", "archive.org for sources you added by URL, and Apple's iTunes Search for missing cover art. No search is ever performed for you, and artwork lookup can be turned off.")
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
