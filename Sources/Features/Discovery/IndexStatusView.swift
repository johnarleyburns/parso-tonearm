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
        }
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
            row("Indexed", c?.complete ?? 0)
            Divider().overlay(Palette.hairline)
            row("Queued", c?.queuedOrRunning ?? 0)
            Divider().overlay(Palette.hairline)
            row("Waiting", c?.waiting ?? 0)
            Divider().overlay(Palette.hairline)
            row("Failed", p.failedCount)
        }
        .padding(15)
        .glassSurface(cornerRadius: 18)
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

    private func row(_ label: String, _ value: Int) -> some View {
        HStack {
            Text(label).font(.system(size: 14))
            Spacer()
            Text("\(value)").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink2)
        }
        .padding(.vertical, 10)
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

            actionButton("Export diagnostics", "square.and.arrow.up") {
                diagnosticsText = await model.diagnosticsText()
                showShare = true
            }
        }
        .disabled(model.isBusy)
        .padding(15)
        .glassSurface(cornerRadius: 18)
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
