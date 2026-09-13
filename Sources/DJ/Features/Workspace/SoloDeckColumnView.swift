import SwiftUI

// MARK: - Focused deck

/// The focused deck at full width (§42.6): header pills, title + playhead
/// + BPM readout, waveform, transport row, hot-cue pads and the bank chip row
/// (`Stems · EQ · Filter · Cues · Jog`). The bank selection raises its
/// controls below the chips; the `Jog` chip swaps in the real `JogView`
/// (plan 4.8) — a rendered platter with position marker + phase ghost whose
/// intents reach the transport only through `JogTransport`.
struct SoloDeckColumnView: View {
    @ObservedObject var model: WorkspaceModel
    let deck: Deck
    let isMaster: Bool

    @State private var bank: SoloBank = .stems

    private var telemetryDeck: EngineTelemetry.Deck {
        deck == .a ? model.telemetry.deckA : model.telemetry.deckB
    }

    private var synced: Bool { model.isSynced(deck) }

    private var deckID: String { deck == .a ? "a" : "b" }

    private var eq: (low: Float, mid: Float, high: Float) {
        deck == .a ? (model.eqALow, model.eqAMid, model.eqAHigh)
                   : (model.eqBLow, model.eqBMid, model.eqBHigh)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(deck == .a ? "Deck A" : "Deck B")
                        .font(.system(size: 17, weight: .bold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("dj.deck.\(deckID).loaded")
                .accessibilityLabel(model.loadedTrackTitle(for: deck) ?? "Nothing loaded")
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(playheadText)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(String(format: "%.2f BPM", telemetryDeck.bpmEffective))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    Text("beat \(Int(telemetryDeck.phase * 100))%")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 9)

            // The §26A waveform stack — analysis-driven, from persisted
            // analysis (FR-WAVE-1): phrase ribbon + full-track overview above
            // the scrolling detail under its fixed-centre playhead.
            waveformStack

            transport
                .padding(.vertical, 10)

            HStack(spacing: 6) {
                ForEach(["A", "B", "C", "D"], id: \.self) { pad in
                    Text(pad)
                        .font(.system(size: 12, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.bottom, 10)

            bankChips
                .padding(.bottom, 10)

            bankContent
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    private var header: some View {
        HStack {
            Text(deck == .a ? "DECK A" : "DECK B")
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.08), in: Capsule())
            if isMaster {
                Pill("MASTER", color: .green)
            } else if synced {
                Pill("SYNCED", color: .cyan)
            }
            Spacer()
            Text("stems")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.green.opacity(0.14), in: Capsule())
                .foregroundStyle(.green)
        }
        .padding(.bottom, 7)
    }

    private var subtitle: String {
        if synced { return "synced · playing" }
        return telemetryDeck.playing ? "playing" : "paused"
    }

    private var playheadText: String {
        let seconds = Double(telemetryDeck.playheadSample) / model.engine.sampleRate
        return Self.timeText(seconds)
    }

    static func timeText(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let whole = Int(clamped)
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }

    @ViewBuilder
    private var waveformStack: some View {
        let waveform = model.waveform(for: deck)
        let grid = waveform?.grid
        let playhead = telemetryDeck.playheadSample
        VStack(spacing: 2) {
            PhraseRibbon(model: waveform,
                         windowStart: 0,
                         visibleSamples: Double(waveform?.durationSamples ?? 1),
                         halveLabels: WaveformThermal.current.degradesRendering)
                .frame(height: 12)
            WaveformDetailView(
                model: waveform,
                windowStart: windowStart(for: playhead, grid: grid),
                visibleSamples: visibleSamples(for: grid),
                playhead: playhead,
                emptyTitle: model.hasLoadedTrack(deck) ? "Not analysed yet" : "Load a track",
                emptyMessage: model.hasLoadedTrack(deck) ? "Analyse to draw the waveform here"
                                                         : "Pick a track from the queue")
                .frame(height: 48)
            OverviewStrip(model: waveform, playhead: playhead) { sample in
                model.seek(deck, toSample: sample, quantized: true)
            }
            .frame(height: 18)
        }
    }

    /// The performance window: 16 bars under the fixed-centre playhead (§26A.5).
    private func visibleSamples(for grid: DeckGrid?) -> Double {
        guard let grid else { return 1 }
        return 16 * grid.samplesPerBar
    }

    /// The window start, centred on the playhead and clamped to the track head.
    private func windowStart(for playhead: Int64, grid: DeckGrid?) -> Int64 {
        guard let grid else { return 0 }
        let half = visibleSamples(for: grid) / 2
        return max(0, Int64(Double(playhead) - half))
    }

    private var transport: some View {
        HStack(spacing: 7) {
            TransportButton(title: "CUE",
                            identifier: "dj.deck.\(deckID).cue") {
                model.cue(deck)
            } onRelease: {
                model.releaseCue(deck)
            }
            TransportButton(title: telemetryDeck.playing ? "PAUSE" : "PLAY",
                            emphasized: true,
                            identifier: "dj.deck.\(deckID).play") {
                if telemetryDeck.playing {
                    model.pause(deck)
                } else {
                    model.play(deck)
                }
            } onRelease: {}
            TransportButton(title: "SYNC") {
                model.sync(deck, to: deck == .a ? .b : .a)
            } onRelease: {}
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                        model.sync(deck, to: deck == .a ? .b : .a, barSync: true)
                    }
                )
            TransportButton(title: "LOOP") {
                model.setLoop(deck, beats: 8)
            } onRelease: {}
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                        model.exitLoop(deck)
                    }
                )
        }
    }

    private var bankChips: some View {
        HStack(spacing: 7) {
            ForEach(SoloBank.allCases, id: \.self) { candidate in
                Button {
                    bank = candidate
                } label: {
                    Text(candidate.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                        .background(
                            bank == candidate ? Color.accentColor.opacity(0.22)
                                              : Color.white.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .foregroundStyle(bank == candidate ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var bankContent: some View {
        switch bank {
        case .stems:
            stemsBlock
        case .eq:
            EQGroup(title: "EQ", deckID: deckID,
                    low: eq.low, mid: eq.mid, high: eq.high) { low, mid, high in
                model.setEQKnobs(deck, low: low, mid: mid, high: high)
            }
        case .filter:
            HStack {
                Text("FILTER")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                VerticalSlider(value: deck == .a ? model.filterA : model.filterB,
                               identifier: "dj.deck.\(deckID).filter",
                               onChanged: { model.setFilter(deck, knob: $0) })
                    .frame(height: 96)
            }
            .padding(.horizontal, 8)
        case .fader:
            HStack {
                Text("CH")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                GainVerticalSlider(value: deck == .a ? model.channelA : model.channelB,
                                   identifier: "dj.deck.\(deckID).fader",
                                   onChanged: { model.setChannelFader(deck, gain: $0) })
                    .frame(height: 96)
            }
            .padding(.horizontal, 8)
        case .cues:
            HStack(spacing: 6) {
                ForEach(["A", "B", "C", "D"], id: \.self) { pad in
                    Text("HOT \(pad)")
                        .font(.system(size: 11, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        case .jog:
            JogView(model: model, deck: deck, onIntent: jogIntent)
                .frame(width: 168, height: 168)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
    }

    /// The jog's only route to the transport (FR-ENG-11, §40.7.7): intents are
    /// mapped by the model-owned `JogTransport` (plan M3 — one per deck, shared
    /// with a MIDI jog) onto the engine's transport intents, guarded by
    /// `RTGuard.assertRTSafe` (AT-TWIN-4).
    private func jogIntent(_ intent: JogGestureModel.Intent) {
        model.jogTransport(for: deck).route(intent)
    }

    /// The honest stem faders (§36.5, plan S8): the status is the real
    /// `DeckStemStatus` (unavailable / separating / prepared) and the faders
    /// are live `StemFaderRow`s when prepared — never the hardcoded
    /// "unavailable · M5" placeholder, and never a fader that looks live and
    /// does nothing.
    private var stemsBlock: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Stems")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(model.stemStatus(deck).label)
                    .font(.caption2)
                    .foregroundStyle(model.stemStatus(deck) == .prepared ? Color.green : .secondary)
            }
            if model.stemStatus(deck) == .prepared {
                ForEach(SeparationVoice.allCases, id: \.self) { stem in
                    StemFaderRow(label: title(stem),
                                 gain: model.stemGain(deck, stem: stem),
                                 muted: model.stemIsMuted(deck, stem: stem),
                                 identifier: "dj.deck.\(deckID).stem.\(stem.rawValue)") { gain in
                        model.setStemGain(deck, stem: stem, gain: gain)
                    } onMuteToggled: {
                        model.setStemMute(deck, stem: stem,
                                          muted: !model.stemIsMuted(deck, stem: stem))
                    }
                }
            } else {
                // The honest disabled state: unity bars, dimmed — never a
                // live-looking fader that does nothing (§36.5).
                ForEach(SeparationVoice.allCases, id: \.self) { stem in
                    HStack(spacing: 6) {
                        Text(title(stem))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .leading)
                        Capsule().fill(Color.white.opacity(0.06))
                            .frame(height: 12)
                    }
                }
            }
        }
    }

    private func title(_ stem: SeparationVoice) -> String {
        switch stem {
        case .vocals: return "Vocals"
        case .drums: return "Drums"
        case .bass: return "Bass"
        case .other: return "Other"
        }
    }
}

/// The focused deck's bank set (§42.6 — the compact chip row incl. `Jog`).
private enum SoloBank: String, CaseIterable {
    case stems = "Stems"
    case eq = "EQ"
    case filter = "Filter"
    case fader = "Fader"
    case cues = "Cues"
    case jog = "Jog"
}

/// A vertical channel-fader drag (gain 0…1, §35.4) for the compact surface —
/// the twin's `ChannelFader` in a bank. `identifier` carries the §53.11
/// accessibility identifier.
private struct GainVerticalSlider: View {
    let value: Float
    var identifier: String?
    let onChanged: (Float) -> Void

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(Color.accentColor.opacity(0.85))
                    .frame(height: max(4, height * CGFloat(clampUnit(CGFloat(value)))))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { gesture in
                    let t = 1 - gesture.location.y / height
                    onChanged(Float(clampUnit(t)))
                }
            )
        }
        .performanceControl(identifier, label: "Channel fader", value: value)
        .coachGlow(identifier: identifier)
    }
}

