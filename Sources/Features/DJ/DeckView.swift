import SwiftUI
import TonearmCore

/// One deck: track-info card, platter, tempo knob, play/pause — matching the mockup, except LOAD
/// is not its own button (a real report: tapping the track card, same as the platter's own
/// "tap center to load", should be enough — a separate LOAD button was redundant chrome). Play/
/// pause is real this pass; the platter (spin/tap-to-load) and tempo knob stay static, wired up
/// later one at a time.
struct DeckView: View {
    let side: DJDeckSide
    /// From `DJConsoleView.scale(for:)` — see its doc comment. Keeps the platter, tempo knob and
    /// play button proportionate to whatever landscape size is actually available.
    var scale: CGFloat = 1
    @EnvironmentObject private var model: DJConsoleModel
    @State private var showLoadSheet = false

    private var state: DeckLoadState { model.state(side) }
    private var info: LoadedDeckInfo? { model.info(side) }
    private var platterDiameter: CGFloat { 180 * scale }
    private var tempoKnobSize: CGFloat { max(20, 28 * scale) }

    private var stepText: String? {
        switch state {
        case .empty, .ready: nil
        case .downloading(let fraction): "Downloading… \(Int(fraction * 100))%"
        case .decoding: "Decoding…"
        case .analyzing: "Analyzing tempo & key…"
        case .failed(let reason): reason
        }
    }

    var body: some View {
        VStack(spacing: 8 * scale) {
            trackCard
            ZStack {
                platter
                KnobView(value: 0.5, size: tempoKnobSize)
                    .overlay(alignment: .bottom) {
                        Text("TEMPO").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                            .offset(y: tempoKnobSize * 0.5 + 6)
                    }
                    .offset(x: side == .left ? platterDiameter / 2 : -platterDiameter / 2, y: platterDiameter / 2)
            }
            playButton
        }
        .padding(12 * scale)
        .sheet(isPresented: $showLoadSheet) {
            DeckLoadSheet { row in
                Task { await model.load(row, onto: side) }
            }
        }
    }

    private var trackCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    // Same size as the Camelot key below (a real report: title/BPM were much
                    // larger than the key, with no reason for the mismatch).
                    Text(info?.title ?? "No track loaded")
                        .font(.caption2).foregroundStyle(.white).lineLimit(1)
                    Text(info?.artist ?? " ")
                        .font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let info {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("\(info.bpm, specifier: "%.1f") BPM").font(.caption2.bold()).foregroundStyle(.white)
                        Text(info.camelot).font(.caption2).foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            if let stepText {
                Text(stepText).font(.caption2).foregroundStyle(.white.opacity(0.8))
            } else {
                HStack(spacing: 8) {
                    Text("0:00").font(.caption2).foregroundStyle(.white.opacity(0.6))
                    Capsule().fill(.white.opacity(0.18)).frame(height: 4)
                    Text("—:—").font(.caption2).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .padding(10)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12)))
        .contentShape(Rectangle())
        .onTapGesture { showLoadSheet = true }
        .accessibilityIdentifier(side == .left ? "dj.deck.left" : "dj.deck.right")
        .accessibilityLabel(info.map { "\($0.title), tap to change track" } ?? "No track loaded, tap to load")
    }

    private var platter: some View {
        Circle()
            .fill(
                RadialGradient(colors: [Color(white: 0.16), Color(white: 0.05), Color(white: 0.16)],
                               center: .center, startRadius: 0, endRadius: platterDiameter * 110 / 180)
            )
            .overlay(Circle().stroke(.white.opacity(0.1)))
            .overlay {
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(Color(red: 0x56 / 255, green: 0xb7 / 255, blue: 1), lineWidth: 2)
                    .rotationEffect(.degrees(-38))
                    .padding(16 * scale)
            }
            .overlay {
                VStack(spacing: 2) {
                    Text(info.map { String($0.title.prefix(8)) } ?? "").font(.caption2.bold())
                    Text("tap center\nto load").font(.system(size: 9)).multilineTextAlignment(.center)
                }
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: platterDiameter * 70 / 180, height: platterDiameter * 70 / 180)
                .background(
                    RadialGradient(colors: [Color(red: 0x9e / 255, green: 0x87 / 255, blue: 0xbb / 255),
                                            Color(red: 0x3c / 255, green: 0x2c / 255, blue: 0x66 / 255)],
                                   center: UnitPoint(x: 0.33, y: 0.25), startRadius: 0,
                                   endRadius: platterDiameter * 50 / 180),
                    in: Circle()
                )
            }
            .frame(width: platterDiameter, height: platterDiameter)
            .onTapGesture { showLoadSheet = true }
    }

    private var playButton: some View {
        Button {
            model.togglePlay(side)
        } label: {
            Image(systemName: model.isPlaying(side) ? "pause.fill" : "play.fill")
                .font(.system(size: 16 * scale, weight: .bold))
                .frame(width: 44 * scale, height: 44 * scale)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.white)
        }
        .disabled(state != .ready && !model.isPlaying(side))
        .accessibilityIdentifier(side == .left ? "dj.deck.left.play" : "dj.deck.right.play")
    }
}
