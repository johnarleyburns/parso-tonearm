import SwiftUI

/// The §41.9c per-deck queue panel (plan 5.1, decision 16): the deck's browse
/// surface on the iPad workspace. A **source picker at its head** — the queue
/// is any selectable source and the two decks may draw from different ones at
/// once (FR-ENG-13) — with the queue's rows beneath, each a one-gesture load
/// through the `WorkspaceModel` (the FR-LIB-8 gate, so a track that is not
/// deck-ready is dimmed with its reason, never a failure on the tap). Nothing
/// here auto-advances (§41.9c).
struct DeckQueuePanel: View {
    @ObservedObject var model: WorkspaceModel
    let deck: Deck

    private var queue: DeckQueue { model.queue(for: deck) }
    private var loadState: DeckLoadState { model.loadState(for: deck) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Menu {
                    ForEach(model.availableQueues, id: \.self) { source in
                        Button {
                            Task { await model.selectQueue(source, for: deck) }
                        } label: {
                            if source == queue.source {
                                Label(source.title, systemImage: "checkmark")
                            } else {
                                Text(source.title)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.stack")
                            .font(.system(size: 10, weight: .semibold))
                        Text(queue.source.title)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.07), in: Capsule())
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                Spacer()
                Text("\(queue.rows.count) tracks")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if queue.rows.isEmpty {
                Text("No tracks in this queue yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 4) {
                        ForEach(queue.rows) { row in
                            queueRow(row)
                        }
                    }
                }
                .frame(maxHeight: 100)
            }
        }
        .task {
            await model.refreshDeckQueues()
        }
    }

    private func queueRow(_ row: DeckQueueRow) -> some View {
        let isReady = row.readiness.isReady
        let isLoading = loadState == .loading(trackID: row.trackID)
        return Button {
            guard isReady else { return }
            Task { await model.load(deck, trackID: row.trackID) }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isReady ? .primary : .secondary)
                        .lineLimit(1)
                    Text(row.artist.isEmpty ? "—" : row.artist)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                } else if row.readiness.isReady {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text(WorkspaceModel.unavailableReason(row.readiness))
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(!isReady)
        .opacity(isReady ? 1 : 0.55)
    }
}
