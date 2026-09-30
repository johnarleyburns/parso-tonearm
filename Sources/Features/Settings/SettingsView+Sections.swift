import ParsoAudioStreaming
import SwiftUI
import TonearmCore
#if canImport(UIKit)
import UIKit
#endif

extension SettingsView {
    var appearanceCard: some View {
        Picker("Theme", selection: $appearanceMode) {
            Text("System").tag(AppearanceMode.system.rawValue)
            Text("Light").tag(AppearanceMode.light.rawValue)
            Text("Dark").tag(AppearanceMode.dark.rawValue)
        }
        .pickerStyle(.menu)
        .sensoryFeedback(.selection, trigger: appearanceMode)
    }

    /// Low-frequency actions moved into their own Form (docs/plans/
    /// ui-simplification-plan.md item 1) — everything here is still
    /// reachable, just behind one extra tap instead of always visible.
    var advancedSection: some View {
        Button { activeSheet = .advanced } label: {
            HStack {
                ViewThatFits(in: .horizontal) {
                    Text("Advanced").font(Typography.callout)
                    Text("More settings").font(Typography.callout)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
            }
            .padding(15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.advanced")
        .glassSurface(cornerRadius: 18)
    }

    var advancedForm: some View {
        NavigationStack {
            Form {
                Section("Preparation") {
                    toolsCard
                    jamendoCard
                }
                Section("Storage") {
                    clearCard
                    customArtworkCard
                }
            }
            .foregroundStyle(Palette.ink)
            .scrollContentBackground(.hidden)
            .background(Palette.libraryBackground.ignoresSafeArea())
            .navigationTitle("Advanced")
            .compactNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { activeSheet = nil }.tint(Palette.accent)
                }
            }
        }
    }

    var appVersionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
    }

    var cacheManagementSheet: some View {
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
                    Button("Done") { activeSheet = nil }.tint(Palette.accent)
                }
            }
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

    /// Collapsed summary row (docs/plans/ui-simplification-plan.md item 2)
    /// — the full preset/custom-limit controls (`cacheCard`) move into a
    /// sheet opened from here; nothing about setting the limit changes.
    var cacheSummaryCard: some View {
        Button { activeSheet = .cacheManagement } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Streaming Cache").font(Typography.callout)
                    Text("\(TimeFmt.megabytes(cacheUsed)) of \(TimeFmt.megabytes(cacheLimit)) used")
                        .font(Typography.caption).foregroundStyle(Palette.inkTertiary)
                        .contentTransition(.numericText())
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.inkTertiary)
            }
            .padding(15)
            .glassSurface(cornerRadius: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.cache")
    }

    var cacheCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Streaming Cache").font(Typography.callout)
                Spacer()
                Text("\(TimeFmt.megabytes(cacheUsed)) of \(TimeFmt.megabytes(cacheLimit))")
                    .font(Typography.caption).foregroundStyle(Palette.inkTertiary)
                    .contentTransition(.numericText())
            }
            .padding(.bottom, 11)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.ink.opacity(0.1))
                    Capsule().fill(LinearGradient(colors: [Palette.accent, Palette.accent],
                                                  startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * fillFraction)
                }
            }
            .frame(height: 10)

            HStack {
                Text("\(cachedCount) tracks cached").font(Typography.caption)
                    .contentTransition(.numericText())
                Spacer()
                Text("oldest evicted first").font(Typography.caption)
            }
            .foregroundStyle(Palette.inkTertiary)
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
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
                    .padding(.top, 8)
            }
        }
        .padding(15)
        .glassSurface(cornerRadius: 18)
    }

    func presetButton(_ label: String, _ bytes: Int64) -> some View {
        let selected = bytes == cacheLimit
        return Button {
            cacheLimit = bytes
            customCacheLimitMessage = nil
            Task { await AudioCache.setLimit(bytes); await refresh() }
        } label: {
            Text(label)
            .font(Typography.caption)
            .foregroundStyle(selected ? Palette.accentOnFill : Palette.inkSecondary)
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .background(selected ? Palette.accent : Palette.ink.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 11))
        }
    }

    var customPresetButton: some View {
        let presetValues = Set(presets.map(\.1))
        let selected = !presetValues.contains(cacheLimit)
        return Button {
            customCacheLimitMB = String(max(100, cacheLimit / 1024 / 1024))
            showCustomCacheLimit = true
        } label: {
            Text(selected ? TimeFmt.megabytes(cacheLimit) : "Custom")
                .font(Typography.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(selected ? Palette.accentOnFill : Palette.inkSecondary)
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(selected ? Palette.accent : Palette.ink.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 11))
        }
    }

    /// "Where does my music come from?" — moved here from its own root tab
    /// (docs/plans/UNIFIED_TONEARM_MY_MUSIC_TRANSITION_LAB_HANDOFF.md §6):
    /// source configuration is a low-frequency task, not a permanent
    /// bottom-tab destination.
}
