import SwiftUI
import TonearmCore
import TonearmDiscovery

/// Entry row shared by Listen and My Music.
struct BlendLabEntryButton: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Button { appState.showBlendLab = true } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "wand.and.stars").foregroundStyle(Palette.accent)
                    .font(Typography.title)
                    .accessibilityHidden(true)
                Text("Blend Lab").font(Typography.headline)
                Text("Create, preview, edit and save a blend.")
                    .font(Typography.caption).foregroundStyle(Palette.inkSecondary).lineLimit(2)
            }
            .padding(12)
            .frame(width: 250, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens Blend Lab")
        .accessibilityIdentifier("blendlab.entry")
    }
}

/// The production generator: the real mix planner over the library's analysed
/// metadata. It throws when the planner has nothing to chain (for example no
/// BPM/key analysis yet), which makes the session fall back to a basic mix.
enum BlendLabGenerator {
    static func generate(store: LibraryStore, library: [TrackRow],
                         request: BlendLabRequest) async throws -> BlendLabGeneration {
        let library = request.allowedTrackIDs.map { allowed in
            library.filter { $0.track.id.map(allowed.contains) ?? false }
        } ?? library
        let ids = library.compactMap(\.track.id)
        let info = (try? await store.djLoadTrackInfo(trackIds: ids)) ?? [:]
        let energies = (try? await store.discoveryEnergies(trackIds: ids)) ?? [:]
        let candidates = library.compactMap { row -> MixCandidate? in
            guard let id = row.track.id else { return nil }
            let m = info[id]
            if let range = request.bpmRange, !(m?.bpm.map(range.contains) ?? false) { return nil }
            return MixCandidate(trackID: id, bpm: m?.bpm, camelot: m?.camelotKey, energy: energies[id],
                                artist: row.artist?.name, albumID: row.album?.id,
                                duration: row.track.durationSec ?? 0)
        }
        let mix = MixRequest(candidates: candidates, shape: request.shape,
                             targetDuration: TimeInterval(request.targetTrackCount) * 240,
                             lockedFirst: request.seedTrackIDs.first,
                             seed: UInt64(Date().timeIntervalSince1970 * 1_000),
                             compatibility: .standard)
        let plan = await Task.detached(priority: .userInitiated) { MixPlanner.plan(mix) }.value
        let byID = Dictionary(library.compactMap { r in r.track.id.map { ($0, r) } },
                              uniquingKeysWith: { first, _ in first })
        let rows = plan.steps.compactMap { byID[$0.trackID] }
        guard rows.count > 1 else { throw CocoaError(.featureUnsupported) }
        return BlendLabGeneration(rows: rows, plan: plan, isBasicMix: false)
    }
}

struct BlendLabView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: BlendLabSession
    @State private var count = 10
    @State private var scope: BlendLabScope = .all
    @State private var genre: String?
    @State private var playlistID: Int64?
    @State private var playlistTracks: [Int64: [Int64]] = [:]
    @State private var minimumBPM = 80.0
    @State private var maximumBPM = 160.0
    @State private var shape: MixShape = .steady
    @State private var replacing: ReplaceTarget?
    @State private var title = ""

    init(appState: AppState) {
        let store = appState.store
        _session = StateObject(wrappedValue: BlendLabSession(
            generate: { request in
                let library = await MainActor.run { appState.allTracks }
                return try await BlendLabGenerator.generate(store: store, library: library, request: request)
            },
            library: { appState.allTracks },
            repository: appState.blendRepository,
            play: { rows in AudioPlayer.shared.play(tracks: rows, startAt: 0, source: .none) }))
    }

    var body: some View {
        NavigationStack {
            List {
                createSection
                statusSection
                if session.document != nil { resultSections }
            }
            .navigationTitle("Blend Lab")
            .task { playlistTracks = (try? await appState.store.playlistTrackIDs()) ?? [:] }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { session.cancel(); dismiss() }
                        .accessibilityIdentifier("blendlab.close")
                }
            }
            .sheet(item: $replacing) { target in
                ReplacePicker(candidates: session.replacementCandidates()) { row in
                    session.replace(occurrenceID: target.id, with: row)
                }
            }
        }
        .onDisappear { session.cancel() }
    }

    private var createSection: some View {
        Section("Create") {
            Picker("Source", selection: $scope) {
                Text("Genre").tag(BlendLabScope.genre)
                Text("Playlists").tag(BlendLabScope.playlist)
                Text("All").tag(BlendLabScope.all)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("blendlab.scope")
            switch scope {
            case .genre:
                Picker("Genre", selection: $genre) {
                    Text("Choose a genre").tag(String?.none)
                    ForEach(BlendLabScope.genres(in: appState.allTracks), id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .accessibilityIdentifier("blendlab.genre")
            case .playlist:
                Picker("Playlist", selection: $playlistID) {
                    Text("Choose a playlist").tag(Int64?.none)
                    ForEach(appState.playlists, id: \.id) { Text($0.title).tag($0.id) }
                }
                .accessibilityIdentifier("blendlab.playlist")
            case .all:
                VStack(alignment: .leading) {
                    Stepper("Minimum BPM: \(Int(minimumBPM))", value: $minimumBPM, in: 0...400, step: 1)
                        .accessibilityIdentifier("blendlab.bpm.min")
                    Stepper("Maximum BPM: \(Int(maximumBPM))", value: $maximumBPM, in: 0...400, step: 1)
                        .accessibilityIdentifier("blendlab.bpm.max")
                }
                .accessibilityIdentifier("blendlab.bpm")
            }
            Picker("Mood", selection: $shape) {
                Text("Steady").tag(MixShape.steady)
                Text("Rising energy").tag(MixShape.risingBPM)
                Text("Warm up, peak, cool down").tag(MixShape.warmUpPeakCoolDown)
                Text("Wind down").tag(MixShape.windDown)
            }
            .accessibilityIdentifier("blendlab.shape")
            Stepper("Tracks: \(clampedCount)", value: Binding(get: { clampedCount }, set: { count = $0 }),
                    in: BlendLabScope.minTracks...max(BlendLabScope.minTracks, maxCount))
                .accessibilityIdentifier("blendlab.count")
            if session.phase == .generating {
                Button("Cancel", role: .cancel) { session.cancel() }
                    .accessibilityIdentifier("blendlab.cancel")
            } else {
                Button(session.document == nil ? "Generate" : "Regenerate") { generate() }
                    .accessibilityIdentifier("blendlab.generate")
                    .disabled(!canGenerate)
            }
            if let reason = unavailableReason {
                Text(reason).font(Typography.caption).foregroundStyle(Palette.inkSecondary)
                    .accessibilityIdentifier("blendlab.unavailable")
            }
        }
    }

    @ViewBuilder private var statusSection: some View {
        switch session.phase {
        case .generating:
            Section { ProgressView("Building your blend…").accessibilityIdentifier("blendlab.progress") }
        case .failed(let text):
            Section {
                Label(text, systemImage: "exclamationmark.triangle").foregroundStyle(Palette.danger)
                    .accessibilityIdentifier("blendlab.error")
                Button("Try again") { generate() }
            }
        default:
            if let message = session.message {
                Section { Text(message).font(Typography.caption)
                    .foregroundStyle(Palette.inkSecondary).accessibilityIdentifier("blendlab.message") }
            }
        }
    }

    private var resultSections: some View {
        Group {
            Section("Preview") {
                let items = session.orderedRows
                ForEach(Array(items.enumerated()), id: \.element.occurrenceID) { index, item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.row.track.title)
                        Text(item.row.artist?.name ?? "").font(Typography.caption)
                            .foregroundStyle(Palette.inkSecondary)
                        if index < items.count - 1 { edgeLabel(after: item.occurrenceID) }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAction(named: Text("Play from here")) { session.playPreview(from: index) }
                    .accessibilityAction(named: Text("Replace")) { replacing = ReplaceTarget(id: item.occurrenceID) }
                    .accessibilityAction(named: Text("Remove")) { session.remove(occurrenceID: item.occurrenceID) }
                    .swipeActions {
                        Button("Remove", role: .destructive) { session.remove(occurrenceID: item.occurrenceID) }
                        Button("Replace") { replacing = ReplaceTarget(id: item.occurrenceID) }.tint(Palette.accent)
                    }
                    .contextMenu {
                        Button("Play from here") { session.playPreview(from: index) }
                        Button("Replace…") { replacing = ReplaceTarget(id: item.occurrenceID) }
                        if index < items.count - 1 {
                            let off = isNoBlend(after: item.occurrenceID)
                            Button(off ? "Restore automatic blend" : "No blend after this track") {
                                session.setNoBlend(afterOccurrence: item.occurrenceID, !off)
                            }
                        }
                    }
                }
                .onMove { session.move(from: $0, to: $1) }
                .onDelete { offsets in
                    let ids = offsets.map { items[$0].occurrenceID }
                    ids.forEach { session.remove(occurrenceID: $0) }
                }
            }
            Section {
                Button("Play") { session.playPreview() }.accessibilityIdentifier("blendlab.play")
                TextField("Name", text: $title).accessibilityIdentifier("blendlab.name")
                Button(session.savedID == nil ? "Save Blend" : "Saved") {
                    Task { await session.save(title: title) }
                }
                .disabled(session.savedID != nil)
                .accessibilityIdentifier("blendlab.save")
            }
        }
    }

    private func isNoBlend(after id: UUID) -> Bool {
        session.document?.requestedIntent(afterOccurrence: id) == BlendLabSession.noBlendStyle
    }

    private func edgeLabel(after id: UUID) -> some View {
        let style = session.document?.requestedIntent(afterOccurrence: id)
        let text: LocalizedStringKey = style == BlendLabSession.noBlendStyle
            ? "→ No blend" : (style == nil ? "→ Automatic blend" : "→ Requested blend")
        return Text(text).font(Typography.caption).foregroundStyle(Palette.inkSecondary)
    }

    /// Track ids the chosen genre/playlist allows; nil for All (nothing chosen yet → empty).
    private var scopedIDs: Set<Int64>? {
        switch scope {
        case .all: return nil
        case .genre:
            return genre.map { BlendLabScope.trackIDs(genre: $0, in: appState.allTracks) } ?? []
        case .playlist:
            let inLibrary = Set(appState.allTracks.compactMap(\.track.id))
            return Set((playlistID.flatMap { playlistTracks[$0] } ?? []).filter(inLibrary.contains))
        }
    }

    private var isValidBPMRange: Bool { BlendLabScope.isValidBPMRange(lower: minimumBPM, upper: maximumBPM) }

    private var bpmRange: ClosedRange<Double>? {
        scope == .all && isValidBPMRange ? minimumBPM...maximumBPM : nil
    }

    private var eligibleCount: Int {
        let bpmByID = appState.musicalInfo.compactMapValues(\.bpm)
        return BlendLabScope.eligibleIDs(allowed: scopedIDs, library: appState.allTracks,
                                         bpm: bpmRange, bpmByID: bpmByID).count
    }

    private var canGenerate: Bool {
        !appState.allTracks.isEmpty && (scope != .all || isValidBPMRange) && eligibleCount >= BlendLabScope.minTracks
    }

    private var unavailableReason: LocalizedStringKey? {
        if appState.allTracks.isEmpty { return "Add music to your library to create a blend." }
        if scope == .all && !isValidBPMRange { return "The minimum BPM must not exceed the maximum." }
        guard eligibleCount < BlendLabScope.minTracks else { return nil }
        switch scope {
        case .genre: return genre == nil ? "Choose a genre." : "This genre has fewer than 2 tracks."
        case .playlist: return playlistID == nil ? "Choose a playlist." : "This playlist has fewer than 2 tracks."
        case .all: return "No tracks match \(Int(minimumBPM))–\(Int(maximumBPM)) BPM."
        }
    }

    private var maxCount: Int { BlendLabScope.maxTrackCount(available: eligibleCount) }

    private var clampedCount: Int { BlendLabScope.clampedCount(count, available: eligibleCount) }

    private func generate() {
        guard canGenerate else { return }
        let bpm = bpmRange
        session.start(BlendLabRequest(targetTrackCount: clampedCount, shape: shape,
                                      allowedTrackIDs: scopedIDs, bpmRange: bpm))
    }
}

private struct ReplaceTarget: Identifiable { let id: UUID }

private struct ReplacePicker: View {
    let candidates: [TrackRow]
    let pick: (TrackRow) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(candidates.prefix(300), id: \.id) { row in
                Button(row.track.title) { pick(row); dismiss() }
            }
            .navigationTitle("Replace Track")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
