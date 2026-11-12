import SwiftUI
import TonearmCore

struct UpNextView: View {
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var appState: AppState
    #if os(iOS)
    @State private var editMode: EditMode = .inactive
    #endif

    private var projection: QueueSectionProjection { player.queueSectionProjection }

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

                if projection.hasManual {
                    Button {
                        player.removeUnplayedListenerTracks()
                    } label: {
                        Image(systemName: "text.badge.xmark")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.inkSecondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear added tracks")
                    .accessibilityIdentifier("np.queue.clearManual")
                }

                if projection.hasKeepPlaying {
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

            if player.queue.isEmpty || player.isAmbient {
                Text(player.isAmbient ? "Continuous ambient loop" : "Nothing up next")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
                    .padding(.vertical, 8)
            } else {
                #if os(iOS)
                // Not a List: the parent Now Playing ScrollView is the only scroller, so
                // playback advancing can never move a nested viewport or strand the controls.
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let current = projection.currentOffset {
                        iosQueueRow(offset: current, row: player.queue[current])
                            .id(queueRowID(current))
                    }
                    ForEach(projection.sections, id: \.kind) { section in
                        sectionHeader(section.kind)
                        ForEach(section.offsets, id: \.self) { offset in
                            iosQueueRow(offset: offset, row: player.queue[offset])
                                .id(queueRowID(offset))
                        }
                    }
                }
                .accessibilityIdentifier("np.queue.list")
                #else
                List {
                    if let current = projection.currentOffset {
                        macRow(offset: current)
                    }
                    ForEach(projection.sections, id: \.kind) { section in
                        SwiftUI.Section {
                            ForEach(section.offsets, id: \.self) { offset in
                                macRow(offset: offset)
                            }
                            .onMove { offsets, destination in
                                // Section-local indices map back to physical queue offsets.
                                let from = IndexSet(offsets.map { section.offsets[$0] })
                                let to = destination < section.offsets.count
                                    ? section.offsets[destination] : (section.offsets.last ?? 0) + 1
                                player.moveQueueItems(fromOffsets: from, toOffset: to)
                            }
                            .onDelete { offsets in
                                player.removeFromQueue(atOffsets: IndexSet(offsets.map { section.offsets[$0] }))
                            }
                        } header: {
                            sectionHeader(section.kind)
                        }
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
    }

    /// Stable occurrence identity so duplicates stay distinct across advance/insert/remove/reorder.
    private func queueRowID(_ offset: Int) -> String {
        let occurrences = player.queueOccurrences
        return occurrences.count == player.queue.count ? "o-\(occurrences[offset].rawValue)" : "i-\(offset)"
    }

    @ViewBuilder
    private func sectionHeader(_ kind: QueueSectionProjection.Kind) -> some View {
        let title: String = {
            switch kind {
            case .manual: return String(localized: "Added by you")
            case .context: return String(localized: "Playing from \(player.queueSource.label)")
            case .keepPlaying: return String(localized: "Keep Playing")
            }
        }()
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Typography.caption)
                .textCase(.uppercase)
                .kerning(0.3)
            if kind == .keepPlaying, player.keepPlayingLastExtensionWasFallback {
                Text(keepPlayingFallbackDetail)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
                    .textCase(nil)
            }
        }
        .foregroundStyle(Palette.accent.opacity(0.85))
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier(kind.accessibilityIdentifier)
        // Copy contract: ADDED BY YOU / PLAYING FROM <source> / KEEP PLAYING (uppercased by textCase).
    }

    #if !os(iOS)
    private func macRow(offset: Int) -> some View {
        QueueRow(row: player.queue[offset],
                 position: offset + 1,
                 isCurrent: offset == player.index,
                 isUpNext: offset == player.index + 1,
                 queueIndex: offset)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(Palette.hairline)
            .id(queueRowID(offset))
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
    #endif

    #if os(iOS)
    @ViewBuilder
    private func iosQueueRow(offset: Int, row: TrackRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
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
            // Real report: the removed blend/transition connector row here ("Fallback", "Blend
            // unavailable", "Not planned yet"...) was a confusing leftover from the removed
            // automatic/manual blend features — there's no real transition plan to describe
            // anymore, so it always rendered one of the "nothing is happening" fallback states.
            // See also NowPlayingView.swift's TransitionCard removal.
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
                        cornerRadius: 6,
                        thumbnailMaxDimension: 34)
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
