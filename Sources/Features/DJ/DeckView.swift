import SwiftUI
import TonearmCore

/// One deck: track-info card, LOAD, platter, tempo knob, play/pause — matching the mockup. LOAD,
/// play/pause are real this pass; the platter (spin/tap-to-load) and tempo knob stay static,
/// wired up later one at a time.
struct DeckView: View {
    let side: DJDeckSide
    @EnvironmentObject private var model: DJConsoleModel
    @State private var showLoadSheet = false

    private var state: DeckLoadState { model.state(side) }
    private var info: LoadedDeckInfo? { model.info(side) }

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
        VStack(spacing: 10) {
            trackCard
            Spacer(minLength: 0)
            ZStack {
                platter
                KnobView(value: 0.5)
                    .overlay(alignment: .bottom) {
                        Text("TEMPO").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                            .offset(y: 14)
                    }
                    .offset(x: side == .left ? 90 : -90, y: 90)
            }
            playButton
        }
        .padding(12)
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
                    Text(info?.title ?? "No track loaded")
                        .font(.headline).foregroundStyle(.white).lineLimit(1)
                    Text(info?.artist ?? " ")
                        .font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let info {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("\(info.bpm, specifier: "%.1f") BPM").font(.caption.bold()).foregroundStyle(.white)
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
            Button {
                showLoadSheet = true
            } label: {
                Text("LOAD").font(.system(size: 10, weight: .bold))
                    .frame(maxWidth: .infinity).frame(height: 28)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.white)
            }
            .accessibilityIdentifier(side == .left ? "dj.deck.left.load" : "dj.deck.right.load")
        }
        .padding(10)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12)))
        .accessibilityIdentifier(side == .left ? "dj.deck.left" : "dj.deck.right")
    }

    private var platter: some View {
        Circle()
            .fill(
                RadialGradient(colors: [Color(white: 0.16), Color(white: 0.05), Color(white: 0.16)],
                               center: .center, startRadius: 0, endRadius: 110)
            )
            .overlay(Circle().stroke(.white.opacity(0.1)))
            .overlay {
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(Color(red: 0x56 / 255, green: 0xb7 / 255, blue: 1), lineWidth: 2)
                    .rotationEffect(.degrees(-38))
                    .padding(16)
            }
            .overlay {
                VStack(spacing: 2) {
                    Text(info.map { String($0.title.prefix(8)) } ?? "").font(.caption2.bold())
                    Text("tap center\nto load").font(.system(size: 9)).multilineTextAlignment(.center)
                }
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 70, height: 70)
                .background(
                    RadialGradient(colors: [Color(red: 0x9e / 255, green: 0x87 / 255, blue: 0xbb / 255),
                                            Color(red: 0x3c / 255, green: 0x2c / 255, blue: 0x66 / 255)],
                                   center: UnitPoint(x: 0.33, y: 0.25), startRadius: 0, endRadius: 50),
                    in: Circle()
                )
            }
            .frame(width: 180, height: 180)
            .onTapGesture { showLoadSheet = true }
    }

    private var playButton: some View {
        Button {
            model.togglePlay(side)
        } label: {
            Image(systemName: model.isPlaying(side) ? "pause.fill" : "play.fill")
                .font(.system(size: 16, weight: .bold))
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.white)
        }
        .disabled(state != .ready && !model.isPlaying(side))
        .accessibilityIdentifier(side == .left ? "dj.deck.left.play" : "dj.deck.right.play")
    }
}
