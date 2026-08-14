import SwiftUI

// MARK: - Band colours (§26A.2)

extension WaveformBand {
    /// The §26A.2 hue for each band. The split is the mixer EQ's (200 Hz /
    /// 2 kHz), so when the user pulls LOW, the blue is what leaves (§26A.2).
    var color: Color {
        switch self {
        case .low: return Color(red: 0.22, green: 0.62, blue: 1.0)
        case .mid: return Color(red: 1.0, green: 0.66, blue: 0.18)
        case .high: return Color(white: 0.90)
        }
    }
}

/// The Canvas drawing routines for the §26A waveform. All of them read only
/// the `WaveformRenderModel` value and draw with `GraphicsContext` — no audio
/// is touched, and no data array is allocated per frame (§26A.1).
enum WaveformDraw {

    /// The frequency-coloured bars (§26A.2): each bin draws as three stacked
    /// contributions (low/mid/high) normalised to the bin's total energy,
    /// mirrored below the centre line so the waveform reads like audio. The
    /// pyramid level is chosen per frame against the strip's real width
    /// (§26A.7 — the renderer, not the model, knows the rendered width).
    static func bins(model: WaveformRenderModel,
                     windowStart: Double,
                     samplesPerPoint: Double,
                     size: CGSize,
                     into context: inout GraphicsContext) {
        guard !model.pyramid.levels.isEmpty else { return }
        let level = WaveformLevelSelector.level(samplesPerPoint: samplesPerPoint,
                                                thermal: WaveformThermal.current,
                                                pyramid: model.pyramid)
        let bins = model.pyramid.levels[level]
        let binSize = model.pyramid.samplesPerBin(at: level)
        let peak = model.peaks.indices.contains(level) ? model.peaks[level] : 1
        let midY = size.height / 2
        let maxHalf = max(1, size.height / 2 - 1)

        for (index, bin) in bins.enumerated() {
            let x0 = WaveformGeometry.x(sample: Double(index) * binSize,
                                        windowStart: windowStart,
                                        samplesPerPoint: samplesPerPoint)
            if x0 > size.width { break }
            if x0 + 1 < 0 { continue }
            let w = max(1, CGFloat(binSize / max(samplesPerPoint, 1)) - 0.5)
            let half = maxHalf * CGFloat(peak > 0 ? min(1, (abs(bin.max - bin.min) / 2) / peak) : 0)
            let contributions = WaveformBand.contributions(rms: bin.bandRMS)

            // Above the centre: full-opacity stacked bands, low at the base.
            var y = midY
            for band in WaveformBand.allCases {
                let h = half * CGFloat(contributions[band.bandRMSIndex])
                let rect = CGRect(x: x0, y: y - h, width: w, height: h)
                context.fill(Path(rect), with: .color(band.color.opacity(0.92)))
                y -= h
            }
            // Below the centre: the dimmed mirror (the symmetric read).
            y = midY
            for band in WaveformBand.allCases {
                let h = half * CGFloat(contributions[band.bandRMSIndex])
                let rect = CGRect(x: x0, y: y, width: w, height: h)
                context.fill(Path(rect), with: .color(band.color.opacity(0.38)))
                y += h
            }
        }
    }

    /// The §26A.3 beat grid: thin ticks for beats, full-height heavier
    /// downbeats, and bar numbers (every `barNumberEvery`-th downbeat). The
    /// grid is the model's composed beat positions — what the engine quantises
    /// to, always.
    static func grid(model: WaveformRenderModel,
                     windowStart: Double,
                     samplesPerPoint: Double,
                     size: CGSize,
                     barNumberEvery: Int,
                     into context: inout GraphicsContext) {
        guard !model.beats.isEmpty else { return }
        let beatsPerBar = max(1, model.grid.beatsPerBar)
        let downbeatMod = max(0, (model.barNumberOrigin - 1)) % beatsPerBar
        let every = max(1, barNumberEvery)

        for (index, sample) in model.beats.enumerated() {
            let x = WaveformGeometry.x(sample: sample,
                                       windowStart: windowStart,
                                       samplesPerPoint: samplesPerPoint)
            if x > size.width { break }
            if x < 0 { continue }
            let isDownbeat = index % beatsPerBar == downbeatMod
            var path = Path()
            path.move(to: CGPoint(x: x, y: isDownbeat ? 0 : size.height * 0.22))
            path.addLine(to: CGPoint(x: x, y: isDownbeat ? size.height : size.height * 0.78))
            context.stroke(path,
                           with: .color(isDownbeat ? Color.orange.opacity(0.85)
                                                   : Color.white.opacity(0.28)),
                           lineWidth: isDownbeat ? 1.4 : 0.7)
            if isDownbeat {
                let barNumber = model.barNumberOrigin + index / beatsPerBar
                if barNumber % every == 0 {
                    let text = context.resolve(Text("\(barNumber)")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6)))
                    context.draw(text, at: CGPoint(x: x + 2, y: 2), anchor: .topLeading)
                }
            }
        }
    }

    /// The §26A.6 markers: hot cues as full-height coloured markers with their
    /// pad letter, and the active loop as a translucent region with hard edges.
    static func markers(model: WaveformRenderModel,
                        windowStart: Double,
                        samplesPerPoint: Double,
                        size: CGSize,
                        into context: inout GraphicsContext) {
        if let loop = model.activeLoop {
            let x0 = WaveformGeometry.x(sample: loop.start,
                                        windowStart: windowStart,
                                        samplesPerPoint: samplesPerPoint)
            let x1 = WaveformGeometry.x(sample: loop.end,
                                        windowStart: windowStart,
                                        samplesPerPoint: samplesPerPoint)
            let rect = CGRect(x: x0, y: 2, width: max(0, x1 - x0), height: size.height - 4)
            if rect.maxX > 0 && rect.minX < size.width {
                context.fill(Path(rect), with: .color(Color.accentColor.opacity(0.16)))
            }
        }
        for cue in model.cues {
            let x = WaveformGeometry.x(sample: cue.sample,
                                       windowStart: windowStart,
                                       samplesPerPoint: samplesPerPoint)
            if x < 0 || x > size.width { continue }
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: .color(Color.pink.opacity(0.9)), lineWidth: 1.5)
            if !cue.label.isEmpty {
                let text = context.resolve(Text(cue.label)
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(.pink))
                context.draw(text, at: CGPoint(x: x + 2, y: 2), anchor: .topLeading)
            }
        }
    }
}

// MARK: - Detail waveform (§26A.5 view 2)

/// The detail (performance/preparation) waveform — frequency-coloured bins,
/// the beat grid, cues, the active loop and a playhead. `model` is nil when
/// the deck has no track or the track is unanalysed: the strip draws the
/// **honest empty state** — text, never synthetic geometry (§26A.1, FR-WAVE-1).
///
/// The window `[windowStart, windowStart + visibleSamples)` scrolls under a
/// **fixed-centre playhead** (§26A.5); `playhead` comes from telemetry at draw
/// time while the model stays static, so the canvas never re-assembles data
/// per frame.
public struct WaveformDetailView: View {
    let model: WaveformRenderModel?
    let windowStart: Int64
    let visibleSamples: Double
    let playhead: Int64
    var barNumberEvery: Int
    var emptyTitle: String
    var emptyMessage: String

    public init(model: WaveformRenderModel?,
                windowStart: Int64,
                visibleSamples: Double,
                playhead: Int64,
                barNumberEvery: Int = 4,
                emptyTitle: String = "Not analysed yet",
                emptyMessage: String = "Analyse to draw the waveform here") {
        self.model = model
        self.windowStart = windowStart
        self.visibleSamples = visibleSamples
        self.playhead = playhead
        self.barNumberEvery = barNumberEvery
        self.emptyTitle = emptyTitle
        self.emptyMessage = emptyMessage
    }

    public var body: some View {
        GeometryReader { proxy in
            let samplesPerPoint = max(visibleSamples / max(proxy.size.width, 1), 1)
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.05))

                if let model {
                    Canvas { context, size in
                        WaveformDraw.bins(model: model,
                                          windowStart: Double(windowStart),
                                          samplesPerPoint: samplesPerPoint,
                                          size: size,
                                          into: &context)
                        WaveformDraw.grid(model: model,
                                          windowStart: Double(windowStart),
                                          samplesPerPoint: samplesPerPoint,
                                          size: size,
                                          barNumberEvery: barNumberEvery,
                                          into: &context)
                        WaveformDraw.markers(model: model,
                                             windowStart: Double(windowStart),
                                             samplesPerPoint: samplesPerPoint,
                                             size: size,
                                             into: &context)
                    }
                } else {
                    VStack(spacing: 3) {
                        Text(emptyTitle)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(emptyMessage)
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary.opacity(0.75))
                            .lineLimit(1)
                    }
                }

                // The fixed-centre playhead — the window scrolls under it.
                Rectangle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 1.5)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
            .clipped()
        }
        .accessibilityIdentifier("dj.waveform")
        .coachGlow(identifier: "dj.waveform")
    }
}

// MARK: - Bins-only canvas (the prep surface's background layer)

/// The frequency-coloured bins without the grid/markers/playhead — the layer
/// the Track Prep surface draws its own grid markers and gestures over, so the
/// prep zoom and corrections stay exactly as they were while the analysis
/// pyramid becomes the real backdrop (§26A.5 view 3).
public struct WaveformBinsCanvas: View {
    let model: WaveformRenderModel?
    let windowStart: Int64
    let samplesPerPoint: Double

    public init(model: WaveformRenderModel?, windowStart: Int64, samplesPerPoint: Double) {
        self.model = model
        self.windowStart = windowStart
        self.samplesPerPoint = samplesPerPoint
    }

    public var body: some View {
        Canvas { context, size in
            if let model {
                WaveformDraw.bins(model: model,
                                  windowStart: Double(windowStart),
                                  samplesPerPoint: samplesPerPoint,
                                  size: size,
                                  into: &context)
            }
        }
    }
}
