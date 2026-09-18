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
/// `SmartFader` on a `HeadlessDJEngine` and rendering in real time). Real-
/// time audio hosting has no compile-time safety net — it needs a real
/// device to verify — so it's left as a documented follow-up rather than
/// shipped unverified. This screen covers "get a suggestion, hear it" with
/// the one-shot `TransitionPreviewRenderer` path, which needs no engine-
/// lifecycle management, for both a single pair and Set Practice (walking a
/// whole playlist's adjacent pairs one at a time).
struct TransitionLabTabView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer
    @StateObject private var model: TransitionLabModel
    @State private var outgoing: TrackRow?
    @State private var incoming: TrackRow?
    @State private var pickerTarget: PickerTarget?

    /// Set Practice state — present only when launched from a playlist's
    /// "Practice transitions" action. `edgeIndex` is the currently-shown
    /// adjacent pair (tracks[edgeIndex] -> tracks[edgeIndex + 1]).
    @State private var setPractice: (playlistId: Int64, tracks: [TrackRow])?
    @State private var edgeIndex = 0

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
                        .accessibilityIdentifier("dj.transitionLab")
                    Text(setPractice != nil ? "Practice this playlist's transitions, one at a time."
                         : "Prepare how two tracks meet.")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink3)

                    if setPractice != nil {
                        setPracticeStepper
                    }

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
                setPractice = nil  // manual re-pick exits Set Practice
                replan()
            }
        }
        .onChange(of: outgoing) { _, _ in replan() }
        .onChange(of: incoming) { _, _ in replan() }
        .task { consumePendingSeed() }
    }

    /// A playlist's "Practice transitions" action seeds the full track list
    /// and switches to this tab (plan §14) — one-shot, cleared immediately
    /// so returning to DJ later doesn't silently reset the user's own
    /// in-progress pick. With no seed, default the outgoing slot to Now
    /// Playing (or the most recently played track) so the common
    /// single-pair case needs only one picker interaction instead of two
    /// (docs/plans/ui-simplification-plan.md item 3) — manual override via
    /// the picker button is unaffected.
    private func consumePendingSeed() {
        guard let seed = appState.pendingTransitionLabSet, seed.tracks.count >= 2 else {
            if outgoing == nil {
                outgoing = player.currentTrack ?? appState.recentlyPlayed.first
            }
            return
        }
        appState.pendingTransitionLabSet = nil
        setPractice = seed
        edgeIndex = 0
        loadCurrentEdge()
    }

    private func loadCurrentEdge() {
        guard let setPractice, setPractice.tracks.indices.contains(edgeIndex + 1) else { return }
        outgoing = setPractice.tracks[edgeIndex]
        incoming = setPractice.tracks[edgeIndex + 1]
        replan()
    }

    private var setPracticeStepper: some View {
        HStack {
            Button {
                guard edgeIndex > 0 else { return }
                edgeIndex -= 1
                loadCurrentEdge()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(edgeIndex == 0)
            Spacer()
            VStack(spacing: 2) {
                Text("Transition \(edgeIndex + 1) of \((setPractice?.tracks.count ?? 1) - 1)")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.ink3)
                if let setPractice, let outgoing, let incoming,
                    let edge = model.edgeStatus(
                        playlistId: setPractice.playlistId, outgoing: outgoing, incoming: incoming)
                {
                    Text(edge.status == TransitionPlaylistEdgeRow.Status.prepared.rawValue
                        ? "Prepared" : "Needs work")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(
                            edge.status == TransitionPlaylistEdgeRow.Status.prepared.rawValue
                                ? Palette.brass : Palette.ink3)
                }
            }
            Spacer()
            Button {
                guard let setPractice, edgeIndex < setPractice.tracks.count - 2 else { return }
                edgeIndex += 1
                loadCurrentEdge()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled((setPractice?.tracks.count ?? 0) - 2 <= edgeIndex)
        }
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(Palette.brass)
        .padding(12)
        .glassSurface(cornerRadius: 14)
    }

    private func replan() {
        guard let outgoing, let incoming else { return }
        model.plan(outgoing: outgoing, incoming: incoming)
    }

    /// Called after a preview so Set Practice can show prepared/needs-work
    /// per edge without re-running `TransitionPlanner` every time the screen
    /// reopens.
    private func recordEdgeChoice(_ proposal: AudioTransitionProposal?) {
        guard let setPractice, let outgoing, let incoming else { return }
        model.saveEdge(
            playlistId: setPractice.playlistId, outgoing: outgoing, incoming: incoming,
            proposal: proposal)
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
                    recordEdgeChoice(proposal)
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
