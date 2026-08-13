import SwiftUI

/// The §26A.4 phrase ribbon: the §25 segmentation as labelled, coloured spans
/// drawn above the waveform.
///
/// Rules (all normative):
/// - The ribbon spans the **overview** waveform (whole track) at all times, so
///   the next drop is visible before it arrives — this is the display's main
///   tactical value.
/// - Each span shows its length in **bars**, not seconds — DJs phrase in bars
///   (`32`, not `62 s`).
/// - A span whose `confidence` is below the display threshold renders with a
///   dashed edge rather than being hidden — the honest signal is "boundary
///   uncertain", not silence.
/// - The ribbon is **free-tier** (FR-WAVE-4 — information about your music).
public struct PhraseRibbon: View {
    let model: WaveformRenderModel?
    let windowStart: Int64
    let visibleSamples: Double
    var halveLabels: Bool

    public init(model: WaveformRenderModel?,
                windowStart: Int64,
                visibleSamples: Double,
                halveLabels: Bool = false) {
        self.model = model
        self.windowStart = windowStart
        self.visibleSamples = visibleSamples
        self.halveLabels = halveLabels
    }

    public var body: some View {
        GeometryReader { proxy in
            let samplesPerPoint = max(visibleSamples / max(proxy.size.width, 1), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.04))
                if let model, !model.phrases.isEmpty {
                    Canvas { context, size in
                        let skipEvery = halveLabels ? 2 : 1
                        for (index, phrase) in model.phrases.enumerated() {
                            let x0 = WaveformGeometry.x(sample: phrase.startSample,
                                                        windowStart: Double(windowStart),
                                                        samplesPerPoint: samplesPerPoint)
                            let x1 = WaveformGeometry.x(sample: phrase.endSample,
                                                        windowStart: Double(windowStart),
                                                        samplesPerPoint: samplesPerPoint)
                            guard x1 > 0, x0 < size.width, x1 > x0 else { continue }
                            let rect = CGRect(x: x0, y: 1,
                                              width: max(0, x1 - x0),
                                              height: size.height - 2)
                            let colour = Self.colour(for: phrase.type)
                            context.fill(Path(rect), with: .color(colour.opacity(0.18)))

                            // §26A.4: a low-confidence boundary is marked with
                            // dashed edges, never hidden.
                            var edges = Path()
                            edges.move(to: CGPoint(x: x0, y: 0))
                            edges.addLine(to: CGPoint(x: x0, y: size.height))
                            edges.move(to: CGPoint(x: x1, y: 0))
                            edges.addLine(to: CGPoint(x: x1, y: size.height))
                            if phrase.isLowConfidence {
                                context.stroke(edges, with: .color(colour.opacity(0.95)),
                                               style: StrokeStyle(lineWidth: 1.2, dash: [2, 2]))
                            } else {
                                context.stroke(edges, with: .color(colour.opacity(0.6)),
                                               lineWidth: 1.2)
                            }

                            if (index % skipEvery) == 0 {
                                // §26A.4: length in bars, not seconds.
                                let label = context.resolve(Text("\(phrase.barCount)")
                                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                                    .foregroundStyle(colour.opacity(0.95)))
                                context.draw(label, at: CGPoint(x: x0 + 2, y: 1),
                                             anchor: .topLeading)
                            }
                        }
                    }
                } else {
                    Text("No phrase map yet")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .padding(.leading, 6)
                }
            }
            .clipped()
        }
    }

    /// The §26A.4 colour roles.
    static func colour(for type: PhraseType) -> Color {
        switch type {
        case .intro, .outro: return Color(white: 0.62)
        case .build: return Color(red: 1.0, green: 0.66, blue: 0.18)
        case .drop: return Color(red: 1.0, green: 0.30, blue: 0.30)
        case .chorus: return Color(red: 0.40, green: 0.80, blue: 0.50)
        case .breakdown: return Color(red: 0.35, green: 0.55, blue: 0.95)
        }
    }
}
