import SwiftUI

// MARK: - Arc card (requested vs delivered, FR-PLIST-5) and compact chips (§42.4)

extension PlaylistResultView {
    var arcCard: some View {
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

    func legendItem(color: Color, label: String, line: Bool) -> some View {
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

    var smootherLine: String {
        model.smootherThanShuffleText ?? "smoother than shuffle — measuring"
    }

    var compactChips: some View {
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

    func chipKindColor(_ kind: BriefChip.Kind) -> Color {
        switch kind {
        case .positive: return .blue
        case .negative: return .orange
        case .arc: return .indigo
        default: return .primary
        }
    }
}
