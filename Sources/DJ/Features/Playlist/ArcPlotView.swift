import SwiftUI

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
