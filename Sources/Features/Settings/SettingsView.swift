import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    @State private var cacheUsed: Int64 = 0
    @State private var cacheLimit: Int64 = CacheStore.defaultLimit
    @State private var cachedCount: Int = 0
    @State private var showPrivacy = false
    @State private var showClearConfirm = false

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
                clearCard
                privacyCard
                aboutCard
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 160)
        }
        .foregroundStyle(Palette.ink)
        .task { await refresh() }
        .sheet(isPresented: $showPrivacy) { PrivacyView() }
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
        return Button {
            guard bytes > 0 else { return }
            cacheLimit = bytes
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

    private var behaviorCard: some View {
        VStack(spacing: 0) {
            settingToggle("Stream on cellular", "Off = Wi-Fi only; cached tracks always play",
                          $appState.streamOnCellular)
            Divider().overlay(Palette.hairline)
            settingToggle("Prefer FLAC over MP3", "Stream lossless when available (larger files)", $appState.preferFLAC)
            Divider().overlay(Palette.hairline)
            Stepper(value: $appState.prefetchDepth, in: 0...5) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Prefetch next tracks").font(.system(size: 13.5))
                    Text("Cache ahead while playing").font(.system(size: 11)).foregroundStyle(Palette.ink3)
                }
            }
            .padding(.vertical, 6)
        }
        .padding(15)
        .glassSurface(cornerRadius: 18)
        .onChange(of: appState.streamOnCellular) { _, _ in appState.applySettingsToPlayer() }
        .onChange(of: appState.preferFLAC) { _, _ in appState.applySettingsToPlayer() }
        .onChange(of: appState.prefetchDepth) { _, _ in appState.applySettingsToPlayer() }
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

    private var privacyCard: some View {
        Button { showPrivacy = true } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Privacy").font(.system(size: 13.5))
                    Text("No accounts · no ads · no analytics · talks only to archive.org for your added sources")
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
                    privacyPoint("No ads, no analytics", "No third-party SDKs. No tracking of any kind.")
                    privacyPoint("Network contact", "Only archive.org, and only for sources you added by URL. No search is ever performed for you.")
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
