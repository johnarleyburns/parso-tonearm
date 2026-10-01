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
    @State private var candidates: [MixCandidate] = []
    @State private var didLoadCandidates = false
    @State private var generationMessage: String?

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
                        if plan.steps.isEmpty {
                            Label(
                                generationMessage ?? "No compatible tracks were found yet.",
                                systemImage: "exclamationmark.circle"
                            )
                            .font(Typography.callout)
                            .foregroundStyle(Palette.inkSecondary)
                        } else {
                            NavigationLink("Review \(plan.steps.count) tracks") {
                                MixPreviewView(plan: plan, rows: rows, sourcePlaylist: sourcePlaylist)
                            }
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

    private func loadCandidates() async {
        let ids = rows.compactMap(\.track.id)
        let info = (try? await appState.store.djLoadTrackInfo(trackIds: ids)) ?? [:]
        // Keep unanalyzed rows in the request with nil metadata. MixPlanner
        // records them as explicit exclusions so the preview can explain and
        // act on them instead of silently shrinking the source pool.
        var loaded: [MixCandidate] = []
        for row in rows {
            guard let id = row.track.id else { continue }
            let musical = info[id]
            let analysis = try? await appState.store.discoveryTrackAnalysis(trackId: id)
            let embedding = try? await appState.store.discoveryEmbeddingVector(trackId: id)
            loaded.append(MixCandidate(trackID: id, bpm: musical?.bpm, camelot: musical?.camelotKey,
                                       energy: analysis?.energy, artist: row.artist?.name,
                                       albumID: row.album?.id, duration: row.track.durationSec ?? 0,
                                       embedding: embedding))
        }
        candidates = loaded
        didLoadCandidates = true
    }

    private func generate() {
        isLoading = true
        generationMessage = nil
        Task {
            // The source rows arrive before the async DJ/discovery metadata.
            // Previously a fast tap generated a plan from an empty candidate
            // array, left no preview to navigate to, and appeared to do
            // nothing. Finish the real load before planning.
            if !didLoadCandidates {
                await loadCandidates()
            }
            let request = MixRequest(candidates: candidates, shape: shape, targetDuration: duration,
                                     lockedFirst: lockedFirst,
                                     seed: UInt64(Date().timeIntervalSince1970))
            let generated = MixPlanner.plan(request)
            plan = generated
            if generated.steps.isEmpty {
                generationMessage = rows.isEmpty
                    ? "Add music to your library before building a mix."
                    : "No tracks have usable BPM and Camelot analysis yet. Prepare the Sound Index, then generate again."
            }
            isLoading = false
        }
    }
}

struct MixPreviewView: View {
    @EnvironmentObject private var appState: AppState
    let rows: [TrackRow]
    let sourcePlaylist: Playlist?
    @State private var whyMix = false
    @State private var plan: MixPlan
    @State private var plainFadeEdges: Set<String> = []
    @State private var transitionPayloads: [Int64: DJTrackPrepPayload] = [:]
    @State private var undoPlaylistID: Int64?
    @State private var undoPlaylistOrder: [Int64] = []
    @EnvironmentObject private var prep: TransitionPrepService

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
                        TransitionChip(
                            plan: transitionPlan(at: index),
                            onUsePlainFade: {
                                plainFadeEdges.insert(edgeKey)
                                Task { await resolveTransitionPlans() }
                                persistConfiguration()
                            },
                            onPrepareNow: {
                                let rowsToPrepare = [plan.steps[index - 1].trackID, step.trackID]
                                    .compactMap { rowByID[$0] }
                                prep.prepare(rows: rowsToPrepare, appState: appState)
                            },
                            onAudition: {
                                guard let auditionPlan = transitionPlan(at: index),
                                      let outgoing = rowByID[plan.steps[index - 1].trackID],
                                      let incoming = rowByID[step.trackID] else { return }
                                AudioPlayer.shared.auditionTransition(
                                    outgoing: outgoing, incoming: incoming, plan: auditionPlan)
                            },
                            outgoingPayload: transitionPayloads[plan.steps[index - 1].trackID],
                            incomingPayload: transitionPayloads[step.trackID],
                            preparationState: prep.transitionPrepState(for: step.trackID))
                            .listRowSeparator(.hidden)
                    }
                    if let row = rowByID[step.trackID] {
                        MixTrackRow(row: row, step: step, camelotLabel: camelotLabel(at: index))
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
                        VStack(alignment: .leading, spacing: 8) {
                            Label(rowByID[exclusion.trackID]?.track.title ?? "Unknown track",
                                  systemImage: "questionmark.circle")
                                .foregroundStyle(Palette.inkSecondary)
                            HStack {
                                Text(exclusion.reason.label)
                                    .font(Typography.caption)
                                    .foregroundStyle(Palette.inkTertiary)
                                Spacer()
                                if case .notAnalyzed = exclusion.reason,
                                   let row = rowByID[exclusion.trackID] {
                                    Button("Analyze now") {
                                        prep.prepare(rows: [row], appState: appState)
                                    }
                                }
                                Button("Add at end") { addAtEnd(exclusion) }
                                Button("Remove") { removeExclusion(exclusion) }
                            }
                            .font(Typography.caption)
                        }
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
                        AudioPlayer.shared.play(tracks: ordered, startAt: 0, source: .mix(plan))
                    }
                    Button("Save as Playlist") { saveAsPlaylist() }
                    if let sourcePlaylist {
                        Button("Apply Order") { applyOrder(to: sourcePlaylist) }
                    }
                    if undoPlaylistID != nil {
                        Button("Undo Apply Order") { undoApplyOrder() }
                    }
                    Button("Regenerate") {
                        var request = plan.request
                        request.seed &+= 1
                        plan = MixPlanner.plan(request)
                        Task { await resolveTransitionPlans() }
                        persistConfiguration()
                    }
                } label: {
                    Label("Mix actions", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $whyMix) {
            WhyThisMixView(plan: plan, rows: rows, sourcePlaylist: sourcePlaylist)
        }
        .task {
            await loadPersistedConfiguration()
            await resolveTransitionPlans()
        }
    }

    private var summary: String {
        "\(plan.steps.count) tracks · \(Int(plan.summary.bpmRange.lowerBound.rounded()))–\(Int(plan.summary.bpmRange.upperBound.rounded())) BPM · \(plan.summary.harmonicEdges)/\(plan.summary.totalEdges) harmonic edges"
    }

    private func lock(_ step: MixStep) {
        plan.request.locks[step.trackID] = step.position
        plan = MixPlanner.plan(plan.request)
        Task { await resolveTransitionPlans() }
        persistConfiguration()
    }

    private func swap(_ step: MixStep, with runner: RunnerUp) {
        plan.request.locks[runner.trackID] = step.position
        plan = MixPlanner.plan(plan.request)
        Task { await resolveTransitionPlans() }
        persistConfiguration()
    }

    private func remove(_ step: MixStep) {
        plan.request.candidates.removeAll { $0.trackID == step.trackID }
        plan = MixPlanner.plan(plan.request)
        Task { await resolveTransitionPlans() }
        persistConfiguration()
    }

    private func addAtEnd(_ exclusion: MixExclusion) {
        guard rowByID[exclusion.trackID] != nil else { return }
        let nextPosition = plan.steps.count
        let bpm = plan.request.candidates.first(where: { $0.trackID == exclusion.trackID })?.bpm ?? 0
        let step = MixStep(trackID: exclusion.trackID, position: nextPosition,
                           effectiveBPM: bpm,
                           reasons: [.onlyRemainingOption])
        plan.steps.append(step)
        plan.excluded.removeAll { $0.trackID == exclusion.trackID }
        persistConfiguration()
    }

    private func removeExclusion(_ exclusion: MixExclusion) {
        plan.excluded.removeAll { $0.trackID == exclusion.trackID }
        persistConfiguration()
    }

    private func camelotLabel(at index: Int) -> String {
        guard index > 0,
              let from = plan.request.candidates.first(where: { $0.trackID == plan.steps[index - 1].trackID })?.camelot,
              let to = plan.request.candidates.first(where: { $0.trackID == plan.steps[index].trackID })?.camelot else {
            return "Key unavailable"
        }
        return "\(DJKeyFormatter.format(from)) → \(DJKeyFormatter.format(to))"
    }

    private func saveAsPlaylist() {
        let ids = plan.steps.map(\.trackID)
        let savedPlan = plan
        let savedOverrides = plainFadeEdges
        Task {
            let playlist = await appState.createPlaylist(title: "Mix · \(savedPlan.request.shape.title)",
                                                         trackIds: ids, switchesTab: false)
            if let id = playlist?.id {
                persistConfiguration(for: id, plan: savedPlan, overrides: savedOverrides)
                ToastCenter.shared.success("Mix saved as a playlist", icon: "checkmark.circle.fill")
            } else {
                ToastCenter.shared.error("Could not save the mix", icon: "exclamationmark.triangle")
            }
        }
    }

    private func applyOrder(to playlist: Playlist) {
        guard let id = playlist.id else { return }
        let ids = plan.steps.map(\.trackID)
        Task {
            do {
                let original = try await appState.store.playlistTrackRows(playlistId: id).map(\.row.track.id).compactMap { $0 }
                try await appState.store.applyPlaylistOrder(id: id, orderedTrackIDs: ids)
                undoPlaylistID = id
                undoPlaylistOrder = original
                persistConfiguration()
                ToastCenter.shared.success("Playlist order updated", icon: "checkmark.circle.fill")
            } catch {
                ToastCenter.shared.error("Could not update playlist order", icon: "exclamationmark.triangle")
            }
        }
    }

    private func undoApplyOrder() {
        guard let id = undoPlaylistID, !undoPlaylistOrder.isEmpty else { return }
        let original = undoPlaylistOrder
        Task {
            do {
                try await appState.store.applyPlaylistOrder(id: id, orderedTrackIDs: original)
                undoPlaylistID = nil
                undoPlaylistOrder = []
                ToastCenter.shared.success("Playlist order restored", icon: "arrow.uturn.backward")
            } catch {
                ToastCenter.shared.error("Could not restore playlist order", icon: "exclamationmark.triangle")
            }
        }
    }

    private func transitionPlan(at index: Int) -> TransitionPlan? {
        guard index > 0, index < plan.steps.count else { return nil }
        let from = plan.steps[index - 1]
        let to = plan.steps[index]
        return plan.transitionPlans.first(where: {
            $0.fromTrackID == from.trackID && $0.toTrackID == to.trackID
        }) ?? makeTransitionPlan(from: from, to: to)
    }

    private func makeTransitionPlan(from: MixStep, to: MixStep) -> TransitionPlan {
        let fromRow = rowByID[from.trackID]
        let toRow = rowByID[to.trackID]
        let sameAlbumInOrder: Bool = {
            guard let fromRow, let toRow else { return false }
            return CrossfadeCurve.suppressesForGaplessAlbum(
                current: CrossfadeCurve.AlbumContinuity(row: fromRow),
                next: CrossfadeCurve.AlbumContinuity(row: toRow))
        }()
        let context = TonearmCore.TransitionPlanningContext(
            fromTrackID: from.trackID, toTrackID: to.trackID,
            fromDuration: fromRow?.track.durationSec ?? 0,
            toDuration: toRow?.track.durationSec ?? 0,
            sameAlbumInOrder: sameAlbumInOrder,
            userChosePlainFade: plainFadeEdges.contains("\(from.trackID)-\(to.trackID)"),
            prepState: transitionPayloads[from.trackID] != nil && transitionPayloads[to.trackID] != nil
                ? .ready : .notPrepared,
            incomingBuffered: transitionPayloads[to.trackID] != nil)
        return TonearmCore.TransitionPlanner.plan(from: transitionPayloads[from.trackID],
                                      to: transitionPayloads[to.trackID], context: context)
    }

    private func resolveTransitionPlans() async {
        var payloads: [Int64: DJTrackPrepPayload] = [:]
        for step in plan.steps {
            guard payloads[step.trackID] == nil else { continue }
            if let payload = try? await appState.store.transitionPrepPayload(trackId: step.trackID) {
                payloads[step.trackID] = payload
            }
        }
        transitionPayloads = payloads
        plan.transitionPlans = plan.steps.dropFirst().enumerated().map { offset, step in
            makeTransitionPlan(from: plan.steps[offset], to: step)
        }
        prep.prepare(rows: plan.steps.compactMap { rowByID[$0.trackID] }, appState: appState)
    }

    private func loadPersistedConfiguration() async {
        guard let playlistID = sourcePlaylist?.id else { return }
        guard let record = try? await appState.store.playlistMix(playlistId: playlistID) else { return }
        var request = plan.request
        request.shape = record.mixShape
        request.seed = record.unsignedSeed
        request.locks = (try? JSONDecoder().decode([Int64: Int].self,
                                                     from: record.lockedJSON)) ?? request.locks
        plan = MixPlanner.plan(request)
        let overrides = (try? JSONDecoder().decode([String: String].self,
                                                     from: record.transitionOverridesJSON)) ?? [:]
        plainFadeEdges = Set(overrides.compactMap { key, value in
            value == TransitionStyle.plainCrossfade.rawValue ? key : nil
        })
    }

    private func persistConfiguration(for playlistID: Int64? = nil,
                                      plan savedPlan: MixPlan? = nil,
                                      overrides: Set<String>? = nil) {
        guard let playlistID = playlistID ?? sourcePlaylist?.id else { return }
        let savedPlan = savedPlan ?? plan
        let overrides = overrides ?? plainFadeEdges
        guard let lockedJSON = try? JSONEncoder().encode(savedPlan.request.locks),
              let transitionOverridesJSON = try? JSONEncoder().encode(
                Dictionary(uniqueKeysWithValues: overrides.map {
                    ($0, TransitionStyle.plainCrossfade.rawValue)
                })) else { return }
        let record = PlaylistMixRecord(playlistId: playlistID, shape: savedPlan.request.shape,
                                       seed: savedPlan.request.seed, lockedJSON: lockedJSON,
                                       transitionOverridesJSON: transitionOverridesJSON)
        Task { try? await appState.store.savePlaylistMix(record) }
    }
}

private struct MixTrackRow: View {
    let row: TrackRow
    let step: MixStep
    let camelotLabel: String

    var body: some View {
        HStack(spacing: 12) {
            Text("\(step.position + 1)").font(Typography.mono).foregroundStyle(Palette.inkTertiary)
            VStack(alignment: .leading) {
                Text(row.track.title).font(Typography.body).lineLimit(1)
                Text(row.artist?.name ?? "Unknown artist").font(Typography.caption).foregroundStyle(Palette.inkSecondary)
            }
            Spacer()
            Text(step.effectiveBPM > 0 ? "\(Int(step.effectiveBPM.rounded())) BPM" : "BPM unavailable")
                .font(Typography.mono)
            Text(camelotLabel).font(Typography.mono).foregroundStyle(Palette.accent)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Position \(step.position + 1), \(row.track.title)")
        .accessibilityValue(step.effectiveBPM > 0
                            ? "\(Int(step.effectiveBPM.rounded())) BPM, \(camelotLabel)"
                            : "BPM unavailable, \(camelotLabel)")
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
        Chart {
            ForEach(plan.steps) { step in
            LineMark(x: .value("Position", step.position), y: .value("BPM", step.effectiveBPM))
                .foregroundStyle(Palette.accent)
            PointMark(x: .value("Position", step.position), y: .value("BPM", step.effectiveBPM))
                .foregroundStyle(Palette.accent)
                .annotation(position: .top) { Text(step.edgeIn?.key.label ?? "") .font(Typography.caption) }
            }
            ForEach(plan.steps.compactMap { step -> (Int, Double)? in
                guard let energy = plan.request.candidates.first(where: { $0.trackID == step.trackID })?.energy else { return nil }
                return (step.position, energy)
            }, id: \.0) { position, energy in
                LineMark(x: .value("Position", position), y: .value("Energy", energyValue(energy)), series: .value("Series", "Energy"))
                    .foregroundStyle(Palette.success)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                PointMark(x: .value("Position", position), y: .value("Energy", energyValue(energy)))
                    .foregroundStyle(Palette.success)
            }
        }
        .chartYAxisLabel("BPM")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mix tempo and energy arc")
        .accessibilityValue(chartDescription)
    }

    private var chartDescription: String {
        let tempo = plan.steps.map { Int($0.effectiveBPM.rounded()) }
        let energies = plan.steps.compactMap { step in
            plan.request.candidates.first(where: { $0.trackID == step.trackID })?.energy
        }
        let energyText = energies.isEmpty ? "Energy is unavailable." : "Energy ranges from \(Int((energies.min() ?? 0) * 100)) to \(Int((energies.max() ?? 0) * 100)) percent."
        return "Tempo runs \(tempo.map(String.init).joined(separator: ", ")) BPM. \(energyText)"
    }

    private func energyValue(_ energy: Double) -> Double {
        let lower = plan.summary.bpmRange.lowerBound
        let upper = max(lower + 1, plan.summary.bpmRange.upperBound)
        return lower + min(max(energy, 0), 1) * (upper - lower)
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
        switch self {
        case .same: "same key"
        case .adjacentUp: "one Camelot step up"
        case .adjacentDown: "one Camelot step down"
        case .relative: "relative major/minor"
        case .energyBoost: "energy lift"
        case .clash(let steps): "key clash, \(steps) steps apart"
        case .unknown: "unknown key relationship"
        }
    }
}
