import SwiftUI

// MARK: - Track list

extension PlaylistResultView {
    var trackList: some View {
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
    func regularRow(_ row: AutoPlaylistRow, previous: AutoPlaylistRow?) -> some View {
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
    func compactRow(_ row: AutoPlaylistRow, previous: AutoPlaylistRow?) -> some View {
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

    func lockIcon(_ row: AutoPlaylistRow) -> some View {
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

    func bpmText(_ row: AutoPlaylistRow) -> String {
        guard let bpm = row.bpm else { return "—" }
        return String(format: "%.1f", bpm)
    }

    func energyBar(_ row: AutoPlaylistRow) -> some View {
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

    func energyColor(_ value: Double) -> Color {
        if value >= 0.66 { return .orange }
        if value >= 0.33 { return .green }
        return .cyan
    }

    /// The transition-in badge: the Camelot relationship + signed BPM delta of
    /// this join, with the roughest joins visibly marked (FR-PLIST-5). The seed
    /// row's join is the neutral "— seed —".
    func transitionContent(previous: AutoPlaylistRow?,
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
}
