import SwiftUI
import TonearmCore

/// My Music > Saved Blends. Loading, empty and error states never hide
/// blends that did load.
struct SavedBlendsView: View {
    @EnvironmentObject var appState: AppState
    @State private var blends: [BlendDocument] = []
    @State private var issues: [BlendRepository.LoadIssue] = []
    @State private var didLoad = false
    @State private var selected: BlendDocument?

    var body: some View {
        List {
            BlendLabEntryButton()
            ForEach(issues.indices, id: \.self) { i in
                Label(Self.describe(issues[i]), systemImage: "exclamationmark.triangle")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkSecondary)
                    .accessibilityIdentifier("savedblends.issue")
            }
            if !didLoad {
                ProgressView("Loading saved blends…").accessibilityIdentifier("savedblends.loading")
            } else if blends.isEmpty {
                Text("No saved blends yet. Use Save Blend in the queue to keep one.")
                    .foregroundStyle(Palette.inkSecondary)
                    .accessibilityIdentifier("savedblends.empty")
            }
            ForEach(blends) { blend in
                Button { selected = blend } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(blend.title).font(Typography.callout).foregroundStyle(Palette.ink)
                        Text("\(blend.occurrences.count) tracks")
                            .font(Typography.caption).foregroundStyle(Palette.inkSecondary)
                    }
                }
                .accessibilityIdentifier("savedblends.row")
            }
        }
        .listStyle(.plain)
        .task { await reload() }
        .sheet(item: $selected, onDismiss: { Task { await reload() } }) { blend in
            BlendDetailView(blend: blend)
        }
    }

    private func reload() async {
        let snapshot = await appState.blendRepository.load()
        blends = StarterBlendCatalog.mergingStarterBlends(into: snapshot.blends); issues = snapshot.issues; didLoad = true
    }

    static func describe(_ issue: BlendRepository.LoadIssue) -> String {
        switch issue {
        case .malformedQuarantined: String(localized: "Saved blends could not be read; the file was kept aside.")
        case .newerSchema: String(localized: "Saved blends were made by a newer version and are read-only.")
        case .legacyMigrated: String(localized: "Older saved blends were upgraded.")
        }
    }
}

struct BlendDetailView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss
    @State var blend: BlendDocument
    @State private var confirmRemove = false
    @State private var message: String?

    private var entries: [BlendReplay.Entry] {
        BlendReplay.resolve(blend, lookup: BlendReplay.lookup(in: appState.allTracks))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(Self.originLabel(blend.origin))
                    if let played = blend.lastPlayedAt {
                        Text("Last played \(played.formatted(date: .abbreviated, time: .shortened))")
                    } else { Text("Never played") }
                    if let message { Text(message).accessibilityIdentifier("blenddetail.message") }
                }
                Section("Tracks") {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.row?.track.title ?? entry.occurrence.source.title)
                            if blend.pack == nil, let status = Self.statusLabel(entry.status) {
                                Text(status).font(Typography.caption).foregroundStyle(.red)
                                Button("Remove from blend", role: .destructive) { remove(entry) }
                                    .font(Typography.caption)
                            }
                            if index < blend.edges.count {
                                Text(blend.edges[index].plan.map { "→ \($0.style.rawValue)" }
                                     ?? blend.edges[index].requestedStyle.map { "→ \($0)" } ?? "→ Smart blend")
                                    .font(Typography.caption).foregroundStyle(Palette.inkSecondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                Section {
                    Button("Play") { play() }.accessibilityIdentifier("blenddetail.play")
                    if !StarterBlendCatalog.isBuiltIn(blend) {
                        Button("Remove Saved Blend", role: .destructive) { confirmRemove = true }
                    }
                }
            }
            .navigationTitle(blend.title)
            .confirmationDialog("Remove this saved blend?", isPresented: $confirmRemove,
                                titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    Task {
                        try? await appState.blendRepository.remove(id: blend.id)
                        appState.savedBlendIDsByQueue = appState.savedBlendIDsByQueue.filter { $0.value != blend.id }
                        dismiss()
                    }
                }
            }
        }
    }

    private func play() {
        if let request = BlendReplay.starterRequest(for: blend) {
            message = nil
            player.playStarterBlend(request)
            let id = blend.id
            Task { try? await appState.blendRepository.markPlayed(id: id) }
            return
        }
        let all = entries
        let queue = BlendReplay.playableQueue(all)
        let skipped = all.count - queue.count
        guard !queue.isEmpty else {
            message = String(localized: "None of this blend's tracks are available."); return
        }
        message = skipped > 0 ? String(localized: "Skipped \(skipped) unavailable track(s).") : nil
        player.play(tracks: queue, startAt: 0, source: .none)
        let id = blend.id
        Task { try? await appState.blendRepository.markPlayed(id: id) }
    }

    private func remove(_ entry: BlendReplay.Entry) {
        let updated = blend.replacingOccurrences(blend.occurrences.filter { $0.id != entry.id })
        Task {
            if (try? await appState.blendRepository.save(updated)) != nil { blend = updated }
        }
    }

    static func statusLabel(_ status: BlendReplay.Status) -> String? {
        switch status {
        case .playable: nil
        case .missingLocalFile: String(localized: "Local file missing — skipped")
        case .unavailableRemote: String(localized: "Remote track unavailable — skipped")
        case .notInLibrary: String(localized: "Not in your library — skipped")
        }
    }

    static func originLabel(_ origin: BlendDocument.Origin) -> String {
        switch origin {
        case .starter: String(localized: "From a starter blend")
        case .manualQueue: String(localized: "From a queue")
        case .blendLab: String(localized: "From Blend Lab")
        }
    }
}
