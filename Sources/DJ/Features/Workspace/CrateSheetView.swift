import SwiftUI

struct CrateSheetView: View {
    @ObservedObject var model: WorkspaceModel
    @State private var pickingDeck: PerformanceEngine.Deck?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Capsule().fill(Color.white.opacity(0.18)).frame(width: 38, height: 4)
                Spacer()
                Button { model.dismissCrateSheet() } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }.accessibilityIdentifier("dj.crate.close")
            }.padding(.horizontal, 15)
            deckHalf(.a)
            Divider()
            deckHalf(.b)
        }
        .background(Color(red: 0.055, green: 0.075, blue: 0.10))
        .accessibilityIdentifier("dj.crate.sheet")
        .sheet(isPresented: Binding(get: { pickingDeck != nil }, set: { if !$0 { pickingDeck = nil } })) {
            if let deck = pickingDeck {
                CratePlaylistPickerView(model: model, deck: deck) { pickingDeck = nil }
            }
        }
    }

    private func deckHalf(_ deck: PerformanceEngine.Deck) -> some View {
        let imported = model.importedCrate(for: deck)
        let code = deck == .a ? "a" : "b"
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("DECK \(deck == .a ? "A" : "B")" + (imported.map { " — \($0.title)" } ?? ""))
                    .font(.caption.bold()).accessibilityIdentifier("dj.crate.deck.\(code).title")
                Spacer()
                if imported != nil {
                    Button("Change") { pickingDeck = deck }
                        .accessibilityIdentifier("dj.crate.change.\(code)")
                }
            }
            if imported == nil {
                Button { pickingDeck = deck } label: {
                    Label("Import playlist", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .accessibilityIdentifier("dj.crate.import.\(code)")
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(model.queue(for: deck).rows) { row in
                            crateRow(row, deck: deck)
                        }
                    }
                }
            }
            if let error = model.crateImportError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 15).padding(.vertical, 8)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func crateRow(_ row: DeckQueueRow, deck: PerformanceEngine.Deck) -> some View {
        Button {
            guard row.readiness.isReady else { return }
            Task { await model.loadAndPlay(deck, trackID: row.trackID) }
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(row.title).font(.caption.bold()).lineLimit(1)
                    Text(row.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: row.readiness.isReady ? "play.circle.fill" : "exclamationmark.circle")
            }.padding(8).background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain).disabled(!row.readiness.isReady)
        .accessibilityIdentifier("dj.queue.row.\(row.title)")
    }
}

private struct CratePlaylistPickerView: View {
    @ObservedObject var model: WorkspaceModel
    let deck: PerformanceEngine.Deck
    let close: () -> Void
    @State private var playlists: [CratePlaylistSummary] = []
    @State private var tracks: [Int64: [CrateTrackSummary]] = [:]
    @State private var selected: CratePlaylistSummary?

    var body: some View {
        NavigationStack {
            List(playlists) { playlist in
                DisclosureGroup {
                    ForEach(tracks[playlist.id] ?? []) { track in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(track.title); Text(track.artist).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !track.isOnDevice { Text("not on this device").font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                    Button("Select \(playlist.title)") { selected = playlist }
                        .accessibilityIdentifier("dj.crate.picker.row.\(playlist.title)")
                } label: {
                    HStack { Text(playlist.title); Spacer(); Text("\(playlist.trackCount) tracks").foregroundStyle(.secondary) }
                }
                .accessibilityIdentifier("dj.crate.picker.expand.\(playlist.title)")
                .task { tracks[playlist.id] = await model.cratePlaylistTracks(playlist.id) }
            }
            .navigationTitle("Import playlist")
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button("Cancel") { close() }
                    Spacer()
                    if model.isImportingCrate { ProgressView() }
                    Button("Import") {
                        guard let selected else { return }
                        Task {
                            await model.importCrate(playlistID: selected.id, title: selected.title,
                                                    into: deck)
                            if model.crateImportError == nil { close() }
                        }
                    }
                    .disabled(selected == nil || model.isImportingCrate)
                    .accessibilityIdentifier("dj.crate.picker.confirm")
                }.padding().background(.ultraThinMaterial)
            }
            .task { playlists = await model.availableCratePlaylists() }
        }
    }
}
