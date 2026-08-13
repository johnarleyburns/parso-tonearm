import SwiftUI

/// The §26A.5 view-1 overview: the whole track at fixed scale — band-coloured
/// coarse bins, cues and the active loop — with a position cursor at the
/// playhead. Tapping seeks, quantised to the deck's grid (§33): the tap snaps
/// to the nearest grid beat, the same boundary the engine quantises to.
///
/// `model` is nil for an unanalysed track: the strip draws the honest empty
/// state, never synthetic geometry (§26A.1).
public struct OverviewStrip: View {
    let model: WaveformRenderModel?
    let playhead: Int64
    var onSeek: ((Int64) -> Void)?

    public init(model: WaveformRenderModel?,
                playhead: Int64,
                onSeek: ((Int64) -> Void)? = nil) {
        self.model = model
        self.playhead = playhead
        self.onSeek = onSeek
    }

    public var body: some View {
        GeometryReader { proxy in
            if let model, model.durationSamples > 0 {
                let samplesPerPoint = Double(model.durationSamples) / max(proxy.size.width, 1)
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.white.opacity(0.04))
                    Canvas { context, size in
                        WaveformDraw.bins(model: model,
                                          windowStart: 0,
                                          samplesPerPoint: samplesPerPoint,
                                          size: size,
                                          into: &context)
                        WaveformDraw.markers(model: model,
                                             windowStart: 0,
                                             samplesPerPoint: samplesPerPoint,
                                             size: size,
                                             into: &context)
                    }
                    Rectangle()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 1.5)
                        .position(x: WaveformGeometry.x(sample: playhead,
                                                        windowStart: 0,
                                                        samplesPerPoint: samplesPerPoint),
                                  y: proxy.size.height / 2)
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    let sample = WaveformGeometry.sample(atX: location.x,
                                                         windowStart: 0,
                                                         samplesPerPoint: samplesPerPoint)
                    onSeek?(Self.quantisedSeekTarget(sample: sample, model: model))
                }
            } else {
                Text("No waveform yet")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.04)))
            }
        }
    }

    /// §26A.5: a tap seeks, quantised per §33 — snap to the nearest grid beat
    /// (the model's composed beats, what the engine quantises to). Pure so the
    /// seek resolution is testable off-device.
    public static func quantisedSeekTarget(sample: Int64, model: WaveformRenderModel) -> Int64 {
        guard !model.beats.isEmpty else { return sample }
        var best = model.beats[0]
        var bestDistance = abs(sample - best)
        for beat in model.beats {
            let distance = abs(sample - beat)
            if distance < bestDistance {
                bestDistance = distance
                best = beat
            }
        }
        return best
    }
}
