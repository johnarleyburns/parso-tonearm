import SwiftUI

struct UpNextView: View {
    @EnvironmentObject var player: AudioPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Up Next")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer()

                if player.queueSource != .none {
                    Text(player.queueSource.label)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.bottom, 8)

            let upcoming = Array(player.upNextTracks.prefix(5))
            if upcoming.isEmpty {
                Text(player.isAmbient ? "Continuous ambient loop" : "Nothing up next")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(upcoming.enumerated()), id: \.element.id) { idx, row in
                    HStack(spacing: 10) {
                        Text("\(idx + 1)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                            .frame(width: 18, alignment: .leading)

                        ArtworkView(trackRow: row,
                                    seed: row.album?.title ?? row.track.title,
                                    cornerRadius: 6)
                            .frame(width: 34, height: 34)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.track.title)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(row.album?.artist ?? "")
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
                    .padding(.horizontal, 4)

                    if idx < upcoming.count - 1 {
                        Divider()
                            .overlay(.white.opacity(0.08))
                    }
                }
            }

            if player.upNextTracks.count > 5 {
                HStack {
                    Spacer()
                    Text("+ \(player.upNextTracks.count - 5) more")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08)))
    }
}
