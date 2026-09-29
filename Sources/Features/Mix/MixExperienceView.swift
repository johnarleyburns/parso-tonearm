import Charts
import SwiftUI
import TonearmCore
import TonearmDiscovery

struct MixEntryCard: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "waveform.path.ecg")
                    .font(.title2)
                    .foregroundStyle(Palette.accent)
                    .frame(width: 44, height: 44)
                    .background(Palette.accent.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("Build a Mix").font(Typography.headline)
                    Text("Let Platterhead shape a smooth order from your music.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(Palette.inkTertiary)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .adaptiveGlass(cornerRadius: 18)
        .accessibilityIdentifier("listen.buildMix")
    }
}

struct MixBuilderSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let rows: [TrackRow]
    let lockedFirst: Int64?
    let sourcePlaylist: Playlist?
    @State private var shape: MixShape = .risingBPM
    @State private var duration: TimeInterval?
    @State private var plan: MixPlan?
    @State private var isLoading = false

    init(rows: [TrackRow], lockedFirst: Int64? = nil, sourcePlaylist: Playlist? = nil) {
        self.rows = rows
        self.lockedFirst = lockedFirst
        self.sourcePlaylist = sourcePlaylist
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Source") {
                    LabeledContent("Tracks", value: "\(rows.count)")
                    Text("Only tracks with transition analysis are placed. Nothing is silently discarded.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkSecondary)
                }
                Section("Shape") {
                    ForEach(MixShape.allCases, id: \.self) { item in
                        Button { shape = item } label: {
                            HStack {
                                Image(systemName: item == shape ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(item == shape ? Palette.accent : Palette.inkTertiary)
                                VStack(alignment: .leading) {
                                    Text(item.title).foregroundStyle(Palette.ink)
                                    Text(item.subtitle).font(Typography.caption).foregroundStyle(Palette.inkSecondary)
                                }
                                Spacer()
                                ShapeSparkline(shape: item)
                                    .frame(width: 74, height: 28)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section("Length") {
                    Picker("Target", selection: $duration) {
                        Text("All tracks").tag(TimeInterval?.none)
                        Text("About 30 minutes").tag(TimeInterval?.some(30 * 60))
                        Text("About 60 minutes").tag(TimeInterval?.some(60 * 60))
                        Text("About 90 minutes").tag(TimeInterval?.some(90 * 60))
                    }
                }
                if let plan {
                    Section("Preview") {
                        NavigationLink("Review \(plan.steps.count) tracks") {
                            MixPreviewView(plan: plan, rows: rows, sourcePlaylist: sourcePlaylist)
                        }
                    }
                }
            }
            .navigationTitle("Build a Mix")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isLoading ? "Generating…" : "Generate") { generate() }
                        .disabled(isLoading || rows.isEmpty)
                }
            }
            .task { await loadCandidates() }
        }
        .presentationDetents([.medium, .large])
    }

    @State private var candidates: [MixCandidate] = []

    private func loadCandidates() async {
        let ids = rows.compactMap(\.track.id)
        let info = (try? await appState.store.djLoadTrackInfo(trackIds: ids)) ?? [:]
        candidates = rows.compactMap { row in
            guard let id = row.track.id, let musical = info[id] else { return nil }
            return MixCandidate(trackID: id, bpm: musical.bpm, camelot: musical.camelotKey,
                                artist: row.artist?.name, albumID: row.album?.id,
                                duration: row.track.durationSec ?? 0)
        }
    }

    private func generate() {
        isLoading = true
        let request = MixRequest(candidates: candidates, shape: shape, targetDuration: duration,
                                 lockedFirst: lockedFirst,
                                 seed: UInt64(Date().timeIntervalSince1970))
        plan = MixPlanner.plan(request)
        isLoading = false
    }
}

struct MixPreviewView: View {
    @EnvironmentObject private var appState: AppState
    let rows: [TrackRow]
    let sourcePlaylist: Playlist?
    @State private var whyMix = false
    @State private var plan: MixPlan
    @State private var plainFadeEdges: Set<String> = []

    init(plan: MixPlan, rows: [TrackRow], sourcePlaylist: Playlist? = nil) {
        self.rows = rows
        self.sourcePlaylist = sourcePlaylist
        _plan = State(initialValue: plan)
    }

    private var rowByID: [Int64: TrackRow] { Dictionary(uniqueKeysWithValues: rows.compactMap { row in row.track.id.map { ($0, row) } }) }

    var body: some View {
        List {
            Section {
                MixArcChart(plan: plan)
                    .frame(height: 150)
                    .listRowBackground(Color.clear)
                Text(summary)
                    .font(Typography.callout)
                    .foregroundStyle(Palette.inkSecondary)
                Button("Why This Mix?") { whyMix = true }
            }
            Section("Order") {
                ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                    if index > 0 {
                        let edgeKey = "\(plan.steps[index - 1].trackID)-\(step.trackID)"
                        TransitionChip(plan: transitionPlan(at: index), onUsePlainFade: {
                            plainFadeEdges.insert(edgeKey)
                        })
                            .listRowSeparator(.hidden)
                    }
                    if let row = rowByID[step.trackID] {
                        MixTrackRow(row: row, step: step)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Remove", role: .destructive) { remove(step) }
                                Button("Lock") { lock(step) }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                if let runner = step.runnersUp.first {
                                    Button("Swap") { swap(step, with: runner) }
                                        .tint(Palette.accent)
                                }
                            }
                    }
                }
            }
            if !plan.excluded.isEmpty {
                Section("Not placed (\(plan.excluded.count))") {
                    ForEach(plan.excluded, id: \.trackID) { exclusion in
                        Label(rowByID[exclusion.trackID]?.track.title ?? "Track \(exclusion.trackID)",
                              systemImage: "questionmark.circle")
                            .foregroundStyle(Palette.inkSecondary)
                    }
                }
            }
        }
        .navigationTitle("Mix Preview")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Play") {
                        let ordered = plan.steps.compactMap { rowByID[$0.trackID] }
                        AudioPlayer.shared.play(tracks: ordered, startAt: 0, source: .library)
                    }
                    Button("Save as Playlist") { saveAsPlaylist() }
                    if let sourcePlaylist {
                        Button("Apply Order") { applyOrder(to: sourcePlaylist) }
                    }
                    Button("Regenerate") { plan = MixPlanner.plan(plan.request) }
                } label: {
                    Label("Mix actions", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $whyMix) { WhyThisMixView(plan: plan, rows: rows) }
    }

    private var summary: String {
        "\(plan.steps.count) tracks · \(Int(plan.summary.bpmRange.lowerBound.rounded()))–\(Int(plan.summary.bpmRange.upperBound.rounded())) BPM · \(plan.summary.harmonicEdges)/\(plan.summary.totalEdges) harmonic edges"
    }

    private func lock(_ step: MixStep) {
        plan.request.locks[step.trackID] = step.position
        plan = MixPlanner.plan(plan.request)
    }

    private func swap(_ step: MixStep, with runner: RunnerUp) {
        plan.request.locks[runner.trackID] = step.position
        plan = MixPlanner.plan(plan.request)
    }

    private func remove(_ step: MixStep) {
        plan.request.candidates.removeAll { $0.trackID == step.trackID }
        plan = MixPlanner.plan(plan.request)
    }

    private func saveAsPlaylist() {
        let ids = plan.steps.map(\.trackID)
        Task {
            await appState.createPlaylist(title: "Mix · \(plan.request.shape.title)",
                                          trackIds: ids, switchesTab: false)
            ToastCenter.shared.success("Mix saved as a playlist", icon: "checkmark.circle.fill")
        }
    }

    private func applyOrder(to playlist: Playlist) {
        guard let id = playlist.id else { return }
        let ids = plan.steps.map(\.trackID)
        Task {
            try? await appState.store.applyPlaylistOrder(id: id, orderedTrackIDs: ids)
            ToastCenter.shared.success("Playlist order updated", icon: "checkmark.circle.fill")
        }
    }

    private func transitionPlan(at index: Int) -> TransitionPlan? {
        guard index > 0, index < plan.steps.count else { return nil }
        let from = plan.steps[index - 1]
        let to = plan.steps[index]
        let edge = to.edgeIn
        var result = TransitionPlan(fromTrackID: from.trackID, toTrackID: to.trackID,
                              style: .phraseFade, overlapBeats: 8,
                              overlapSeconds: 4, blendRate: 1,
                              keyRelation: edge?.key ?? .unknown,
                              bpmDeltaPct: edge?.bpmDeltaPct,
                              confidence: edge == nil ? 0 : 0.65,
                              reasons: edge.map { [.keyCompatible($0.key)] } ?? [])
        if plainFadeEdges.contains("\(from.trackID)-\(to.trackID)") {
            result.style = .plainCrossfade
            result.reasons.append(.userChosePlainFade)
            result.overlapBeats = nil
            result.blendRate = 1
        }
        return result
    }
}

private struct MixTrackRow: View {
    let row: TrackRow
    let step: MixStep

    var body: some View {
        HStack(spacing: 12) {
            Text("\(step.position + 1)").font(Typography.mono).foregroundStyle(Palette.inkTertiary)
            VStack(alignment: .leading) {
                Text(row.track.title).font(Typography.body).lineLimit(1)
                Text(row.artist?.name ?? "Unknown artist").font(Typography.caption).foregroundStyle(Palette.inkSecondary)
            }
            Spacer()
            Text("\(Int(step.effectiveBPM.rounded())) BPM").font(Typography.mono)
            Text(step.edgeIn?.key.label ?? "—").font(Typography.mono).foregroundStyle(Palette.accent)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Position \(step.position + 1), \(row.track.title)")
        .accessibilityValue("\(Int(step.effectiveBPM.rounded())) BPM, \(step.edgeIn?.key.label ?? "no key")")
    }
}

private struct ShapeSparkline: View {
    let shape: MixShape
    var body: some View {
        Chart(Array(0..<8), id: \.self) { index in
            LineMark(x: .value("Position", index), y: .value("BPM", value(at: index)))
                .foregroundStyle(Palette.accent)
        }
        .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
    }
    private func value(at index: Int) -> Double {
        let x = Double(index) / 7
        switch shape {
        case .risingBPM: return x
        case .steady: return 0.5
        case .warmUpPeakCoolDown: return x < 0.7 ? x / 0.7 : 1 - (x - 0.7) / 0.3 * 0.5
        case .windDown: return 1 - x
        }
    }
}

private struct MixArcChart: View {
    let plan: MixPlan
    var body: some View {
        Chart(plan.steps) { step in
            LineMark(x: .value("Position", step.position), y: .value("BPM", step.effectiveBPM))
                .foregroundStyle(Palette.accent)
            PointMark(x: .value("Position", step.position), y: .value("BPM", step.effectiveBPM))
                .foregroundStyle(Palette.accent)
                .annotation(position: .top) { Text(step.edgeIn?.key.label ?? "") .font(Typography.caption) }
        }
        .chartYAxisLabel("BPM")
    }
}

private extension MixShape {
    var title: String {
        switch self { case .risingBPM: "Rising BPM"; case .steady: "Steady"; case .warmUpPeakCoolDown: "Warm up, peak, cool down"; case .windDown: "Wind down" }
    }
    var subtitle: String {
        switch self { case .risingBPM: "Build energy gradually"; case .steady: "Stay close to the median tempo"; case .warmUpPeakCoolDown: "Climb, peak, then release"; case .windDown: "Ease toward a calm finish" }
    }
}

private extension KeyRelation {
    var label: String {
        switch self { case .same: "same"; case .adjacentUp: "up"; case .adjacentDown: "down"; case .relative: "relative"; case .energyBoost: "boost"; case .clash(let steps): "clash \(steps)"; case .unknown: "unknown" }
    }
}
