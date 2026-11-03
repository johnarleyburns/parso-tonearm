import SwiftUI
import TonearmCore

struct UpNextView: View {
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var appState: AppState
    @EnvironmentObject private var transitionPrep: TransitionPrepService
    @State private var selectedEdge: QueueEdgeKey?
    #if os(iOS)
    @State private var editMode: EditMode = .inactive
    #endif

    private var transitionRows: [TrackRow] {
        Array(([player.currentTrack].compactMap { $0 } + player.upNextTracks).prefix(3))
    }

    /// The first queue offset Keep Playing appended, if any — where the
    /// "Extended by Keep Playing" marker renders. `nil` when nothing in the
    /// live queue is auto-added (feature off, nothing extended yet, or the
    /// auto-added tail was cleared).
    private var firstAutoAddedOffset: Int? {
        player.queue.firstIndex { player.keepPlayingAutoAddedTrackIDs.contains($0.id) }
    }

    /// Per-edge rows from the live queue, the occurrence identities and the renderer snapshots.
    private var edgeRows: [QueueEdgeRow] {
        QueueEdgeResolver.rows(
            trackIDs: player.queue.map(\.track.id), currentIndex: player.index,
            repeatMode: player.repeatMode, smartTransitionsEnabled: player.smartTransitionsEnabled,
            live: player.transitionPresentation, occurrences: player.queueOccurrences,
            snapshot: { player.transitionExecutionSnapshot(afterQueueIndex: $0) },
            noBlend: player.noBlendEdges)
    }

    /// The selected edge while it still names the same occurrence pair; nil dismisses the detail.
    private var selectedEdgeBinding: Binding<QueueEdgeRow?> {
        Binding(get: { QueueEdgeResolver.resolve(selectedEdge, in: edgeRows) },
                set: { selectedEdge = $0?.key })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Queue")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.ink)

                Spacer()

                if player.queueSource != .none {
                    Text(player.queueSource.label)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkSecondary)
                }

                keepPlayingToggle

                if !player.keepPlayingAutoAddedTrackIDs.isEmpty {
                    Button {
                        player.removeUnplayedKeepPlayingTracks()
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.inkSecondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear auto-added tracks")
                    .accessibilityIdentifier("np.keepPlaying.clearAutoAdded")
                }

                // A Mac list reorders by drag and removes with the Delete key
                // at any time, so only iPhone needs an explicit reorder mode.
                #if os(iOS)
                if !player.isAmbient, player.queue.count > 1 {
                    Button {
                        editMode = editMode == .active ? .inactive : .active
                    } label: {
                        Image(systemName: editMode == .active ? "checkmark" : "line.3.horizontal")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.inkSecondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(QueueAccessibility.reorderLabel(isReordering: editMode == .active))
                }
                #endif
            }
            .padding(.bottom, 8)

            TransitionChip(
                onPrepareNow: {
                    transitionPrep.prepare(rows: transitionRows, appState: appState, allowsCellular: player.isPlayingMix)
                },
                onAudition: {
                    guard let outgoing = player.currentTrack,
                          let incoming = player.upNextTracks.first else { return }
                    player.auditionTransition(outgoing: outgoing, incoming: incoming)
                },
                preparationState: player.upNextTracks.first?.track.id.flatMap {
                    transitionPrep.transitionPrepState(for: $0)
                })
                .padding(.bottom, 6)

            if player.queue.isEmpty || player.isAmbient {
                Text(player.isAmbient ? "Continuous ambient loop" : "Nothing up next")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
                    .padding(.vertical, 8)
            } else {
                let edges = Dictionary(uniqueKeysWithValues: edgeRows.map { ($0.key.position, $0) })
                #if os(iOS)
                // Not a List: the parent Now Playing ScrollView is the only scroller, so
                // playback advancing can never move a nested viewport or strand the controls.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(queueEntries, id: \.id) { entry in
                        iosQueueRow(offset: entry.offset, row: entry.row, edges: edges)
                    }
                }
                .accessibilityIdentifier("np.queue.list")
                #else
                List {
                    ForEach(Array(player.queue.enumerated()), id: \.offset) { offset, row in
                        VStack(alignment: .leading, spacing: 4) {
                            if offset == firstAutoAddedOffset {
                                keepPlayingSeparator
                            }
                            QueueRow(row: row,
                                     position: offset + 1,
                                     isCurrent: offset == player.index,
                                     isUpNext: offset == player.index + 1,
                                     queueIndex: offset)
                            if let edge = edges[offset] {
                                QueueTransitionConnector(edge: edge, isSelected: edge.key == selectedEdge,
                                         incomingPosition: edge.key.position + 1 < player.queue.count ? edge.key.position + 2 : 1) {
                                    selectedEdge = edge.key
                                }
                                .id(edge.key)
                            }
                        }
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .listRowBackground(Color.clear)
                            .listRowSeparatorTint(Palette.hairline)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    player.removeFromQueue(at: offset)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                            .accessibilityAction(named: QueueAccessibility.removeActionName) {
                                player.removeFromQueue(at: offset)
                            }
                    }
                    .onMove { offsets, destination in
                        player.moveQueueItems(fromOffsets: offsets, toOffset: destination)
                    }
                    .onDelete { offsets in
                        player.removeFromQueue(atOffsets: offsets)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                #if os(iOS)
                .environment(\.editMode, $editMode)
                #endif
                .frame(height: queueListHeight)
                #endif
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.hairline))
        .sheet(item: selectedEdgeBinding) { edge in
            QueueEdgeDetailSheet(edge: edge,
                                 outgoing: player.queue.indices.contains(edge.key.position) ? player.queue[edge.key.position] : nil,
                                 incoming: queueRow(after: edge.key.position),
                                 incomingPosition: edge.key.position + 1 < player.queue.count ? edge.key.position + 2 : 1)
        }
        .task {
            if case .mix = player.queueSource {
                transitionPrep.prepare(rows: transitionRows, appState: appState, allowsCellular: player.isPlayingMix)
            }
        }
        .onChange(of: player.currentTrack?.track.id) { _, _ in
            guard case .mix = player.queueSource else { return }
            transitionPrep.prepare(rows: transitionRows, appState: appState, allowsCellular: player.isPlayingMix)
        }
    }

    private func queueRow(after position: Int) -> TrackRow? {
        guard !player.queue.isEmpty else { return nil }
        let next = position + 1 < player.queue.count ? position + 1 : 0
        return player.queue[next]
    }

    #if os(iOS)
    /// Rows keyed by queue-occurrence identity so duplicates stay distinct and
    /// identity survives advance, insert, remove and reorder.
    private var queueEntries: [(id: String, offset: Int, row: TrackRow)] {
        let occurrences = player.queueOccurrences
        let usable = occurrences.count == player.queue.count
        return player.queue.enumerated().map { offset, row in
            (usable ? "o-\(occurrences[offset].rawValue)" : "i-\(offset)", offset, row)
        }
    }

    @ViewBuilder
    private func iosQueueRow(offset: Int, row: TrackRow, edges: [Int: QueueEdgeRow]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if offset == firstAutoAddedOffset {
                keepPlayingSeparator
            }
            HStack(spacing: 6) {
                if editMode == .active {
                    Button { player.removeFromQueue(at: offset) } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(Color.red)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(QueueAccessibility.removeActionName)
                    .accessibilityIdentifier("np.queue.remove.\(offset)")
                }
                QueueRow(row: row,
                         position: offset + 1,
                         isCurrent: offset == player.index,
                         isUpNext: offset == player.index + 1,
                         queueIndex: offset)
                if editMode == .active {
                    VStack(spacing: 0) {
                        Button { player.moveQueueItem(from: offset, to: offset - 1) } label: {
                            Image(systemName: "chevron.up").frame(width: 44, height: 22)
                                .contentShape(Rectangle())
                        }
                        .disabled(offset == 0)
                        .accessibilityLabel("Move up")
                        .accessibilityIdentifier("np.queue.moveUp.\(offset)")
                        Button { player.moveQueueItem(from: offset, to: offset + 1) } label: {
                            Image(systemName: "chevron.down").frame(width: 44, height: 22)
                                .contentShape(Rectangle())
                        }
                        .disabled(offset == player.queue.count - 1)
                        .accessibilityLabel("Move down")
                        .accessibilityIdentifier("np.queue.moveDown.\(offset)")
                    }
                    .buttonStyle(.plain)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkSecondary)
                }
            }
            if let edge = edges[offset] {
                QueueTransitionConnector(edge: edge, isSelected: edge.key == selectedEdge,
                         incomingPosition: edge.key.position + 1 < player.queue.count ? edge.key.position + 2 : 1) {
                    selectedEdge = edge.key
                }
                .id(edge.key)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button(role: .destructive) { player.removeFromQueue(at: offset) } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .accessibilityAction(named: QueueAccessibility.removeActionName) {
            player.removeFromQueue(at: offset)
        }
    }
    #endif

    private var queueListHeight: CGFloat {
        let visibleRows = min(max(player.queue.count, 1), 6)
        return CGFloat(visibleRows) * 150
    }

    /// The obvious, discoverable Keep Playing control (CLAUDE.md "no silent/
    /// magic background work" — a settings-only toggle isn't enough): lives
    /// right in the queue header, next to shuffle/repeat above it. Toggling
    /// it off also removes any not-yet-played auto-added tail
    /// (`AudioPlayer.keepPlayingEnabled`'s `didSet`).
    private var keepPlayingToggle: some View {
        Button {
            appState.keepPlayingEnabled.toggle()
            appState.applySettingsToPlayer()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "infinity").font(Typography.caption)
                Text("Keep Playing").font(Typography.caption)
            }
            .foregroundStyle(player.keepPlayingEnabled ? Palette.accent : Palette.inkTertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(minHeight: 44)
            .contentShape(Capsule())
            .background(player.keepPlayingEnabled ? Palette.accent.opacity(0.16) : Palette.ink.opacity(0.06),
                        in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(player.isAmbient)
        .accessibilityLabel("Keep Playing")
        .accessibilityValue(QueueAccessibility.keepPlayingValue(isOn: player.keepPlayingEnabled))
        .accessibilityHint(QueueAccessibility.keepPlayingHint)
        .accessibilityAddTraits(player.keepPlayingEnabled ? .isSelected : [])
        .accessibilityIdentifier("np.keepPlaying")
    }

    /// Marks where Keep Playing's auto-added tail begins, distinguishing it
    /// from tracks the user explicitly queued (CLAUDE.md "no silent/magic
    /// background work": when it extends the queue, that must be visible).
    /// When the last extension had to fall back to a shuffle-continue, this
    /// also says so and why — never a silent substitution.
    private var keepPlayingSeparator: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: player.keepPlayingLastExtensionWasFallback ? "shuffle" : "waveform")
                    .font(Typography.caption)
                Text("Extended by Keep Playing")
                    .font(Typography.caption)
                    .textCase(.uppercase)
                    .kerning(0.3)
            }
            if player.keepPlayingLastExtensionWasFallback {
                Text(keepPlayingFallbackDetail)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
            }
        }
        .foregroundStyle(Palette.accent.opacity(0.85))
        .padding(.top, 2)
    }

    private var keepPlayingFallbackDetail: String {
        switch player.keepPlayingFallbackReason {
        case .waitingForModel:
            return String(localized: "Shuffled — the sound-search model is still downloading")
        case .matchingUnavailable:
            return String(localized: "Broader sound match — no Camelot/BPM match was available")
        case .unavailable, nil:
            return String(localized: "Shuffled — no sound-search match available for this track")
        }
    }
}

private struct QueueRow: View {
    let row: TrackRow
    let position: Int
    let isCurrent: Bool
    var isUpNext = false
    let queueIndex: Int
    @EnvironmentObject var player: AudioPlayer

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if isCurrent {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(Typography.caption)
                } else {
                    Text("\(position)")
                        .font(Typography.monoStrong)
                }
            }
            .foregroundStyle(isCurrent ? Palette.accent : Palette.inkTertiary)
            .frame(width: 20, alignment: .leading)

            ArtworkView(trackRow: row,
                        seed: row.album?.title ?? row.track.title,
                        cornerRadius: 6)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.track.title)
                    .font(Typography.callout)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(row.artist?.name ?? row.album?.artist ?? "")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(1)
            }
            Spacer()
            if let dur = row.track.durationSec, dur > 0 {
                Text(TimeFmt.mmss(dur))
                    .font(Typography.mono)
                    .foregroundStyle(Palette.inkTertiary)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
        .background(isCurrent ? Palette.accent.opacity(0.12) : Palette.ink.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(isCurrent ? Palette.accent : Palette.hairline, lineWidth: isCurrent ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture {
            player.skipToIndex(queueIndex)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(QueueAccessibility.rowLabel(
            position: position, title: row.track.title,
            artist: row.artist?.name ?? row.album?.artist ?? ""))
        .accessibilityValue(QueueAccessibility.rowValue(isCurrent: isCurrent, isUpNext: isUpNext,
                                                        duration: row.track.durationSec))
        .accessibilityHint(QueueAccessibility.rowHint(isCurrent: isCurrent))
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { player.skipToIndex(queueIndex) }
    }
}
