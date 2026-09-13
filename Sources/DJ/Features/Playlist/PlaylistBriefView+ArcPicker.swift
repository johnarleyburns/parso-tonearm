import SwiftUI

// MARK: - Energy arc picker (§28A.5)

extension PlaylistBriefView {
    var arcPicker: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Energy arc")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 9)],
                      spacing: 9) {
                ForEach(arcPresets, id: \.name) { preset in
                    arcCard(name: preset.name, arc: preset.arc)
                }
            }

            arcParameterControls

            Text("Arcs map onto your library's energy range, not an absolute scale — \"high\" means the most energetic thing that fits the brief.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    struct ArcPreset {
        let name: String
        let arc: EnergyArc
    }

    var arcPresets: [ArcPreset] {
        [
            ArcPreset(name: "Steady", arc: .steady(level: steadyLevel)),
            ArcPreset(name: "Build", arc: .build),
            ArcPreset(name: "Peak & release", arc: .peakAndRelease(peakAt: peakAt)),
            ArcPreset(name: "Wind down", arc: .windDown),
            ArcPreset(name: "Wave", arc: .wave(cycles: waveCycles)),
            ArcPreset(name: "Draw your own", arc: .custom(points: customPoints)),
        ]
    }

    func arcCard(name: String, arc: EnergyArc) -> some View {
        let selected = model.arc.kindCode == arc.kindCode
        return Button {
            model.arc = arc
        } label: {
            VStack(spacing: 6) {
                ArcShape(arc: arc)
                    .stroke(selected ? Color.indigo : Color.secondary,
                            style: StrokeStyle(lineWidth: 2,
                                               dash: arc.kindCode == "custom" ? [3, 3] : []))
                    .frame(height: 32)
                    .padding(.horizontal, 4)
                Text(name)
                    .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.indigo : Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(selected ? Color.indigo.opacity(0.12) : Color.gray.opacity(0.16),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? Color.indigo.opacity(0.7) : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name) arc\(selected ? ", selected" : "")")
    }

    @ViewBuilder
    var arcParameterControls: some View {
        switch model.arc {
        case .steady:
            controlSlider(title: "Level",
                          value: steadyBinding,
                          range: 0...1) { Int($0 * 100).description + "%" }
        case .peakAndRelease:
            VStack(alignment: .leading, spacing: 6) {
                controlSlider(title: "Peak at",
                              value: peakBinding,
                              range: 0.05...0.95) { Int($0 * 100).description + "%" }
                Text("Drag the marker on the plot to move it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .wave:
            controlSlider(title: "Cycles",
                          value: cyclesBinding,
                          range: 0.5...3) { String(format: "%.1f", $0) }
        case .custom:
            DrawArcView(points: customPointsBinding)
                .frame(height: 120)
            Button("Reset") { model.arc = .custom(points: [Double](repeating: 0.5, count: 12)) }
                .font(.system(size: 12))
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .build, .windDown:
            EmptyView()
        }
    }

    func controlSlider(title: String, value: Binding<Double>, range: ClosedRange<Double>,
                       text: @escaping (Double) -> String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12))
            Slider(value: value, in: range)
            Text(text(value.wrappedValue))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 44, alignment: .trailing)
        }
    }

    var steadyLevel: Double {
        if case .steady(let level) = model.arc { return level }
        return EnergyArc.defaultLevel
    }

    var peakAt: Double {
        if case .peakAndRelease(let peakAt) = model.arc { return peakAt }
        return EnergyArc.defaultPeakAt
    }

    var waveCycles: Double {
        if case .wave(let cycles) = model.arc { return cycles }
        return EnergyArc.defaultCycles
    }

    var customPoints: [Double] {
        if case .custom(let points) = model.arc { return points }
        return [Double](repeating: 0.5, count: 12)
    }

    var steadyBinding: Binding<Double> {
        Binding(get: { steadyLevel }, set: { model.arc = .steady(level: $0) })
    }

    var peakBinding: Binding<Double> {
        Binding(get: { peakAt }, set: { model.arc = .peakAndRelease(peakAt: $0) })
    }

    var cyclesBinding: Binding<Double> {
        Binding(get: { waveCycles }, set: { model.arc = .wave(cycles: $0) })
    }

    var customPointsBinding: Binding<[Double]> {
        Binding(get: { customPoints }, set: { model.arc = .custom(points: $0) })
    }
}
