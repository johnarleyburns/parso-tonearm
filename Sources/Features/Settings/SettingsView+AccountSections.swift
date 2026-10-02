import ParsoAudioStreaming
import SwiftUI
import TonearmCore
#if canImport(UIKit)
import UIKit
#endif

extension SettingsView {
    var keepPlayingCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingToggle("Keep Playing",
                          "When your queue is about to end, keep music playing with similar-sounding tracks",
                          $appState.keepPlayingEnabled, id: "settings.keepPlaying")
            Divider().overlay(Palette.hairline)
            settingToggle("Select matching tracks",
                          "Prefer Camelot-compatible keys and BPM within 8% of the last track",
                          $appState.keepPlayingMatchingTracksOnly,
                          id: "settings.keepPlayingMatchingTracks")
            Divider().overlay(Palette.hairline)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tracks added per extension").font(Typography.callout)
                    Text("Picked by sound similarity to what you just played, when the sound index is ready — otherwise shuffled from the same library/playlist")
                        .font(Typography.caption).foregroundStyle(Palette.inkTertiary)
                }
                Spacer()
                // Same fix as `prefetchControl` — a Stepper's label closure
                // never renders inline on iOS, so the value needs its own
                // visible Text.
                Text("\(appState.keepPlayingBatchSize)").font(Typography.callout)
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
        .onChange(of: appState.keepPlayingMatchingTracksOnly) { _, _ in appState.applySettingsToPlayer() }
    }

    var clearCard: some View {
        Button { showClearConfirm = true } label: {
            HStack {
                Text("Clear Cache").font(Typography.callout).foregroundStyle(Palette.danger)
                Spacer()
                Text(TimeFmt.megabytes(cacheUsed)).font(Typography.callout).foregroundStyle(Palette.inkTertiary)
            }
            .padding(15)
            .glassSurface(cornerRadius: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.clearCache")
    }

    var customArtworkCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Custom Artwork").font(Typography.callout)
                Spacer()
                Text(TimeFmt.megabytes(customArtworkBytes))
                    .font(Typography.caption).foregroundStyle(Palette.inkTertiary)
            }
            .padding(.bottom, 4)

            Text("Images you attach to tracks, albums, and libraries. Never auto-deleted.")
                .font(Typography.caption).foregroundStyle(Palette.inkTertiary)
                .padding(.bottom, 12)

            Button {
                showClearCustomConfirm = true
            } label: {
                Text("Clear Custom Artwork")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.danger)
                    .frame(maxWidth: .infinity)
            }
            .disabled(customArtworkBytes == 0)
            .opacity(customArtworkBytes == 0 ? 0.4 : 1)
        }
        .padding(15)
        .glassSurface(cornerRadius: 18)
    }

    var privacyCard: some View {
        Button { activeSheet = .privacy } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Privacy").font(Typography.callout)
                    Text("No accounts of ours; optional Apple iCloud sync · no ads · no analytics · talks only to archive.org (URL only for public; Keychain for private lists), Apple artwork search, and libraries you explicitly connect")
                        .font(Typography.caption).foregroundStyle(Palette.inkTertiary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(Typography.caption).foregroundStyle(Palette.inkTertiary)
            }
            .padding(15)
            .glassSurface(cornerRadius: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.privacy")
    }

    var aboutCard: some View {
        VStack(spacing: 0) {
            Button { activeSheet = .thirdPartyNotices } label: {
                HStack {
                    aboutRow("Terms", "GPLv3+ · third-party notices")
                    Image(systemName: "chevron.right").font(Typography.caption).foregroundStyle(Palette.inkTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.thirdPartyNotices")
            Divider().overlay(Palette.hairline)
            Link(destination: URL(string: "https://github.com/johnarleyburns/parso-tonearm")!) {
                HStack {
                    aboutRow("Source", "View on GitHub")
                    Image(systemName: "arrow.up.right").font(Typography.caption).foregroundStyle(Palette.inkTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider().overlay(Palette.hairline)
            aboutRow("About", "Platterhead \(appVersionString) — you bring the records")
            Divider().overlay(Palette.hairline)
            languagesRow
        }
        .padding(15)
        .glassSurface(cornerRadius: 18)
    }

    /// Every language this build ships, named in its own language, read from
    /// the bundle so the list can never drift from the string catalogs.
    static var shippedLanguageNames: [String] {
        Bundle.main.localizations
            .filter { $0 != "Base" }
            .sorted()
            .map { code in
                let locale = Locale(identifier: code)
                let name = locale.localizedString(forIdentifier: code) ?? code
                return name.prefix(1).uppercased(with: locale) + name.dropFirst()
            }
    }

    var languagesRow: some View {
        let names = Self.shippedLanguageNames
        #if os(macOS)
        // System Settings › General › Language & Region › Applications.
        let destination = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!
        #else
        let destination = URL(string: UIApplication.openSettingsURLString)!
        #endif
        return Link(destination: destination) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    #if os(macOS)
                    aboutRow("Language", "Change in System Settings")
                    #else
                    aboutRow("Language", "Change in iPhone Settings")
                    #endif
                    Image(systemName: "arrow.up.right").font(Typography.caption).foregroundStyle(Palette.inkTertiary)
                }
                #if os(macOS)
                Text("Platterhead is available in \(names.count) languages. It follows your Mac’s language, or you can choose a language just for Platterhead in System Settings › General › Language & Region.")
                    .font(Typography.caption).foregroundStyle(Palette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                #else
                Text("Platterhead is available in \(names.count) languages. It follows your iPhone’s language, or you can choose a language just for Platterhead in iPhone Settings.")
                    .font(Typography.caption).foregroundStyle(Palette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                #endif
                Text(verbatim: names.joined(separator: " · "))
                    .font(Typography.caption).foregroundStyle(Palette.ink)
                    .accessibilityIdentifier("settings.about.languages")
            }
            .padding(.bottom, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.about.changeLanguage")
    }

    func aboutRow(_ title: LocalizedStringKey, _ value: LocalizedStringKey) -> some View {
        HStack {
            Text(title).font(Typography.callout)
            Spacer()
            Text(value).font(Typography.caption).foregroundStyle(Palette.inkTertiary)
        }
        .padding(.vertical, 8)
    }

    var fillFraction: Double {
        guard cacheLimit > 0 else { return 0 }
        return min(1, Double(cacheUsed) / Double(cacheLimit))
    }

    func refresh() async {
        cacheUsed = await AudioCache.shared.totalCachedBytes()
        cacheLimit = await AudioCache.shared.currentLimit()
        cachedCount = await AudioCache.shared.completeEntryCount(kind: "audio")
        customArtworkBytes = customArtworkSize()
        if let stats = try? await appState.store.djPrepStorageStats() {
            analysisTracks = stats.tracks
            analysisBytes = stats.bytes
        }
    }

    func applyCustomCacheLimit() {
        let mb = Int64(customCacheLimitMB.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let requested = mb * 1024 * 1024
        let result = CacheLimitPolicy.validate(requestedBytes: requested, freeDiskBytes: freeDiskBytes())
        cacheLimit = result.allowedBytes
        customCacheLimitMessage = result.reason
        Task { await AudioCache.setLimit(result.allowedBytes); await refresh() }
    }

    func freeDiskBytes() -> Int64 {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    func customArtworkSize() -> Int64 {
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
