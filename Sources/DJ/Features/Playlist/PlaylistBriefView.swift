import SwiftUI

/// The auto-playlist brief (§41.6, mockup `ipad/05a-autoplaylist-brief.html`;
/// compact class §42.4/`iphone/03-autoplaylist.html`). Free tier.
///
/// Natural-language brief → editable "what we understood" chips (§28A.6), the
/// energy-arc picker (six presets incl. draw-your-own, peak marker draggable),
/// the length (duration slider with the ±5% honesty, or a track count), the
/// constraint toggles, and "start from" a seed track. Phone and iPad share the
/// one `AutoPlaylistModel`; on the compact class the generated result renders
/// inline below the form (separated by the generate action, §42.4), on the
/// regular class it pushes to `PlaylistResultView`.
public struct PlaylistBriefView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @StateObject private var model: AutoPlaylistModel
    @State private var showSeedPicker = false
    @State private var seedSearch = ""
    @State private var pushResult = false

    public init(model: AutoPlaylistModel) {
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                briefField
                understoodChips
                arcPicker
                lengthCard
                constraintsCard
                seedCard
                generateButton
                privacyNote
                if sizeClass == .compact, model.generation != nil {
                    Divider()
                        .padding(.vertical, 6)
                    PlaylistResultView(model: model)
                }
            }
            .padding(20)
        }
        .navigationTitle("Make me a playlist")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Text("Free")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.blue.opacity(0.15), in: Capsule())
                    .foregroundStyle(.blue)
                    .accessibilityLabel("Free feature")
            }
        }
        .navigationDestination(isPresented: $pushResult) {
            ScrollView {
                PlaylistResultView(model: model)
                    .padding(20)
            }
            .navigationTitle(model.resultTitle)
        }
        .sheet(isPresented: $showSeedPicker) {
            NavigationStack {
                seedPicker
            }
        }
    }

    // MARK: - Brief field

    private var briefField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("In your own words")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("e.g. two hours for a dinner party — starts warm and conversational, builds after the food…",
                      text: $model.prompt,
                      axis: .vertical)
                .lineLimit(4...8)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .padding(14)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.indigo.opacity(0.5), lineWidth: 1))
        }
    }

    // MARK: - Chips (§28A.6, inspectable + editable)

    private var understoodChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What we understood — tap to drop")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            if model.chips.isEmpty {
                Text("Nothing to show yet — everything you write also goes to the search model unchanged.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(model.chips) { chip in
                        chipView(chip)
                    }
                }
            }
            Text("Everything we didn't recognise still goes to the search model unchanged.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func chipView(_ chip: BriefChip) -> some View {
        Button {
            model.removeChip(chip)
        } label: {
            HStack(spacing: 5) {
                Text(chip.label)
                    .font(.system(size: 12))
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(chipBackground(chip.kind), in: Capsule())
            .foregroundStyle(chipForeground(chip.kind))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Drop \(chip.label)")
    }

    private func chipBackground(_ kind: BriefChip.Kind) -> Color {
        switch kind {
        case .positive: return .blue.opacity(0.12)
        case .negative: return .orange.opacity(0.12)
        case .arc: return .indigo.opacity(0.14)
        default: return .gray.opacity(0.16)
        }
    }

    private func chipForeground(_ kind: BriefChip.Kind) -> Color {
        switch kind {
        case .positive: return .blue
        case .negative: return .orange
        case .arc: return .indigo
        default: return .primary
        }
    }

    // MARK: - Energy arc picker (§28A.5)

    private var arcPicker: some View {
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

    private struct ArcPreset {
        let name: String
        let arc: EnergyArc
    }

    private var arcPresets: [ArcPreset] {
        [
            ArcPreset(name: "Steady", arc: .steady(level: steadyLevel)),
            ArcPreset(name: "Build", arc: .build),
            ArcPreset(name: "Peak & release", arc: .peakAndRelease(peakAt: peakAt)),
            ArcPreset(name: "Wind down", arc: .windDown),
            ArcPreset(name: "Wave", arc: .wave(cycles: waveCycles)),
            ArcPreset(name: "Draw your own", arc: .custom(points: customPoints)),
        ]
    }

    private func arcCard(name: String, arc: EnergyArc) -> some View {
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
    private var arcParameterControls: some View {
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

    private func controlSlider(title: String, value: Binding<Double>, range: ClosedRange<Double>,
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

    private var steadyLevel: Double {
        if case .steady(let level) = model.arc { return level }
        return EnergyArc.defaultLevel
    }

    private var peakAt: Double {
        if case .peakAndRelease(let peakAt) = model.arc { return peakAt }
        return EnergyArc.defaultPeakAt
    }

    private var waveCycles: Double {
        if case .wave(let cycles) = model.arc { return cycles }
        return EnergyArc.defaultCycles
    }

    private var customPoints: [Double] {
        if case .custom(let points) = model.arc { return points }
        return [Double](repeating: 0.5, count: 12)
    }

    private var steadyBinding: Binding<Double> {
        Binding(get: { steadyLevel }, set: { model.arc = .steady(level: $0) })
    }

    private var peakBinding: Binding<Double> {
        Binding(get: { peakAt }, set: { model.arc = .peakAndRelease(peakAt: $0) })
    }

    private var cyclesBinding: Binding<Double> {
        Binding(get: { waveCycles }, set: { model.arc = .wave(cycles: $0) })
    }

    private var customPointsBinding: Binding<[Double]> {
        Binding(get: { customPoints }, set: { model.arc = .custom(points: $0) })
    }

    // MARK: - Length (FR-PLIST-2's T, with ±5% honesty)

    private var lengthCard: some View {
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

    // MARK: - Constraints (§28A.2)

    private var constraintsCard: some View {
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

    private func stepperRow(label: String, value: Binding<Int>, range: ClosedRange<Int>,
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

    private func stepperRow(label: String, value: Binding<Double>, range: ClosedRange<Double>,
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

    private var keyStrictnessRow: some View {
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

    // MARK: - Seed track (§41.6 "Start from")

    private var seedCard: some View {
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

    private var seedPicker: some View {
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

    // MARK: - Generate

    private var generateButton: some View {
        Button {
            Task {
                await model.generate()
                if sizeClass != .compact {
                    pushResult = true
                }
            }
        } label: {
            HStack {
                if model.isGenerating {
                    ProgressView()
                        .controlSize(.small)
                    Text("Generating…")
                } else {
                    Image(systemName: "wand.and.stars")
                    Text(model.generation == nil ? "Generate" : "Regenerate")
                }
            }
            .font(.system(size: 15, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isGenerating || model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var privacyNote: some View {
        Text("Runs entirely on this device · a couple of seconds")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
    }
}

/// A single arc's closed-form curve as a SwiftUI `Shape` — the picker previews
/// and the result plot both draw through it (one geometry, §49.3).
public struct ArcShape: Shape {
    public let arc: EnergyArc
    public var sampleCount = 64

    public init(arc: EnergyArc, sampleCount: Int = 64) {
        self.arc = arc
        self.sampleCount = sampleCount
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        for index in 0...sampleCount {
            let t = Double(index) / Double(sampleCount)
            let x = rect.minX + CGFloat(t) * rect.width
            let y = rect.minY + (1 - CGFloat(arc.value(at: t))) * rect.height
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }
}

/// A "draw your own" canvas: `points` are evenly-spaced values in [0,1]; a drag
/// writes the slot nearest the finger, so the user sketches the shape the
/// `custom` arc interpolates (§28A.5).
public struct DrawArcView: View {
    @Binding var points: [Double]

    public init(points: Binding<[Double]>) {
        _points = points
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let count = max(points.count, 2)
            ZStack(alignment: .topLeading) {
                Color.clear
                gridLines(width: w, height: h)
                polyline(width: w, height: h, count: count)
                    .stroke(Color.indigo, style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            updatePoints(at: value.location, width: w, height: h, count: count)
                        })
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary, lineWidth: 1))
        .accessibilityLabel("Draw your own energy arc")
    }

    private func updatePoints(at location: CGPoint, width: CGFloat, height: CGFloat,
                              count: Int) {
        let t = min(1, max(0, location.x / width))
        let value = min(1, max(0, 1 - location.y / height))
        let index = Int((Double(t) * Double(count - 1)).rounded())
        var updated = points
        if updated.count < count {
            updated = [Double](repeating: 0.5, count: count)
        }
        updated[index] = value
        points = updated
    }

    private func gridLines(width: CGFloat, height: CGFloat) -> some View {
        Path { path in
            for fraction in [0.25, 0.5, 0.75] {
                let y = height * fraction
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: width, y: y))
            }
        }
        .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
    }

    private func polyline(width: CGFloat, height: CGFloat, count: Int) -> Path {
        var path = Path()
        let values = points.count >= count ? points : [Double](repeating: 0.5, count: count)
        for index in values.indices {
            let x = CGFloat(index) / CGFloat(count - 1) * width
            let y = (1 - CGFloat(values[index])) * height
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }
}

/// A minimal left-to-right flow layout for the chips (§41.6).
public struct FlowLayout: Layout {
    public var spacing: CGFloat = 8

    public init(spacing: CGFloat = 8) {
        self.spacing = spacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                             cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                              subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
