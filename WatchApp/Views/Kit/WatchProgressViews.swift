import SwiftUI

/// Watch redesign §3 — a read-only 3 pt progress line with tabular times underneath. No scrubbing
/// on the watch.
struct WatchProgressHairline: View {
    let elapsed: Double
    let duration: Double
    var tint: Color = .primary
    var showsTimes = true

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18))
                    Capsule().fill(tint).frame(width: max(0, geo.size.width * fraction))
                }
            }
            .frame(height: 3)
            .accessibilityHidden(true)
            if showsTimes {
                HStack {
                    Text(WatchTimeFmt.mmss(elapsed))
                        .accessibilityIdentifier("watch.now.elapsed")
                        .accessibilityValue(WatchTimeFmt.mmss(elapsed))
                    Spacer()
                    Text(verbatim: "-\(WatchTimeFmt.mmss(max(0, duration - elapsed)))")
                        .accessibilityIdentifier("watch.now.remaining")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Progress"))
        .accessibilityValue(Text("\(WatchTimeFmt.mmss(elapsed)) of \(WatchTimeFmt.mmss(duration))"))
    }

    private var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, elapsed / duration))
    }
}

/// A 22 pt ring that closes with real byte or item progress, or an indeterminate spinner before the
/// first byte (§3 `TransferRing`).
struct WatchTransferRing: View {
    let fraction: Double?
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: 3)
            if let fraction {
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, fraction)))
                    .stroke(WatchPalette.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.35), value: fraction)
            } else {
                ProgressView().scaleEffect(0.5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(Text("Download progress"))
        .accessibilityValue(fraction.map { Text("\(Int(($0 * 100).rounded())) percent") } ?? Text("Starting"))
    }
}

/// Rounded artwork thumbnail with a gradient placeholder from the accent (§3 `ArtTile`).
struct WatchArtTile: View {
    var image: UIImage?
    var tint: Color?
    var size: CGFloat = 32
    var systemImage = "music.note"

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [(tint ?? WatchPalette.accent).opacity(0.85),
                                            (tint ?? WatchPalette.accent).opacity(0.25)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: systemImage)
                        .font(size > 34 ? .body : .caption)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// A stable, pleasant tint per collection name, for placeholder art (no artwork is synced per
/// playlist to the watch).
enum WatchArtTint {
    static func color(for key: String) -> Color {
        let hues: [Double] = [0.04, 0.08, 0.55, 0.62, 0.78, 0.92, 0.33, 0.12]
        let index = Int(key.unicodeScalars.reduce(UInt32(0)) { ($0 &* 31) &+ $1.value } % UInt32(hues.count))
        return Color(hue: hues[index], saturation: 0.55, brightness: 0.75)
    }
}
