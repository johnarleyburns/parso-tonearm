// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tonearm (Platterhead DJ) — Copyright (C) 2026 John Arley Burns.
// See ../../../LICENSE.

#if !os(watchOS)
import SwiftUI
import TonearmDiscovery

/// The full sound-index status screen (plan §10 item 3 + actions in item 4 +
/// diagnostics export in item 6).
struct IndexStatusView: View {
    @ObservedObject var model: IndexStatusModel
    @Environment(\.dismiss) private var dismiss
    @State private var diagnosticsText: String?
    @State private var showShare = false
    @State private var trackListBucket: IndexJobRepository.TrackListBucket?
    @State private var showWiFiOnlyOffConfirmation = false
    @State private var wifiOnlyOffEstimate: (trackCount: Int, estimatedBytes: Int64)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let p = model.presentation {
                        summaryCard(p)
                        // Real report: "I don't necessarily want to download
                        // ALL the files in my library, it's too many, I want
                        // to only index downloaded/on-device tracks" —
                        // remote/cloud tracks that were never downloaded are
                        // skipped by default rather than parked forever
                        // waiting for audio that will never arrive, so this
                        // says why the totals above don't include them
                        // unless the owner has since turned on remote
                        // sparse sampling below.
                        Text(
                            model.snapshot?.isRemoteIndexingEnabled == true
                                ? "Downloaded tracks are indexed fully; remote tracks are sampled just enough to index without downloading them."
                                : "Only downloaded, on-device tracks are indexed. A track streamed from a remote library is included once you download it."
                        )
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkTertiary)
                        .padding(.horizontal, 4)
                        countsCard(p)
                        actionsCard(p)
                    } else if let error = model.errorMessage {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Sound Index unavailable", systemImage: "exclamationmark.triangle")
                                .font(Typography.body)
                            Text(error)
                                .font(Typography.caption)
                                .foregroundStyle(Palette.inkSecondary)
                            Button("Retry") { Task { await model.refresh() } }
                                .buttonStyle(.borderedProminent)
                                .tint(Palette.accent)
                        }
                        .padding(15)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassSurface(cornerRadius: 18)
                    } else {
                        ProgressView("Reading Sound Index…").padding(.top, 40)
                    }
                    if let detail = model.snapshot?.modelDiagnostics {
                        modelsCard(detail)
                    }
                    activityCard
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .foregroundStyle(Palette.ink)
            .navigationTitle("Sound Index")
            .compactNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await model.refresh()
                model.startPolling()
            }
            .onDisappear { model.stopPolling() }
            .sheet(isPresented: $showShare) {
                if let text = diagnosticsText {
                    DiagnosticsShareSheet(text: text)
                }
            }
            .alert(
                "Allow cellular data for remote indexing?",
                isPresented: $showWiFiOnlyOffConfirmation
            ) {
                Button("Cancel", role: .cancel) { wifiOnlyOffEstimate = nil }
                Button("Turn Off Wi-Fi Only", role: .destructive) {
                    wifiOnlyOffEstimate = nil
                    Task { await model.setRemoteIndexingWiFiOnly(false) }
                }
            } message: {
                Text(wifiOnlyOffConfirmationMessage)
            }
        }
    }

    private var wifiOnlyOffConfirmationMessage: String {
        guard let estimate = wifiOnlyOffEstimate else {
            return String(localized: "This could use a significant amount of cellular data.")
        }
        guard estimate.trackCount > 0 else {
            return String(localized: "You have no remote tracks waiting to be indexed right now.")
        }
        let mb = ByteCountFormatter.string(fromByteCount: estimate.estimatedBytes, countStyle: .file)
        return String(localized: "You have about \(estimate.trackCount) remote tracks not yet indexed. Indexing them over cellular could use approximately \(mb). Are you sure?")
    }

    // MARK: - Cards

    private func summaryCard(_ p: IndexStatusPresentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(p.headline).font(Typography.headline)
            ProgressView(value: p.modelDownloadFraction ?? p.fractionComplete)
                .tint(Palette.accent)
            Text(p.detail).font(Typography.callout).foregroundStyle(Palette.inkSecondary)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 18)
    }

    private func countsCard(_ p: IndexStatusPresentation) -> some View {
        let c = model.snapshot?.coverage
        return VStack(spacing: 0) {
            tappableRow("Indexed", c?.complete ?? 0, bucket: .complete)
            Divider().overlay(Palette.hairline)
            tappableRow("Queued", c?.queuedOrRunning ?? 0, bucket: .queuedOrRunning)
            Divider().overlay(Palette.hairline)
            tappableRow("Waiting", c?.waiting ?? 0, bucket: .waiting)
            Divider().overlay(Palette.hairline)
            tappableRow("Failed", p.failedCount, bucket: .failed)
        }
        .padding(15)
        .glassSurface(cornerRadius: 18)
        .sheet(item: $trackListBucket) { bucket in
            IndexTrackListSheet(model: model, bucket: bucket)
        }
    }

    /// A `countsCard` row that opens the real track list for that bucket — real report: "I want
    /// to actually see what's happening and what's indexed," not just a count.
    private func tappableRow(_ label: LocalizedStringKey, _ value: Int, bucket: IndexJobRepository.TrackListBucket)
        -> some View
    {
        Button {
            guard value > 0 else { return }
            trackListBucket = bucket
        } label: {
            HStack {
                Text(label).font(Typography.callout).foregroundStyle(Palette.ink)
                Spacer()
                Text("\(value)").font(Typography.callout).foregroundStyle(Palette.inkSecondary)
                if value > 0 {
                    Image(systemName: "chevron.right")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkTertiary)
                }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(value == 0)
    }

    /// The "Models" section — added directly at the user's request for an
    /// interactive debug session ("show each model, the percentage
    /// downloaded, MB downloaded, if it's complete or not, any errors, also
    /// show active downloading, we need this level of detail to know what's
    /// going on"). Two distinct facts per model, shown separately on
    /// purpose: the raw ODR download state, and whether the resulting file
    /// actually resolves on disk — a real device once showed both downloads
    /// "finished" while every artifact still failed to resolve, and only
    /// showing one of those two facts would have hidden that gap again.
    private func modelsCard(_ detail: ModelDiagnosticsDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Models").font(Typography.callout).foregroundStyle(Palette.inkTertiary)

            if let error = detail.downloadError {
                Text("Download error: \(error)")
                    .font(Typography.caption)
                    .foregroundStyle(.red)
            }

            ForEach(detail.downloadTags) { tag in
                downloadTagRow(tag)
                Divider().overlay(Palette.hairline)
            }
            ForEach(detail.artifacts) { artifact in
                artifactRow(artifact)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 18)
    }

    private func downloadTagRow(_ tag: ModelDiagnosticsDetail.DownloadTag) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: downloadStateIcon(tag.state))
                    .foregroundStyle(downloadStateColor(tag.state))
                    .font(Typography.callout)
                Text(tag.tag).font(Typography.callout)
                Spacer()
                Text(downloadStateLabel(tag.state))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
            }
            if tag.state == .inProgress {
                if tag.bytesAreTrustworthy {
                    let doneMB = Int((Double(tag.completedBytes) / 1_048_576).rounded())
                    let totalMB = Int((Double(tag.totalBytes) / 1_048_576).rounded())
                    ProgressView(value: tag.fractionComplete)
                        .tint(Palette.accent)
                    Text("\(doneMB) of \(totalMB) MB"
                        + (tag.fractionComplete.map { " (\(Int(($0 * 100).rounded()))%)" } ?? ""))
                        .font(Typography.caption).foregroundStyle(Palette.inkTertiary)
                } else {
                    // NSBundleResourceRequest's unit isn't guaranteed to be
                    // real bytes (confirmed on a real device: a literal
                    // totalUnitCount of 1) — never show a fabricated MB
                    // count or percentage here.
                    Text("Downloading — no byte count reported yet")
                        .font(Typography.caption).foregroundStyle(Palette.inkTertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func downloadStateIcon(_ state: ModelDiagnosticsDetail.DownloadTag.State) -> String {
        switch state {
        case .finished: return "checkmark.circle.fill"
        case .inProgress: return "arrow.down.circle"
        case .notStarted: return "circle.dashed"
        }
    }

    private func downloadStateColor(_ state: ModelDiagnosticsDetail.DownloadTag.State) -> Color {
        switch state {
        case .finished: return .green
        case .inProgress: return Palette.accent
        case .notStarted: return Palette.inkTertiary
        }
    }

    private func downloadStateLabel(_ state: ModelDiagnosticsDetail.DownloadTag.State) -> String {
        switch state {
        case .finished: return String(localized: "Finished")
        case .inProgress: return String(localized: "Downloading…")
        case .notStarted: return String(localized: "Not started")
        }
    }

    private func artifactRow(_ artifact: ModelDiagnosticsDetail.Artifact) -> some View {
        HStack {
            Image(systemName: artifact.isResolved ? "doc.fill" : "questionmark.folder")
                .foregroundStyle(artifact.isResolved ? .green : .orange)
                .font(Typography.callout)
            Text(artifact.name).font(Typography.callout)
            Spacer()
            Text(artifact.isResolved ? (artifact.resolvedName ?? String(localized: "Found")) : String(localized: "Not found"))
                .font(Typography.caption)
                .foregroundStyle(artifact.isResolved ? Palette.inkTertiary : .orange)
        }
        .padding(.vertical, 4)
    }

    private func actionsCard(_ p: IndexStatusPresentation) -> some View {
        VStack(spacing: 10) {
            if p.canResume {
                actionButton(String(localized: "Resume indexing"), "play.fill") { await model.setPaused(false) }
            } else if p.canPause {
                actionButton(String(localized: "Pause indexing"), "pause.fill") { await model.setPaused(true) }
            }
            if p.canRetryFailed {
                actionButton(String(localized: "Retry \(p.failedCount) failed"), "arrow.clockwise") {
                    await model.retryFailed()
                }
            }
            Toggle(
                "Only index while charging",
                isOn: Binding(
                    get: { model.snapshot?.isChargingOnly ?? false },
                    set: { on in Task { await model.setChargingOnly(on) } })
            )
            .font(Typography.callout)
            .padding(.vertical, 4)

            Divider().overlay(Palette.hairline)

            remoteIndexingToggles

            actionButton(String(localized: "Enqueue unindexed tracks"), "arrow.triangle.2.circlepath") {
                let count = await model.enqueueUnindexedTracks()
                if count > 0 {
                    ToastCenter.shared.success("Queued \(count) tracks")
                } else {
                    ToastCenter.shared.info("Everything eligible is already queued or indexed")
                }
            }

            actionButton(String(localized: "Export diagnostics"), "square.and.arrow.up") {
                diagnosticsText = await model.diagnosticsText()
                showShare = true
            }
        }
        .disabled(model.isBusy)
        .padding(15)
        .glassSurface(cornerRadius: 18)
    }

    /// Real, ongoing network-data cost — off by default (plan:
    /// "must ship gated behind an explicit, off-by-default setting, never
    /// silently enabled"). Turning Wi-Fi-only OFF is the one action here
    /// that needs a confirmation, since it's the one that can spend
    /// cellular data unattended; every other change here takes effect
    /// immediately, same as "Only index while charging" above.
    private var remoteIndexingToggles: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(
                "Index tracks I haven't downloaded",
                isOn: Binding(
                    get: { model.snapshot?.isRemoteIndexingEnabled ?? true },
                    set: { on in Task { await model.setRemoteIndexingEnabled(on) } })
            )
            .font(Typography.callout)
            .padding(.vertical, 4)
            Text("Samples just enough of each track from your remote libraries to index it — the audio is never downloaded or kept.")
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)

            if model.snapshot?.isRemoteIndexingEnabled == true {
                Toggle(
                    "Wi-Fi only",
                    isOn: Binding(
                        get: { model.snapshot?.isRemoteIndexingWiFiOnly ?? true },
                        set: { on in
                            if on {
                                Task { await model.setRemoteIndexingWiFiOnly(true) }
                            } else {
                                Task {
                                    wifiOnlyOffEstimate = await model.remoteIndexingEstimate()
                                    showWiFiOnlyOffConfirmation = true
                                }
                            }
                        })
                )
                .font(Typography.callout)
                .padding(.vertical, 4)
                .padding(.leading, 14)
            }
        }
    }

    private func actionButton(
        _ title: String, _ icon: String, _ action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack {
                Image(systemName: icon)
                Text(title)
                Spacer()
            }
            .font(Typography.callout)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.hairline, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var activityCard: some View {
        let r = model.snapshot?.runtime
        return VStack(alignment: .leading, spacing: 6) {
            Text("Activity").font(Typography.callout).foregroundStyle(Palette.inkTertiary)
            line("Last run", r?.lastRunAt)
            line("Last successful work", r?.lastSuccessfulWorkAt)
            line("Last background submit", r?.lastBackgroundSubmissionAt)
            if let reason = r?.lastStopReason {
                Text(reason).font(Typography.caption).foregroundStyle(Palette.inkTertiary)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 18)
    }

    private func line(_ label: LocalizedStringKey, _ date: Date?) -> some View {
        HStack {
            Text(label).font(Typography.caption).foregroundStyle(Palette.inkTertiary)
            Spacer()
            Text(date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                .font(Typography.caption).foregroundStyle(Palette.inkSecondary)
        }
    }
}

/// The scrollable drill-down for one `countsCard` bucket — real report: "I want to actually see
/// what's happening and what's indexed." On-device only: shows real track titles/artists, unlike
/// the redacted `DiscoveryDiagnostics` export below (plan §10.6).
private struct IndexTrackListSheet: View {
    let model: IndexStatusModel
    let bucket: IndexJobRepository.TrackListBucket
    @Environment(\.dismiss) private var dismiss
    @State private var tracks: [IndexJobRepository.TrackSummary]?

    var body: some View {
        NavigationStack {
            Group {
                if let tracks {
                    if tracks.isEmpty {
                        Text("Nothing here right now.")
                            .font(Typography.callout).foregroundStyle(Palette.inkTertiary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(tracks) { track in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title).font(Typography.callout).lineLimit(1)
                                if let artist = track.artistName {
                                    Text(artist).font(Typography.caption).foregroundStyle(Palette.inkTertiary)
                                        .lineLimit(1)
                                }
                                if let detail = track.detail {
                                    Text(detail).font(Typography.caption).foregroundStyle(Palette.inkTertiary)
                                        .lineLimit(2)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .listStyle(.plain)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(title)
            .compactNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            tracks = await model.trackSummaries(for: bucket)
        }
        // Real report: scrolling this list feels "jerky... like it's
        // processing something on the UI thread." Root cause: the status
        // screen underneath keeps polling every 2s (`IndexStatusView`'s
        // `.task { model.startPolling() }`) even while this sheet is on
        // top of it, so every couple of seconds the whole presenting view
        // republishes and re-lays-out mid-scroll. Nothing in this static,
        // one-time track list needs that live refresh, so pause it while
        // the sheet is open and resume when it's dismissed.
        .onAppear { model.stopPolling() }
        .onDisappear { model.startPolling() }
    }

    private var title: String {
        switch bucket {
        case .complete: return String(localized: "Indexed")
        case .queuedOrRunning: return String(localized: "Queued")
        case .waiting: return String(localized: "Waiting")
        case .failed: return String(localized: "Failed")
        }
    }
}

/// The redacted-diagnostics share sheet (plan §10.6). `ShareLink` is fully
/// cross-platform SwiftUI (iOS 16+/macOS 13+, well within this project's
/// deployment targets) — it renders the real `UIActivityViewController` on
/// iOS and `NSSharingServicePicker` on macOS automatically, so this needs no
/// platform-specific wrapper at all (native Mac app,
/// docs/plans/native-mac-app-plan.md §2a — this file's own UIKit-only
/// `UIActivityViewController`/`UIViewControllerRepresentable` wrapper is
/// exactly the kind of real, but avoidable, port that section flagged).
private struct DiagnosticsShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    let text: String

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(Typography.mono)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }
            .navigationTitle("Diagnostics")
            .compactNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: text)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
#endif
