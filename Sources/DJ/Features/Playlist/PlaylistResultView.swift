import SwiftUI

/// The generated sequence (§41.7, mockup `ipad/05b-autoplaylist-result.html`;
/// compact class §42.4/`iphone/03-autoplaylist.html`). Free tier.
///
/// The sequence is plotted against the requested arc so a mismatch is visible
/// rather than asserted (FR-PLIST-5); every transition carries its Camelot
/// relationship and BPM delta (roughest joins visible); per-row lock / replace /
/// reject are constrained re-runs (§28A.4), not re-rolls; the footer carries the
/// total-vs-target, mean transition cost, the AT-PLIST-3 "smoother than shuffle"
/// language and the honest short-pool state (plan §2.7). FR-PLIST-10's "Blend
/// these" card is dismissible, session-scoped, and inert in M3 (StoreKit is M4).
public struct PlaylistResultView: View {
    @ObservedObject var model: AutoPlaylistModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showSavePlaylistPrompt = false
    @State private var showSaveCratePrompt = false
    @State private var playlistTitle = ""
    @State private var crateName = ""
    @State private var showBlendAlert = false

    public init(model: AutoPlaylistModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if sizeClass == .compact { compactHeader } else { regularHeader }
            arcCard
            if sizeClass == .compact { compactChips }
            trackList
            footer
            if model.showsBlendCard { blendCard }
        }
        .alert("Save as Playlist", isPresented: $showSavePlaylistPrompt) {
            TextField("Playlist name", text: $playlistTitle)
            Button("Save") { savePlaylist() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Name this Smart Crate", isPresented: $showSaveCratePrompt) {
            TextField("e.g. Dinner set", text: $crateName)
            Button("Save") { model.saveAsSmartCrate(name: crateName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A crate is the brief, not a copy — it keeps finding new matches as your library grows.")
        }
        .alert("Platterhead DJ", isPresented: $showBlendAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Blending arrives in a later release. Everything you're doing here stays free.")
        }
    }

    // MARK: - Header

    private var regularHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.resultTitle)
                    .font(.system(size: 22, weight: .bold))
                Text("“\(model.prompt)”")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if let seconds = model.generationSecondsText {
                Text(seconds)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.cyan.opacity(0.15), in: Capsule())
                    .foregroundStyle(.cyan)
            }
            Button {
                model.onPlay?(model.rows)
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            Button {
                playlistTitle = model.resultTitle
                showSavePlaylistPrompt = true
            } label: {
                Label("Save as Playlist", systemImage: "list.bullet")
            }
            .buttonStyle(.bordered)
            Button {
                crateName = ""
                showSaveCratePrompt = true
            } label: {
                Label("Save as Smart Crate", systemImage: "tray.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
        }
    }

    private var compactHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(model.resultTitle)
                .font(.system(size: 22, weight: .bold))
            Text("“\(model.prompt)”")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    // MARK: - Arc card (requested vs delivered, FR-PLIST-5)

    private var arcCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(sizeClass == .compact ? "Arc — asked vs got" : "Energy arc — requested vs delivered")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 10) {
                    legendItem(color: .indigo, label: "requested", line: true)
                    legendItem(color: .cyan, label: "actual", line: false)
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                if let arcError = model.arcError {
                    Text(String(format: "arc error %.2f", arcError))
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.15), in: Capsule())
                        .foregroundStyle(.green)
                }
            }
            ArcPlotView(arc: model.arc, rows: model.rows,
                        showPeakMarker: sizeClass != .compact)
                .frame(height: sizeClass == .compact ? 62 : 150)
            HStack {
                Text("\(AutoPlaylistModel.durationText(Double(model.totalSeconds))) of \(model.targetSummaryText)")
                    .font(.system(size: 11, design: .monospaced))
                Spacer()
                Text("\(model.rows.count) tracks · \(smootherLine)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func legendItem(color: Color, label: String, line: Bool) -> some View {
        HStack(spacing: 4) {
            Group {
                if line {
                    Rectangle()
                        .fill(color)
                        .frame(width: 12, height: 2.5)
                } else {
                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                }
            }
            Text(label)
        }
    }

    private var smootherLine: String {
        model.smootherThanShuffleText ?? "smoother than shuffle — measuring"
    }

    // MARK: - Compact chips (§42.4)

    private var compactChips: some View {
        FlowLayout(spacing: 6) {
            ForEach(model.chips.prefix(3)) { chip in
                Text(chip.label)
                    .font(.system(size: 10.5))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(chipKindColor(chip.kind).opacity(0.14), in: Capsule())
                    .foregroundStyle(chipKindColor(chip.kind))
            }
            if model.chips.count > 3 {
                Text("+\(model.chips.count - 3)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func chipKindColor(_ kind: BriefChip.Kind) -> Color {
        switch kind {
        case .positive: return .blue
        case .negative: return .orange
        case .arc: return .indigo
        default: return .primary
        }
    }

    // MARK: - Track list

    private var trackList: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                if sizeClass == .compact {
                    compactRow(row, previous: index > 0 ? model.rows[index - 1] : nil)
                } else {
                    regularRow(row, previous: index > 0 ? model.rows[index - 1] : nil)
                }
                if index < model.rows.count - 1 {
                    Divider()
                }
            }
        }
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Full table (mockup `ipad/05b`): position, lock, title, artist, BPM, key,
    /// energy bar, transition-in badge, and the per-row ⟳ / ✕ actions.
    private func regularRow(_ row: AutoPlaylistRow, previous: AutoPlaylistRow?) -> some View {
        HStack(spacing: 12) {
            Text("\(row.position + 1)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)
            lockIcon(row)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(row.artistNames)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(bpmText(row))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
            Text(row.camelot ?? "—")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
            energyBar(row)
                .frame(width: 52)
            if let content = transitionContent(previous: previous, current: row) {
                Text(content.0)
                    .font(.system(size: 10))
                    .foregroundStyle(content.1.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(content.1.color.opacity(0.14), in: Capsule())
                    .frame(width: 120, alignment: .leading)
            } else {
                Color.clear.frame(width: 120)
            }
            HStack(spacing: 8) {
                Button { Task { await model.replaceSlot(slot: row.position) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                Button { Task { await model.reject(trackID: row.trackID) } } label: {
                    Image(systemName: "xmark")
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .foregroundStyle(.secondary)
            .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Compact row (mockup `iphone/03`): position, title + artist·BPM·key, and a
    /// trailing transition pill or lock icon; the row's actions live in a swipe.
    private func compactRow(_ row: AutoPlaylistRow, previous: AutoPlaylistRow?) -> some View {
        HStack(spacing: 10) {
            Text("\(row.position + 1)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(row.artistNames)
                        .lineLimit(1)
                    if let bpm = row.bpm {
                        Text(String(format: "· %.0f", bpm))
                    }
                    if let key = row.camelot {
                        Text("· \(key)")
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.isLocked(at: row.position) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.indigo)
            } else if let content = transitionContent(previous: previous, current: row) {
                Text(content.0)
                    .font(.system(size: 10))
                    .foregroundStyle(content.1.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(content.1.color.opacity(0.14), in: Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                Task { await model.reject(trackID: row.trackID) }
            } label: {
                Label("Reject", systemImage: "xmark")
            }
            .tint(.red)
            Button {
                Task { await model.replaceSlot(slot: row.position) }
            } label: {
                Label("Replace", systemImage: "arrow.clockwise")
            }
            .tint(.orange)
            Button {
                model.toggleLock(at: row.position)
            } label: {
                Label(model.isLocked(at: row.position) ? "Unlock" : "Lock",
                      systemImage: model.isLocked(at: row.position) ? "lock.open" : "lock")
            }
            .tint(.indigo)
        }
    }

    private func lockIcon(_ row: AutoPlaylistRow) -> some View {
        Button {
            model.toggleLock(at: row.position)
        } label: {
            Image(systemName: model.isLocked(at: row.position) ? "lock.fill" : "lock")
                .font(.system(size: 12))
                .foregroundStyle(model.isLocked(at: row.position) ? .indigo : .secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(model.isLocked(at: row.position) ? "Unlock \(row.title)" : "Lock \(row.title)")
    }

    private func bpmText(_ row: AutoPlaylistRow) -> String {
        guard let bpm = row.bpm else { return "—" }
        return String(format: "%.1f", bpm)
    }

    private func energyBar(_ row: AutoPlaylistRow) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(energyColor(row.actualEnergy))
                    .frame(width: max(3, geo.size.width * row.actualEnergy))
            }
        }
        .frame(height: 6)
    }

    private func energyColor(_ value: Double) -> Color {
        if value >= 0.66 { return .orange }
        if value >= 0.33 { return .green }
        return .cyan
    }

    /// The transition-in badge: the Camelot relationship + signed BPM delta of
    /// this join, with the roughest joins visibly marked (FR-PLIST-5). The seed
    /// row's join is the neutral "— seed —".
    private func transitionContent(previous: AutoPlaylistRow?,
                                   current: AutoPlaylistRow) -> (String, TransitionSeverity)? {
        if current.isSeed {
            return ("— seed —", .neutral)
        }
        guard let previous else { return nil }
        return Self.transitionText(previous: previous, current: current)
    }

    /// The Camelot + BPM join description (§41.7). One scoring/formatting
    /// implementation shared with the compact row; nothing musical is computed
    /// twice (§49.3).
    static func transitionText(previous: AutoPlaylistRow, current: AutoPlaylistRow)
        -> (String, TransitionSeverity) {
        let keyText: String
        var severity = TransitionSeverity.good
        if let prevKey = previous.camelot.flatMap(CamelotKey.init(code:)),
           let currentKey = current.camelot.flatMap(CamelotKey.init(code:)) {
            let compatibility = Camelot.compatibility(prevKey, currentKey)
            if compatibility == 1.0 {
                keyText = "same key"
            } else if compatibility == 0.9 {
                keyText = "relative"
            } else if compatibility == 0.7 {
                keyText = "adjacent"
            } else if compatibility == 0.5 {
                keyText = "energy boost"
            } else {
                keyText = "\(wheelSteps(prevKey, currentKey)) steps"
                severity = .work
            }
        } else {
            keyText = "—"
        }

        let bpmText: String
        if let prevBPM = previous.bpm, let currentBPM = current.bpm {
            let delta = currentBPM - prevBPM
            bpmText = String(format: "%+.1f", delta)
            if abs(delta) >= 6 { severity = .work }
        } else {
            bpmText = "—"
        }
        return ("\(keyText) · \(bpmText)", severity)
    }

    /// The fewest steps around the 12-position wheel, ignoring letter.
    static func wheelSteps(_ a: CamelotKey, _ b: CamelotKey) -> Int {
        let raw = abs(a.number - b.number)
        return min(raw, 12 - raw)
    }

    enum TransitionSeverity {
        case good
        case work
        case neutral

        var color: Color {
            switch self {
            case .good: return .green
            case .work: return .orange
            case .neutral: return .secondary
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(footerLine)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if model.isShortPool {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Could only fill \(model.rows.count) of \(model.requestedCount) tracks — nothing was padded in that doesn't fit the brief.")
                }
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            }

            if sizeClass == .compact {
                HStack(spacing: 8) {
                    Button {
                        playlistTitle = model.resultTitle
                        showSavePlaylistPrompt = true
                    } label: {
                        Label("Save", systemImage: "list.bullet")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        model.onPlay?(model.rows)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            } else {
                HStack(spacing: 8) {
                    Button { Task { await model.extend(minutes: 30) } } label: {
                        Label("Extend +30 min", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    Button { Task { await model.reshuffle(from: 1, to: max(0, model.rows.count - 2)) } } label: {
                        Label("Reshuffle the middle", systemImage: "shuffle")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
                .controlSize(.small)
            }
        }
        .padding(.top, 2)
    }

    private var footerLine: String {
        var parts = ["\(model.rows.count) tracks",
                     "\(AutoPlaylistModel.durationText(Double(model.totalSeconds))) of \(model.targetSummaryText)"]
        if let delta = model.durationDeltaPercent {
            parts.append(String(format: "(%+.1f%%)", delta))
        }
        if let cost = model.meanTransitionCost {
            parts.append(String(format: "mean transition cost %.2f", cost))
        }
        if let smoother = model.smootherThanShuffleText {
            parts.append(smoother)
        }
        if model.rejectionCount > 0 {
            parts.append("\(model.rejectionCount) rejected and remembered")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - FR-PLIST-10 (dismissible, inert in M3)

    private var blendCard: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 20))
                .foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 2) {
                Text("Want these to actually blend into each other?")
                    .font(.system(size: 13, weight: .semibold))
                Text("Platterhead DJ turns this playlist into a gig crate: two decks, beatmatched transitions at the points already scored above. One-time purchase — coming in 3.0.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Coming in 3.0") { showBlendAlert = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button("Not now") { model.dismissBlendCard() }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.indigo.opacity(0.4), lineWidth: 1))
    }

    private func savePlaylist() {
        let title = playlistTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        Task { await model.saveAsPlaylist(title: title) }
    }
}

// MARK: - Plotting helpers

/// The requested arc (solid) overlaid with the delivered sequence (dashed dots),
/// so a mismatch is visible rather than asserted (FR-PLIST-5, §41.7).
struct ArcPlotView: View {
    let arc: EnergyArc
    let rows: [AutoPlaylistRow]
    var showPeakMarker = true

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .topLeading) {
                gridLines(width: w, height: h)
                ArcShape(arc: arc, sampleCount: 80)
                    .stroke(Color.indigo, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                actualPath(width: w, height: h)
                    .stroke(Color.cyan.opacity(0.8),
                            style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                actualDots(width: w, height: h)
                if showPeakMarker, case .peakAndRelease(let peakAt) = arc {
                    peakMarker(at: peakAt, width: w, height: h)
                }
            }
        }
    }

    private func gridLines(width: CGFloat, height: CGFloat) -> some View {
        Path { path in
            for fraction in stride(from: 0, through: 1, by: 0.25) {
                let y = height * fraction
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: width, y: y))
            }
        }
        .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
    }

    private func pointX(_ position: Int, width: CGFloat) -> CGFloat {
        guard rows.count > 1 else { return width / 2 }
        return CGFloat(position) / CGFloat(rows.count - 1) * width
    }

    private func pointY(_ energy: Double, height: CGFloat) -> CGFloat {
        (1 - CGFloat(min(1, max(0, energy)))) * height
    }

    private func actualPath(width: CGFloat, height: CGFloat) -> Path {
        var path = Path()
        for (index, row) in rows.enumerated() {
            let x = pointX(row.position, width: width)
            let y = pointY(row.actualEnergy, height: height)
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }

    private func actualDots(width: CGFloat, height: CGFloat) -> some View {
        ForEach(rows, id: \.trackID) { row in
            Circle()
                .fill(Color.cyan)
                .frame(width: 5, height: 5)
                .position(x: pointX(row.position, width: width),
                          y: pointY(row.actualEnergy, height: height))
        }
    }

    private func peakMarker(at peakAt: Double, width: CGFloat, height: CGFloat) -> some View {
        let x = CGFloat(peakAt) * width
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: height))
            }
            .stroke(Color.yellow.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            Text("peak · \(Int((peakAt * 100).rounded()))%")
                .font(.system(size: 9))
                .foregroundStyle(.yellow)
                .position(x: min(x + 42, width - 20), y: 10)
        }
    }
}
