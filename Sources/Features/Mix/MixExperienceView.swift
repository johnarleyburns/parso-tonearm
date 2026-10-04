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
    /// Build a Mix from Listen picks its own source (a random genre, else a playlist not used in
    /// the last 10 mixes, else the library). Other entry points mix the tracks they were given.
    let picksSource: Bool
    @State private var source: MixSource = .given
    /// Build a Mix from Listen: what to mix from. Genre (default; "Surprise me" picks one), one of
    /// your playlists, or all tracks.
    enum SourceChoice: String, CaseIterable, Identifiable {
        case genre, playlist, allTracks
        var id: String { rawValue }
    }
    @State private var sourceChoice: SourceChoice = .genre
    /// nil = Surprise me (a random genre that can fill the session, else an unused playlist, else
    /// the library).
    @State private var chosenGenre: String?
    @State private var chosenPlaylistID: Int64?
    @State private var shape: MixShape = .steady
    /// A mix is a listening session, not the whole library: 15, 30 or 60 minutes.
    @State private var duration: TimeInterval = 30 * 60
    @State private var plan: MixPlan?
    @State private var isLoading = false
    @State private var candidates: [MixCandidate] = []
    @State private var didLoadCandidates = false
    @State private var generationMessage: String?
    @State private var showingPreview = false
    @State private var detent: PresentationDetent = .medium

    init(rows: [TrackRow], lockedFirst: Int64? = nil, sourcePlaylist: Playlist? = nil,
         picksSource: Bool = false) {
        self.rows = rows
        self.lockedFirst = lockedFirst
        self.sourcePlaylist = sourcePlaylist
        self.picksSource = picksSource
    }

    var body: some View {
        NavigationStack {
            Form {
                // The result goes first: the sheet opens at half height, and a result appended
                // below the fold made Generate look like it did nothing.
                if let plan, plan.steps.isEmpty {
                    Section {
                        Label(
                            generationMessage ?? String(localized: "No compatible tracks were found yet."),
                            systemImage: "exclamationmark.circle"
                        )
                        .font(Typography.callout)
                        .foregroundStyle(Palette.inkSecondary)
                        .accessibilityIdentifier("mix.builder.message")
                    }
                } else if let plan {
                    Section {
                        Button("Review \(plan.steps.count) tracks") { showingPreview = true }
                            .accessibilityIdentifier("mix.builder.review")
                    }
                }
                Section("Source") {
                    if picksSource {
                        Picker("From", selection: $sourceChoice) {
                            Text("Genre").tag(SourceChoice.genre)
                            Text("Playlist").tag(SourceChoice.playlist)
                            Text("All tracks").tag(SourceChoice.allTracks)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("mix.builder.sourceChoice")
                        switch sourceChoice {
                        case .genre:
                            Picker("Genre", selection: $chosenGenre) {
                                Text("Surprise me").tag(String?.none)
                                ForEach(genreChoices, id: \.name) { choice in
                                    Text("\(choice.name) · \(choice.count)").tag(String?.some(choice.name))
                                }
                            }
                            .accessibilityIdentifier("mix.builder.genre")
                        case .playlist:
                            if mixablePlaylists.isEmpty {
                                Text("You don't have any playlists yet.")
                                    .font(Typography.caption)
                                    .foregroundStyle(Palette.inkSecondary)
                            } else {
                                Picker("Playlist", selection: $chosenPlaylistID) {
                                    ForEach(mixablePlaylists, id: \.id) { playlist in
                                        Text(playlist.title).tag(playlist.id)
                                    }
                                }
                                .accessibilityIdentifier("mix.builder.playlist")
                            }
                        case .allTracks:
                            LabeledContent("Tracks", value: "\(rows.count)")
                                .accessibilityIdentifier("mix.builder.trackCount")
                        }
                    } else {
                        LabeledContent("Tracks", value: "\(rows.count)")
                            .accessibilityIdentifier("mix.builder.trackCount")
                    }
                    sourceExplanation
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkSecondary)
                }
                Section {
                    Label("Reference tempo: fastest track · key preserved", systemImage: "metronome")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkSecondary)
                }
                Section("Length") {
                    Picker("Target", selection: $duration) {
                        Text("About 15 minutes").tag(TimeInterval(15 * 60))
                        Text("About 30 minutes").tag(TimeInterval(30 * 60))
                        Text("About 60 minutes").tag(TimeInterval(60 * 60))
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
            .navigationDestination(isPresented: $showingPreview) {
                if let plan {
                    // Playing closes Build a Mix so the mix is in the player, not behind a sheet.
                    MixPreviewView(plan: plan, rows: rows, sourcePlaylist: sourcePlaylist, source: source,
                                   onPlay: { dismiss() })
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
    }

    private var genreByTrack: [Int64: String] {
        Dictionary(rows.compactMap { row in
            row.track.id.map { ($0, row.track.genre?.trimmingCharacters(in: .whitespaces) ?? "") }
        }, uniquingKeysWith: { first, _ in first })
    }

    /// Genres with tracks that can be mixed (analysed tempo and key), most first.
    private var genreChoices: [(name: String, count: Int)] {
        let genres = genreByTrack
        var counts: [String: Int] = [:]
        for candidate in candidates where (candidate.bpm ?? 0) > 0 && MixCompatibility.isCamelot(candidate.camelot ?? "") {
            if let genre = genres[candidate.trackID], !genre.isEmpty { counts[genre, default: 0] += 1 }
        }
        return counts.map { ($0.key, $0.value) }
            .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
    }

    private var mixablePlaylists: [Playlist] {
        appState.playlists.filter { $0.id != nil }
    }

    @ViewBuilder
    private var sourceExplanation: some View {
        if !picksSource {
            Text("Each track stays within 8% of the last one's tempo, in a matching key.")
        } else {
            switch sourceChoice {
            case .genre where chosenGenre == nil:
                Text("Platterhead picks one genre at random — or a playlist you haven't mixed lately — and chains tracks that each stay within 8% of the last one's tempo, in a matching key.")
            case .genre:
                Text("Tracks from this genre, each within 8% of the last one's tempo, in a matching key.")
            case .playlist:
                Text("Tracks from this playlist, each within 8% of the last one's tempo, in a matching key.")
            case .allTracks:
                Text("Starts from a random track in your library; each next track stays within 8% of the last one's tempo, in a matching key.")
            }
        }
    }

    private func loadCandidates() async {
        let ids = rows.compactMap(\.track.id)
        let info = (try? await appState.store.djLoadTrackInfo(trackIds: ids)) ?? [:]
        // Keep unanalyzed rows in the request with nil metadata. MixPlanner
        // records them as explicit exclusions so the preview can explain and
        // act on them instead of silently shrinking the source pool.
        let energies = (try? await appState.store.discoveryEnergies(trackIds: ids)) ?? [:]
        let embeddings = (try? await appState.store.discoveryEmbeddingVectors(trackIds: ids)) ?? [:]
        var loaded: [MixCandidate] = []
        loaded.reserveCapacity(rows.count)
        for row in rows {
            guard let id = row.track.id else { continue }
            let musical = info[id]
            loaded.append(MixCandidate(trackID: id, bpm: musical?.bpm, camelot: musical?.camelotKey,
                                       energy: energies[id], artist: row.artist?.name,
                                       albumID: row.album?.id, duration: row.track.durationSec ?? 0,
                                       embedding: embeddings[id]))
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
            let seed = UInt64(Date().timeIntervalSince1970 * 1_000)
            let generated: MixPlan
            if picksSource {
                let genres = genreByTrack
                let membership = (try? await appState.store.playlistTrackIDs()) ?? [:]
                let inputs = (candidates, shape, duration)
                switch sourceChoice {
                case .genre where chosenGenre == nil:
                    let playlists = appState.playlists.compactMap { playlist -> MixSourcePicker.Playlist? in
                        guard let id = playlist.id else { return nil }
                        return MixSourcePicker.Playlist(id: id, title: playlist.title, trackIDs: membership[id] ?? [])
                    }
                    let recent = MixHistory.recentSources
                    // The pick plans several pools; keep it off the main thread.
                    let picked = await Task.detached(priority: .userInitiated) {
                        MixSourcePicker.pick(candidates: inputs.0, genres: genres, playlists: playlists,
                                             recentSources: recent, shape: inputs.1,
                                             targetDuration: inputs.2, seed: seed)
                    }.value
                    source = picked.source
                    generated = picked.plan
                case .genre:
                    let genre = chosenGenre ?? ""
                    let pool = inputs.0.filter { genres[$0.trackID] == genre }
                    generated = await Task.detached(priority: .userInitiated) {
                        MixSourcePicker.plan(pool: pool, shape: inputs.1, targetDuration: inputs.2, seed: seed)
                    }.value
                    source = .genre(genre)
                case .playlist:
                    let playlist = mixablePlaylists.first { $0.id == chosenPlaylistID } ?? mixablePlaylists.first
                    let ids = playlist.flatMap { $0.id }.map { membership[$0] ?? [] } ?? []
                    let byID = Dictionary(inputs.0.map { ($0.trackID, $0) }, uniquingKeysWith: { first, _ in first })
                    let pool = ids.compactMap { byID[$0] }
                    generated = await Task.detached(priority: .userInitiated) {
                        MixSourcePicker.plan(pool: pool, shape: inputs.1, targetDuration: inputs.2, seed: seed)
                    }.value
                    source = playlist.flatMap { p in p.id.map { MixSource.playlist(id: $0, title: p.title) } } ?? .given
                case .allTracks:
                    generated = await Task.detached(priority: .userInitiated) {
                        MixSourcePicker.plan(pool: inputs.0, shape: inputs.1, targetDuration: inputs.2, seed: seed)
                    }.value
                    source = .library
                }
                if !generated.steps.isEmpty { MixHistory.record(source) }
            } else {
                let request = MixRequest(candidates: candidates, shape: shape, targetDuration: duration,
                                         lockedFirst: lockedFirst, seed: seed, compatibility: .standard)
                // The planner compares every pair of tracks; keep that off the main thread.
                generated = await Task.detached(priority: .userInitiated) { MixPlanner.plan(request) }.value
                source = sourcePlaylist.flatMap { playlist in
                    playlist.id.map { MixSource.playlist(id: $0, title: playlist.title) }
                } ?? .given
                if !generated.steps.isEmpty { MixHistory.record(source) }
            }
            plan = generated
            // Show the outcome where it can be seen: the full-height sheet, and the preview itself
            // when there is a mix.
            detent = .large
            if !generated.steps.isEmpty { showingPreview = true }
            if generated.steps.isEmpty {
                generationMessage = rows.isEmpty
                    ? String(localized: "Add music to your library before building a mix.")
                    : String(localized: "No tracks have usable BPM and Camelot analysis yet. Prepare the Sound Index, then generate again.")
            }
            isLoading = false
        }
    }
}

/// The last few Build a Mix sources on this device ("not a playlist used in the past 10 mixes").
enum MixHistory {
    private static let key = "mix.recentSources"

    static var recentSources: [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func record(_ source: MixSource) {
        guard let entry = source.historyKey else { return }
        var recent = recentSources.filter { $0 != entry }
        recent.append(entry)
        UserDefaults.standard.set(Array(recent.suffix(MixSourcePicker.recentLimit)), forKey: key)
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

    let source: MixSource
    private let onPlay: (() -> Void)?

    init(plan: MixPlan, rows: [TrackRow], sourcePlaylist: Playlist? = nil, source: MixSource = .given,
         onPlay: (() -> Void)? = nil) {
        self.onPlay = onPlay
        self.rows = rows
        self.sourcePlaylist = sourcePlaylist
        self.source = source
        self.rowByID = Dictionary(rows.compactMap { row in row.track.id.map { ($0, row) } },
                                  uniquingKeysWith: { first, _ in first })
        _plan = State(initialValue: plan)
    }

    /// Built once: it's read several times per row, and rebuilding it each time made a large mix's
    /// preview quadratic on the main thread.
    private let rowByID: [Int64: TrackRow]

    var body: some View {
        List {
            Section {
                if let sourceLine {
                    Label(sourceLine, systemImage: "music.note.list")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.inkSecondary)
                        .accessibilityIdentifier("mix.preview.source")
                }
                Button(action: playMix) {
                    Label("Play Mix", systemImage: "play.fill")
                        .font(Typography.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
                .disabled(plan.steps.isEmpty)
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("mix.preview.play")
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
                                prep.prepare(rows: rowsToPrepare, appState: appState, allowsCellular: true)
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
                            preparationState: preparationState(for: step.trackID))
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
        }
        .navigationTitle("Mix for You")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
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
                        replan(request)
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

    /// Re-plans off the main thread: the solve is quadratic, and a whole-library mix would
    /// otherwise freeze the preview for seconds.
    private func replan(_ request: MixRequest) {
        Task {
            plan = await Task.detached(priority: .userInitiated) { MixPlanner.plan(request) }.value
            persistConfiguration()
            await resolveTransitionPlans()
        }
    }

    private func lock(_ step: MixStep) {
        plan.request.locks[step.trackID] = step.position
        replan(plan.request)
    }

    private func swap(_ step: MixStep, with runner: RunnerUp) {
        plan.request.locks[runner.trackID] = step.position
        replan(plan.request)
    }

    private func remove(_ step: MixStep) {
        plan.request.candidates.removeAll { $0.trackID == step.trackID }
        replan(plan.request)
    }

    private func camelotLabel(at index: Int) -> String {
        let code = { (step: MixStep) in candidateByID[step.trackID]?.camelot }
        // The first track has no transition in, but it does have a key.
        guard index > 0 else {
            return code(plan.steps[index]).map(DJKeyFormatter.format) ?? String(localized: "Key unavailable")
        }
        guard let from = code(plan.steps[index - 1]), let to = code(plan.steps[index]) else {
            return String(localized: "Key unavailable")
        }
        return "\(DJKeyFormatter.format(from)) → \(DJKeyFormatter.format(to))"
    }

    private var candidateByID: [Int64: MixCandidate] {
        Dictionary(plan.request.candidates.map { ($0.trackID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func playMix() {
        let ordered = plan.steps.compactMap { rowByID[$0.trackID] }
        guard !ordered.isEmpty else { return }
        AudioPlayer.shared.play(tracks: ordered, startAt: 0, source: .mix(plan))
        onPlay?()
    }

    private var sourceLine: String? {
        switch source {
        case .genre(let name): String(localized: "From \(name)")
        case .playlist(_, let title): String(localized: "From your playlist “\(title)”")
        case .library: String(localized: "From your whole library")
        case .given: nil
        }
    }

    private func saveAsPlaylist() {
        let ids = plan.steps.map(\.trackID)
        let savedPlan = plan
        let savedOverrides = plainFadeEdges
        Task {
            let playlist = await appState.createPlaylist(title: String(localized: "Mix · \(savedPlan.request.shape.title)"),
                                                         trackIds: ids, switchesTab: false)
            if let id = playlist?.id {
                persistConfiguration(for: id, plan: savedPlan, overrides: savedOverrides)
                ToastCenter.shared.success(String(localized: "Mix saved as a playlist"), icon: "checkmark.circle.fill")
            } else {
                ToastCenter.shared.error(String(localized: "Could not save the mix"), icon: "exclamationmark.triangle")
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
                ToastCenter.shared.success(String(localized: "Playlist order updated"), icon: "checkmark.circle.fill")
            } catch {
                ToastCenter.shared.error(String(localized: "Could not update playlist order"), icon: "exclamationmark.triangle")
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
                ToastCenter.shared.success(String(localized: "Playlist order restored"), icon: "arrow.uturn.backward")
            } catch {
                ToastCenter.shared.error(String(localized: "Could not restore playlist order"), icon: "exclamationmark.triangle")
            }
        }
    }

    /// A track whose payload is already loaded (prepared earlier, or shipped in the starter DB) is
    /// ready, even outside the small window the prep service is working through.
    private func preparationState(for trackID: Int64) -> GridPrepState {
        if let payload = transitionPayloads[trackID],
           payload.algorithmID == DJTrackPrepPayload.currentAlgorithmID,
           payload.version == DJTrackPrepPayload.currentVersion {
            return .ready
        }
        return prep.transitionPrepState(for: trackID)
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

    private static let prepWindow = 6

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
        // Prepare the opening transitions only — the prep service is a small, visible window, and
        // Up Next prepares the rest as playback reaches it. Handing it a whole-library mix queued
        // thousands of downloads and decodes.
        prep.prepare(rows: plan.steps.prefix(Self.prepWindow).compactMap { rowByID[$0.trackID] },
                     appState: appState, allowsCellular: true)
    }

    private func loadPersistedConfiguration() async {
        guard let playlistID = sourcePlaylist?.id else { return }
        guard let record = try? await appState.store.playlistMix(playlistId: playlistID) else { return }
        var request = plan.request
        request.shape = record.mixShape
        request.seed = record.unsignedSeed
        request.locks = (try? JSONDecoder().decode([Int64: Int].self,
                                                     from: record.lockedJSON)) ?? request.locks
        plan = await Task.detached(priority: .userInitiated) { MixPlanner.plan(request) }.value
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
                Text(row.artist?.name ?? String(localized: "Unknown artist")).font(Typography.caption).foregroundStyle(Palette.inkSecondary)
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
        let energyByID = Dictionary(plan.request.candidates.compactMap { candidate in
            candidate.energy.map { (candidate.trackID, $0) } }, uniquingKeysWith: { first, _ in first })
        // Points and key labels read for a normal mix; a library-sized mix draws the lines only.
        let detailed = plan.steps.count <= 60
        Chart {
            ForEach(plan.steps) { step in
            LineMark(x: .value("Position", step.position), y: .value("BPM", step.effectiveBPM))
                .foregroundStyle(Palette.accent)
            if detailed {
                PointMark(x: .value("Position", step.position), y: .value("BPM", step.effectiveBPM))
                    .foregroundStyle(Palette.accent)
                    .annotation(position: .top) { Text(step.edgeIn?.key.label ?? "") .font(Typography.caption) }
            }
            }
            ForEach(plan.steps.compactMap { step -> (Int, Double)? in
                guard let energy = energyByID[step.trackID] else { return nil }
                return (step.position, energy)
            }, id: \.0) { position, energy in
                LineMark(x: .value("Position", position), y: .value("Energy", energyValue(energy)), series: .value("Series", "Energy"))
                    .foregroundStyle(Palette.success)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                if detailed {
                    PointMark(x: .value("Position", position), y: .value("Energy", energyValue(energy)))
                        .foregroundStyle(Palette.success)
                }
            }
        }
        .chartYAxisLabel("BPM")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mix tempo and energy arc")
        .accessibilityChartDescriptor(MixArcChartDescriptor(plan: plan))
        .accessibilityValue(chartDescription)
    }

    private var chartDescription: String {
        let tempo = plan.steps.map { Int($0.effectiveBPM.rounded()) }
        let energies = plan.steps.compactMap { step in
            plan.request.candidates.first(where: { $0.trackID == step.trackID })?.energy
        }
        let energyText = energies.isEmpty ? String(localized: "Energy is unavailable.") : String(localized: "Energy ranges from \(Int((energies.min() ?? 0) * 100)) to \(Int((energies.max() ?? 0) * 100)) percent.")
        return String(localized: "Tempo runs \(tempo.map(String.init).joined(separator: ", ")) BPM. \(energyText)")
    }

    private func energyValue(_ energy: Double) -> Double {
        let lower = plan.summary.bpmRange.lowerBound
        let upper = max(lower + 1, plan.summary.bpmRange.upperBound)
        return lower + min(max(energy, 0), 1) * (upper - lower)
    }
}

private extension MixShape {
    var title: String {
        switch self { case .risingBPM: String(localized: "Rising BPM"); case .steady: String(localized: "Steady"); case .warmUpPeakCoolDown: String(localized: "Warm up, peak, cool down"); case .windDown: String(localized: "Wind down") }
    }
    var subtitle: String {
        switch self { case .risingBPM: String(localized: "Build energy gradually"); case .steady: String(localized: "Stay close to the median tempo"); case .warmUpPeakCoolDown: String(localized: "Climb, peak, then release"); case .windDown: String(localized: "Ease toward a calm finish") }
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
