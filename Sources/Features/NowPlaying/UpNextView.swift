import SwiftUI
import TonearmCore

struct UpNextView: View {
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var appState: AppState
    @State private var editMode: EditMode = .inactive

    /// The first queue offset Keep Playing appended, if any — where the
    /// "Extended by Keep Playing" marker renders. `nil` when nothing in the
    /// live queue is auto-added (feature off, nothing extended yet, or the
    /// auto-added tail was cleared).
    private var firstAutoAddedOffset: Int? {
        player.queue.firstIndex { player.keepPlayingAutoAddedTrackIDs.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Queue")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer()

                if player.queueSource != .none {
                    Text(player.queueSource.label)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }

                keepPlayingToggle

                if !player.keepPlayingAutoAddedTrackIDs.isEmpty {
                    Button {
                        player.removeUnplayedKeepPlayingTracks()
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.72))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear auto-added tracks")
                    .accessibilityIdentifier("np.keepPlaying.clearAutoAdded")
                }

                if !player.isAmbient, player.queue.count > 1 {
                    Button {
                        editMode = editMode == .active ? .inactive : .active
                    } label: {
                        Image(systemName: editMode == .active ? "checkmark" : "line.3.horizontal")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.72))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 8)

            if player.queue.isEmpty || player.isAmbient {
                Text(player.isAmbient ? "Continuous ambient loop" : "Nothing up next")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.vertical, 8)
            } else {
                List {
                    ForEach(Array(player.queue.enumerated()), id: \.offset) { offset, row in
                        VStack(alignment: .leading, spacing: 4) {
                            if offset == firstAutoAddedOffset {
                                keepPlayingSeparator
                            }
                            QueueRow(row: row,
                                     position: offset + 1,
                                     isCurrent: offset == player.index,
                                     queueIndex: offset)
                        }
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .listRowBackground(Color.clear)
                            .listRowSeparatorTint(.white.opacity(0.08))
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    player.removeFromQueue(at: offset)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
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
                .environment(\.editMode, $editMode)
                .frame(height: queueListHeight)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08)))
    }

    private var queueListHeight: CGFloat {
        let visibleRows = min(max(player.queue.count, 1), 6)
        return CGFloat(visibleRows) * 52
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
                Image(systemName: "infinity").font(.system(size: 11, weight: .semibold))
                Text("Keep Playing").font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(player.keepPlayingEnabled ? Palette.brass : .white.opacity(0.5))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(player.keepPlayingEnabled ? Palette.brass.opacity(0.16) : .white.opacity(0.06),
                        in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(player.isAmbient)
        .accessibilityLabel("Keep Playing")
        .accessibilityValue(player.keepPlayingEnabled ? "on" : "off")
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
                    .font(.system(size: 10, weight: .semibold))
                Text("Extended by Keep Playing")
                    .font(.system(size: 10.5, weight: .semibold))
                    .textCase(.uppercase)
                    .kerning(0.3)
            }
            if player.keepPlayingLastExtensionWasFallback {
                Text(keepPlayingFallbackDetail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .foregroundStyle(Palette.brass.opacity(0.85))
        .padding(.top, 2)
    }

    private var keepPlayingFallbackDetail: String {
        switch player.keepPlayingFallbackReason {
        case .waitingForModel:
            return "Shuffled — the sound-search model is still downloading"
        case .unavailable, nil:
            return "Shuffled — no sound-search match available for this track"
        }
    }
}

private struct QueueRow: View {
    let row: TrackRow
    let position: Int
    let isCurrent: Bool
    let queueIndex: Int
    @EnvironmentObject var player: AudioPlayer

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if isCurrent {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 10, weight: .semibold))
                } else {
                    Text("\(position)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                }
            }
            .foregroundStyle(isCurrent ? Palette.brass : .white.opacity(0.4))
            .frame(width: 20, alignment: .leading)

            ArtworkView(trackRow: row,
                        seed: row.album?.title ?? row.track.title,
                        cornerRadius: 6)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.track.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(row.artist?.name ?? row.album?.artist ?? "")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            Spacer()
            if let dur = row.track.durationSec, dur > 0 {
                Text(TimeFmt.mmss(dur))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            player.skipToIndex(queueIndex)
        }
    }
}
