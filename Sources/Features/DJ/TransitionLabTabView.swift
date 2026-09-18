import ParsoDJEngine
import SwiftUI
import TonearmCore
import TonearmDJ

/// The DJ tab's root (docs/plans/UNIFIED_TONEARM_MY_MUSIC_TRANSITION_LAB_HANDOFF.md
/// §7): choose two tracks, get phrase-aware transition suggestions from PAE
/// 1.2's `TransitionPlanner`, and preview one. No home/menu screen — this
/// *is* the DJ tab.
///
/// Deliberately not built here yet: a live practice loop (arming
/// `SmartFader` on a `HeadlessDJEngine` and rendering in real time) — this
/// screen covers "get a suggestion, hear it" with the one-shot
/// `TransitionPreviewRenderer` path, which needs no engine-lifecycle
/// management. Practice/Set Practice (walking a whole playlist) is a
/// follow-up once this core loop is confirmed working on a real device.
struct TransitionLabTabView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var model: TransitionLabModel
    @State private var outgoing: TrackRow?
    @State private var incoming: TrackRow?
    @State private var pickerTarget: PickerTarget?

    private enum PickerTarget: Identifiable {
        case outgoing, incoming
        var id: Int { self == .outgoing ? 0 : 1 }
    }

    init() {
        _model = StateObject(wrappedValue: TransitionLabModel(writer: LibraryStore.shared.dbQueue))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ScreenHeader(title: "Transition Lab")
                    Text("Prepare how two tracks meet.")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink3)

                    trackSlot("Outgoing track", row: outgoing) { pickerTarget = .outgoing }
                        .accessibilityIdentifier("dj.transition.outgoing")
                    trackSlot("Incoming track", row: incoming) { pickerTarget = .incoming }
                        .accessibilityIdentifier("dj.transition.incoming")

                    if outgoing != nil, incoming != nil {
                        stateView
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 160)
            }
            .background(Palette.libraryBackground.ignoresSafeArea())
            .foregroundStyle(Palette.ink)
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(item: $pickerTarget) { target in
            TrackPickerSheet(title: target == .outgoing ? "Choose Outgoing Track" : "Choose Incoming Track") { row in
                if target == .outgoing { outgoing = row } else { incoming = row }
                pickerTarget = nil
                replan()
            }
        }
        .onChange(of: outgoing) { _, _ in replan() }
        .onChange(of: incoming) { _, _ in replan() }
        .task { consumePendingSeed() }
    }

    /// A playlist's "Practice transitions" action seeds a pair and switches
    /// to this tab (plan §14) — one-shot, cleared immediately so returning
    /// to DJ later doesn't silently reset the user's own in-progress pick.
    private func consumePendingSeed() {
        guard let seed = appState.pendingTransitionLabPair else { return }
        appState.pendingTransitionLabPair = nil
        outgoing = seed.outgoing
        incoming = seed.incoming
    }

    private func replan() {
        guard let outgoing, let incoming else { return }
        model.plan(outgoing: outgoing, incoming: incoming)
    }

    private func trackSlot(_ title: String, row: TrackRow?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ArtworkView(trackRow: row, seed: row?.track.title ?? title, cornerRadius: 10)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink3)
                    Text(row?.track.title ?? "Choose…")
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(row == nil ? Palette.ink3 : Palette.ink)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Palette.ink3)
            }
            .padding(12)
            .glassSurface(cornerRadius: 14)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var stateView: some View {
        switch model.state {
        case .downloadRequired(let out, let inc):
            EmptyStateView(
                icon: "arrow.down.circle",
                title: "Download required",
                message: (out && inc)
                    ? "Both tracks need to be downloaded before Transition Lab can analyze them."
                    : "The \(out ? "outgoing" : "incoming") track needs to be downloaded before Transition Lab can analyze it."
            )
            .padding(.top, 20)
        case .analyzing(let progress):
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Analyzing")
                progressRow("Outgoing", progress.outgoingFraction)
                progressRow("Incoming", progress.incomingFraction)
            }
            .padding(15)
            .glassSurface(cornerRadius: 18)
        case .failed(let message):
            EmptyStateView(icon: "exclamationmark.triangle", title: "Analysis failed", message: message)
                .padding(.top, 20)
        case .ready(let proposals):
            if proposals.isEmpty {
                EmptyStateView(
                    icon: "waveform.slash", title: "No transition found",
                    message: "These two tracks don't share a workable tempo/phrase match.")
                    .padding(.top, 20)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "Suggestions", trailing: "\(proposals.count)")
                    ForEach(proposals) { proposal in
                        candidateRow(proposal)
                    }
                }
            }
        }
    }

    private func progressRow(_ label: String, _ fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12)).foregroundStyle(Palette.ink3)
            ProgressView(value: fraction ?? 0).tint(Palette.brass)
        }
    }

    private func candidateRow(_ proposal: AudioTransitionProposal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(proposal.technique.displayName)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(Int(proposal.score * 100))% fit")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.brass)
            }
            Text("\(proposal.bars) bars"
                + (proposal.keySyncRecommended ? " · key-synced" : "")
                + (proposal.incomingTempoRatio != 1
                    ? " · \(String(format: "%.1f%%", (proposal.incomingTempoRatio - 1) * 100)) tempo"
                    : ""))
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.ink3)
            clashSummary(proposal.clashes)
            HStack(spacing: 10) {
                Button {
                    model.preview(proposal)
                } label: {
                    Label(model.isPreviewing ? "Playing…" : "Preview", systemImage: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                }
                .disabled(model.isPreviewing)
                if model.isPreviewing {
                    Button("Stop") { model.stopPreview() }
                        .font(.system(size: 13))
                }
            }
            .accessibilityIdentifier("dj.transition.preview")
            if let error = model.previewError {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
        .padding(15)
        .glassSurface(cornerRadius: 14)
    }

    private func clashSummary(_ clashes: TransitionClashMetrics) -> some View {
        Text("Combined clash: \(Int(clashes.combined * 100))%"
            + " · bass \(Int(clashes.bassCollision * 100))%"
            + " · harmonic \(Int(clashes.harmonicTension * 100))%")
            .font(.system(size: 10.5))
            .foregroundStyle(Palette.ink3)
    }
}

extension TransitionTechnique {
    var displayName: String {
        switch self {
        case .longBlend: return "Long Blend"
        case .bassSwap: return "Bass Swap"
        case .filterBlend: return "Filter Blend"
        case .echoOut: return "Echo Out"
        case .quickCut: return "Quick Cut"
        @unknown default: return "Transition"
        }
    }
}

/// A minimal metadata track picker — searches the whole library, no scope
/// filtering. Deliberately simple: this is Transition Lab's own picker, not
/// a re-implementation of My Music's search.
private struct TrackPickerSheet: View {
    let title: String
    let onPick: (TrackRow) -> Void
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var rows: [TrackRow] {
        guard !query.isEmpty else { return appState.allTracks }
        return appState.allTracks.filter {
            $0.track.title.localizedCaseInsensitiveContains(query)
                || ($0.album?.artist?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            List(rows.prefix(300)) { row in
                Button {
                    onPick(row)
                } label: {
                    TrackRowView(row: row, showArtwork: true)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
