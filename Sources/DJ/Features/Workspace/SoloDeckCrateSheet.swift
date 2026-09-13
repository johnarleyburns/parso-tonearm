import SwiftUI

// MARK: - Browse-while-performing crate sheet

/// The browse-while-performing crate sheet (§42.7, mockup `iphone/05b`): the
/// focused deck's queue, ranked against that deck. Two rules are normative and
/// structural here: both decks stay visible above the sheet, and the sheet may
/// never cover the crossfader — the panel's height is bounded by
/// `WorkspaceModel.crateSheetMaxHeight` and it renders *behind* the
/// always-visible crossfader bar.
///
/// Plan 5.1 made the rows real (decision 16: "the crate sheet deferred in 4.7
/// gets its real rows here"): a **source picker at its head** (§41.9c,
/// FR-ENG-13 — the deck's queue may be any selectable source), and one-gesture
/// loading through `WorkspaceModel.load(_:trackID:)` with the FR-LIB-8
/// readiness shown per row (mockup `iphone/05b`'s dimmed caching row — a
/// track that is not deck-ready says so, it never fails on the tap).
/// The §41.9c per-deck source picker (FR-ENG-13), deliberately holding **values**
/// rather than the workspace model.
///
/// `Equatable` is the point: the crate sheet re-renders at telemetry cadence, and
/// a `Menu` whose subtree is rebuilt underneath it closes. Comparing equal across
/// frames where the crates and the selection have not changed keeps a presented
/// menu on screen — the difference between a picker you can use while the decks
/// run and one that snaps shut in your hand.
struct QueueSourcePicker: View, Equatable {
    let deckID: String
    let sources: [DeckQueueSource]
    let current: DeckQueueSource
    let select: (DeckQueueSource) -> Void

    /// `nonisolated` because SwiftUI compares view values off the main actor:
    /// only the immutable inputs are read, never the action closure.
    nonisolated static func == (lhs: QueueSourcePicker, rhs: QueueSourcePicker) -> Bool {
        lhs.deckID == rhs.deckID && lhs.sources == rhs.sources && lhs.current == rhs.current
    }

    var body: some View {
        Menu {
            ForEach(sources, id: \.self) { source in
                Button {
                    select(source)
                } label: {
                    if source == current {
                        Label(source.title, systemImage: "checkmark")
                    } else {
                        Text(source.title)
                    }
                }
                .accessibilityIdentifier("dj.queue.\(source.title)")
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.stack")
                Text(current.title)
                    .lineLimit(1)
            }
            .font(.system(size: 14, weight: .bold))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("dj.deck.\(deckID).queue")
    }
}

private struct LegacyCrateSheetView: View {
    @ObservedObject var model: WorkspaceModel

    private var deck: Deck { model.focusedDeck }
    private var queue: DeckQueue { model.queue(for: deck) }
    private var loadState: DeckLoadState { model.loadState(for: deck) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.18))
                .frame(width: 38, height: 4)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
                .padding(.bottom, 12)

            header

            Divider()

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(queue.rows) { row in
                        rowView(row)
                    }
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .background(Color(red: 0.055, green: 0.075, blue: 0.10))
        .overlay(alignment: .top) { Divider() }
        .accessibilityIdentifier("dj.crate.sheet")
        .task {
            await model.refreshDeckQueues()
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                // The §41.9c source picker at the browse surface's head — the
                // deck's queue is any selectable source; the other deck is
                // untouched (FR-ENG-13). It takes plain values and compares
                // equal across telemetry frames on purpose: this sheet observes
                // the model, whose telemetry publishes at display rate, so a
                // picker rebuilt from that would dismiss its own open menu
                // within a frame or two — browse-while-performing means the
                // crate list has to stay open while the decks run.
                QueueSourcePicker(deckID: deck == .a ? "a" : "b",
                                  sources: model.availableQueues,
                                  current: queue.source) { source in
                    Task { await model.selectQueue(source, for: deck) }
                }
                .equatable()
                Text("\(queue.rows.count) tracks · ranked against DECK \(deck == .a ? "A" : "B") · browse while performing")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.dismissCrateSheet()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("dj.crate.close")
        }
        .padding(.horizontal, 15)
        .padding(.bottom, 10)
    }

    private func rowView(_ row: DeckQueueRow) -> some View {
        let isReady = row.readiness.isReady
        let isLoading = loadState == .loading(trackID: row.trackID)
        return Button {
            guard isReady else { return }
            Task { await model.loadAndPlay(deck, trackID: row.trackID) }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isReady ? .primary : .secondary)
                        .lineLimit(1)
                    Text(row.artist.isEmpty ? "—" : row.artist)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                status(for: row, isLoading: isLoading)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 9)
            .background(Color.white.opacity(isReady ? 0.04 : 0.02), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!isReady)
        .opacity(isReady ? 1 : 0.5)
        .accessibilityIdentifier("dj.queue.row.\(row.title)")
    }

    @ViewBuilder
    private func status(for row: DeckQueueRow, isLoading: Bool) -> some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
        } else if row.readiness.isReady {
            Label("load", systemImage: "play.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        } else {
            Text(WorkspaceModel.unavailableReason(row.readiness))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }
}
