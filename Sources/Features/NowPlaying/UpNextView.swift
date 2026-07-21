import SwiftUI
import TonearmCore

struct UpNextView: View {
    @EnvironmentObject var player: AudioPlayer
    @State private var editMode: EditMode = .inactive

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
                        QueueRow(row: row,
                                 position: offset + 1,
                                 isCurrent: offset == player.index,
                                 queueIndex: offset)
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
                Text(row.album?.artist ?? row.artist?.name ?? "")
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
