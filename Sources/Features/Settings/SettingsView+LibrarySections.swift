import ParsoAudioStreaming
import SwiftUI
import TonearmCore
#if canImport(UIKit)
import UIKit
#endif

extension SettingsView {
    var musicLibrariesCard: some View {
        Button { activeSheet = .musicLibraries } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Music Libraries").font(Typography.callout)
                    Text(
                        appState.sources.isEmpty
                            ? "Local folders, servers & cloud"
                            : "\(appState.sources.count) connected"
                    )
                    .font(Typography.caption).foregroundStyle(Palette.inkTertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.inkTertiary)
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
    var soundIndexCard: some View {
        Button { activeSheet = .soundIndex } label: {
            HStack {
                Text("Sound Index").font(Typography.callout)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.inkTertiary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.soundIndex")
        .padding(15)
        .glassSurface(cornerRadius: 18)
    }

    var analysisCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transition analysis").font(Typography.callout)
                    Text("Beat grids and phrase maps used to plan transitions. Rebuilt when needed. \(analysisTracks) tracks · \(TimeFmt.megabytes(analysisBytes))")
                        .font(Typography.caption).foregroundStyle(Palette.inkTertiary)
                        .contentTransition(.numericText())
                }
                Spacer()
                Button("Clear analysis", role: .destructive) { showClearAnalysisConfirm = true }
                    .font(Typography.caption)
            }
        }
        .padding(15)
        .glassSurface(cornerRadius: 18)
        .accessibilityIdentifier("settings.transitionAnalysis")
    }

    var behaviorCard: some View {
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

    var prefetchControl: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Prefetch next tracks").font(Typography.callout)
                Text("Cache ahead while playing")
                    .font(Typography.caption).foregroundStyle(Palette.inkTertiary)
            }
            Spacer()
            // Real report: "the +/- does nothing, I don't see any number
            // shown" — a Stepper's label closure is accessibility-only on
            // iOS; it is never rendered inline next to the control, however
            // it's used here (this was true before this change too — not a
            // new regression). The value needs its own always-visible Text.
            Text("\(appState.prefetchDepth)").font(Typography.callout)
                .monospacedDigit()
            Stepper("", value: $appState.prefetchDepth,
                    in: PrefetchDepthPolicy.minimum...PrefetchDepthPolicy.maximum)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.vertical, 6)
    }

    var eqRow: some View {
        Button { activeSheet = .eq } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("10-band EQ").font(Typography.callout)
                    Text("Presets and custom curves")
                        .font(Typography.caption).foregroundStyle(Palette.inkTertiary)
                }
                Spacer()
                Image(systemName: "slider.vertical.3")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.inkTertiary)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.eq")
    }

    /// iCloud sync — free for all users. Off by default; the engine runs when
    /// the toggle is on and an iCloud account is available.
    var syncCard: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("iCloud Sync").font(Typography.callout)
                    Text("Music, playlists & settings across your devices, using your own iCloud")
                        .font(Typography.caption).foregroundStyle(Palette.inkTertiary)
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
                .labelsHidden().tint(Palette.accent)
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
    var discoverySyncActivityRow: some View {
        DiscoverySyncActivityRow()
    }

    var watchCard: some View {
        Button { showWatchSettings = true } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Watch").font(Typography.callout)
                    Text("Download music for offline playback on your watch")
                        .font(Typography.caption).foregroundStyle(Palette.inkTertiary)
                }
                Spacer()
                Image(systemName: "applewatch")
                    .font(Typography.body)
                    .foregroundStyle(Palette.inkTertiary)
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
    var jamendoCard: some View {
        Button { activeSheet = .jamendoKey } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Jamendo key").font(Typography.callout)
                    Text("Use your own application key for genre libraries")
                        .font(Typography.caption).foregroundStyle(Palette.inkTertiary)
                }
                Spacer()
                Image(systemName: "key")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.inkTertiary)
            }
            .padding(15)
            .glassSurface(cornerRadius: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.jamendo.key")
    }

    var toolsCard: some View {
        Button { activeSheet = .tools } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tools").font(Typography.callout)
                    Text("Smart playlists, tags, duplicates, parametric EQ and more")
                        .font(Typography.caption).foregroundStyle(Palette.inkTertiary)
                }
                Spacer()
                Image(systemName: "wrench.and.screwdriver")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.inkTertiary)
            }
            .padding(15)
            .glassSurface(cornerRadius: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.tools")
    }

    func settingToggle(
        _ title: String, _ sub: String, _ binding: Binding<Bool>, id: String? = nil
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typography.callout)
                Text(sub).font(Typography.caption).foregroundStyle(Palette.inkTertiary)
            }
            Spacer()
            // The identifier belongs on the Toggle itself, not the row — an
            // identifier on the surrounding HStack merges into a single
            // accessibility element whose reported control type/value is the
            // row's own (a StaticText), not the switch's, so UI-test taps
            // land on the row but state reads/writes never see the switch.
            Toggle("", isOn: binding)
                .labelsHidden().tint(Palette.accent)
                .modifier(OptionalAccessibilityIdentifier(id: id))
        }
        .padding(.vertical, 8)
    }

    /// The Settings-level detail for Keep Playing (CLAUDE.md "let them drill
    /// down for more info in settings") — the primary discoverable toggle is
    /// in Now Playing's queue header (`UpNextView.keepPlayingToggle`), not
    /// here; this just explains how picking works and exposes the batch size.
}
