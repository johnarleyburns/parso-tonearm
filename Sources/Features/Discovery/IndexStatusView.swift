// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tonearm (Platterhead DJ) — Copyright (C) 2026 John Arley Burns.
// See ../../../LICENSE.

#if canImport(UIKit) && !os(watchOS)
import SwiftUI
import TonearmDiscovery

/// The compact, tappable sound-index banner for the Library screen (plan §10
/// item 2: "Persistent compact status banner: 'Sound index: 238 / 1,042
/// tracks' and actual state such as 'Waiting for charging.'"). Hidden until
/// there is a library to index.
struct IndexStatusBanner: View {
    @ObservedObject var model: IndexStatusModel
    var onTap: () -> Void

    var body: some View {
        if let p = model.presentation, p.showsBanner {
            Button(action: onTap) {
                HStack(spacing: 10) {
                    ProgressView(value: p.modelDownloadFraction ?? p.fractionComplete)
                        .progressViewStyle(.circular)
                        .scaleEffect(0.7)
                        .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.headline)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                        Text(p.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.ink3)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Palette.ink3)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .glassSurface(cornerRadius: 14)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(p.headline). \(p.detail)")
            .task { await model.refresh() }
        }
    }
}

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
                        // deliberately skipped rather than parked forever
                        // waiting for audio that will never arrive, so this
                        // says why the totals above never include them.
                        Text("Only downloaded, on-device tracks are indexed. "
                            + "A track streamed from a remote library is included once you download it.")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.ink3)
                            .padding(.horizontal, 4)
                        countsCard(p)
                        actionsCard(p)
                    } else {
                        ProgressView().padding(.top, 40)
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
            .navigationBarTitleDisplayMode(.inline)
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
                    ActivityView(items: [text])
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
            return "This could use a significant amount of cellular data."
        }
        guard estimate.trackCount > 0 else {
            return "You have no remote tracks waiting to be indexed right now."
        }
        let mb = ByteCountFormatter.string(fromByteCount: estimate.estimatedBytes, countStyle: .file)
        let plural = estimate.trackCount == 1 ? "track" : "tracks"
        return "You have about \(estimate.trackCount) remote \(plural) not yet indexed. "
            + "Indexing them over cellular could use approximately \(mb). Are you sure?"
    }

    // MARK: - Cards

    private func summaryCard(_ p: IndexStatusPresentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(p.headline).font(.system(size: 17, weight: .heavy))
            ProgressView(value: p.modelDownloadFraction ?? p.fractionComplete)
                .tint(Palette.brass)
            Text(p.detail).font(.system(size: 13)).foregroundStyle(Palette.ink2)
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
    private func tappableRow(_ label: String, _ value: Int, bucket: IndexJobRepository.TrackListBucket)
        -> some View
    {
        Button {
            guard value > 0 else { return }
            trackListBucket = bucket
        } label: {
            HStack {
                Text(label).font(.system(size: 14)).foregroundStyle(Palette.ink)
                Spacer()
                Text("\(value)").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink2)
                if value > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.ink3)
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
            Text("Models").font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.ink3)

            if let error = detail.downloadError {
                Text("Download error: \(error)")
                    .font(.system(size: 12))
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
                    .font(.system(size: 13, weight: .semibold))
                Text(tag.tag).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(downloadStateLabel(tag.state))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink3)
            }
            if tag.state == .inProgress {
                if tag.bytesAreTrustworthy {
                    let doneMB = Int((Double(tag.completedBytes) / 1_048_576).rounded())
                    let totalMB = Int((Double(tag.totalBytes) / 1_048_576).rounded())
                    ProgressView(value: tag.fractionComplete)
                        .tint(Palette.brass)
                    Text("\(doneMB) of \(totalMB) MB"
                        + (tag.fractionComplete.map { " (\(Int(($0 * 100).rounded()))%)" } ?? ""))
                        .font(.system(size: 11)).foregroundStyle(Palette.ink3)
                } else {
                    // NSBundleResourceRequest's unit isn't guaranteed to be
                    // real bytes (confirmed on a real device: a literal
                    // totalUnitCount of 1) — never show a fabricated MB
                    // count or percentage here.
                    Text("Downloading — no byte count reported yet")
                        .font(.system(size: 11)).foregroundStyle(Palette.ink3)
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
        case .inProgress: return Palette.brass
        case .notStarted: return Palette.ink3
        }
    }

    private func downloadStateLabel(_ state: ModelDiagnosticsDetail.DownloadTag.State) -> String {
        switch state {
        case .finished: return "Finished"
        case .inProgress: return "Downloading…"
        case .notStarted: return "Not started"
        }
    }

    private func artifactRow(_ artifact: ModelDiagnosticsDetail.Artifact) -> some View {
        HStack {
            Image(systemName: artifact.isResolved ? "doc.fill" : "questionmark.folder")
                .foregroundStyle(artifact.isResolved ? .green : .orange)
                .font(.system(size: 13, weight: .semibold))
            Text(artifact.name).font(.system(size: 13))
            Spacer()
            Text(artifact.isResolved ? (artifact.resolvedName ?? "Found") : "Not found")
                .font(.system(size: 12))
                .foregroundStyle(artifact.isResolved ? Palette.ink3 : .orange)
        }
        .padding(.vertical, 4)
    }

    private func actionsCard(_ p: IndexStatusPresentation) -> some View {
        VStack(spacing: 10) {
            if p.canResume {
                actionButton("Resume indexing", "play.fill") { await model.setPaused(false) }
            } else if p.canPause {
                actionButton("Pause indexing", "pause.fill") { await model.setPaused(true) }
            }
            if p.canRetryFailed {
                actionButton("Retry \(p.failedCount) failed", "arrow.clockwise") {
                    await model.retryFailed()
                }
            }
            Toggle(
                "Only index while charging",
                isOn: Binding(
                    get: { model.snapshot?.isChargingOnly ?? false },
                    set: { on in Task { await model.setChargingOnly(on) } })
            )
            .font(.system(size: 14))
            .padding(.vertical, 4)

            Divider().overlay(Palette.hairline)

            remoteIndexingToggles

            actionButton("Export diagnostics", "square.and.arrow.up") {
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
                    get: { model.snapshot?.isRemoteIndexingEnabled ?? false },
                    set: { on in Task { await model.setRemoteIndexingEnabled(on) } })
            )
            .font(.system(size: 14))
            .padding(.vertical, 4)
            Text("Samples just enough of each track from your remote libraries to index it — "
                + "the audio is never downloaded or kept.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.ink3)

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
                .font(.system(size: 14))
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
            .font(.system(size: 14, weight: .semibold))
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
            Text("Activity").font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.ink3)
            line("Last run", r?.lastRunAt)
            line("Last successful work", r?.lastSuccessfulWorkAt)
            line("Last background submit", r?.lastBackgroundSubmissionAt)
            if let reason = r?.lastStopReason {
                Text(reason).font(.system(size: 11)).foregroundStyle(Palette.ink3)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 18)
    }

    private func line(_ label: String, _ date: Date?) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(Palette.ink3)
            Spacer()
            Text(date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                .font(.system(size: 12)).foregroundStyle(Palette.ink2)
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
                            .font(.system(size: 14)).foregroundStyle(Palette.ink3)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(tracks) { track in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title).font(.system(size: 14)).lineLimit(1)
                                if let artist = track.artistName {
                                    Text(artist).font(.system(size: 12)).foregroundStyle(Palette.ink3)
                                        .lineLimit(1)
                                }
                                if let detail = track.detail {
                                    Text(detail).font(.system(size: 11)).foregroundStyle(Palette.ink3)
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            tracks = await model.trackSummaries(for: bucket)
        }
    }

    private var title: String {
        switch bucket {
        case .complete: return "Indexed"
        case .queuedOrRunning: return "Queued"
        case .waiting: return "Waiting"
        case .failed: return "Failed"
        }
    }
}

/// Minimal `UIActivityViewController` wrapper for the redacted-diagnostics
/// share sheet (plan §10.6).
private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
