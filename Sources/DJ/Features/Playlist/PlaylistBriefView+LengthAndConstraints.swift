import SwiftUI

// MARK: - Length (FR-PLIST-2's T, with ±5% honesty) and Constraints (§28A.2)

extension PlaylistBriefView {
    var lengthCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Length")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            if !model.useTrackCount {
                HStack {
                    Text(AutoPlaylistModel.durationText(model.targetSeconds))
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    Spacer()
                    Text("± 5%")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $model.targetSeconds, in: 30 * 60...4 * 3600, step: 300)
                HStack {
                    Text("30 min")
                    Spacer()
                    Text("4 h")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                Text("We aim for within five percent of your target.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Toggle("…or a fixed number of tracks", isOn: $model.useTrackCount)
                .font(.system(size: 12.5))
            if model.useTrackCount {
                HStack {
                    Text("\(Int(model.targetTrackCount)) tracks")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    Spacer()
                    Stepper("", value: $model.targetTrackCount, in: 5...40, step: 1)
                        .labelsHidden()
                }
            }
        }
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    var constraintsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Constraints")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            stepperRow(label: "Same artist no closer than",
                       value: $model.minArtistGap, range: 1...6, suffix: "tracks")
            stepperRow(label: "Same album no closer than",
                       value: $model.minAlbumGap, range: 1...5, suffix: "tracks")
            stepperRow(label: "Largest BPM jump",
                       value: $model.maxBPMJump, range: 2...20, step: 0.5, suffix: "BPM")
            keyStrictnessRow
            Toggle("Only fully-downloaded tracks", isOn: $model.requireCached)
                .font(.system(size: 12.5))
            Toggle("Allow explicit", isOn: $model.allowExplicit)
                .font(.system(size: 12.5))
        }
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    func stepperRow(label: String, value: Binding<Int>, range: ClosedRange<Int>,
                    suffix: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12.5))
            Spacer()
            Stepper("\(value.wrappedValue) \(suffix)",
                    value: value, in: range)
                .font(.system(size: 12, design: .monospaced))
                .fixedSize()
        }
    }

    func stepperRow(label: String, value: Binding<Double>, range: ClosedRange<Double>,
                    step: Double, suffix: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12.5))
            Spacer()
            Stepper(String(format: "%.1f %@", value.wrappedValue, suffix),
                    value: value, in: range, step: step)
                .font(.system(size: 12, design: .monospaced))
                .fixedSize()
        }
    }

    var keyStrictnessRow: some View {
        HStack {
            Text("Key continuity")
                .font(.system(size: 12.5))
            Spacer()
            Slider(value: $model.keyStrictness, in: 0...1)
                .frame(width: 110)
            Text("\(Int(model.keyStrictness * 100))%")
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 36, alignment: .trailing)
        }
    }
}
