import SwiftUI

// MARK: - Seed track (§41.6 "Start from")

extension PlaylistBriefView {
    var seedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Start from")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            if let label = model.seedTrackLabel {
                HStack(spacing: 10) {
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                    Text(label)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                    Spacer()
                    Button("✕") { model.clearSeed() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("Clear seed track")
                }
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            } else {
                Button {
                    seedSearch = ""
                    showSeedPicker = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle")
                        Text("Choose a track to open with")
                        Spacer()
                    }
                    .font(.system(size: 12.5))
                }
                .buttonStyle(.bordered)
            }

            Text("Optional. A seed track anchors the opening and biases the whole search toward its feel.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    var seedPicker: some View {
        let tracks = model.tracks(matching: seedSearch)
        return List(tracks) { row in
            Button {
                model.setSeed(trackID: row.id,
                              label: "\(row.title) · \(row.artistNames)")
                showSeedPicker = false
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(row.artistNames)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .searchable(text: $seedSearch, prompt: "Search titles and artists")
        .navigationTitle("Start from a track")
    }
}
