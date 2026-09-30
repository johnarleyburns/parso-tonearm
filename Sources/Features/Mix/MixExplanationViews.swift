import Charts
import SwiftUI
import TonearmCore

struct WhyThisMixView: View {
    let plan: MixPlan
    let rows: [TrackRow]
    let sourcePlaylist: Playlist?

    var body: some View {
        NavigationStack {
            List {
                Section("Shape") {
                    Text("This mix follows a \(plan.request.shape.title.lowercased()) curve, using the available BPM range in your library.")
                }
                Section("Source") {
                    LabeledContent("Collection", value: sourcePlaylist?.title ?? "Listen library")
                    LabeledContent("Candidates", value: "\(rows.count) tracks")
                    if let first = plan.steps.first,
                       first.reasons.contains(.lockedByUser) {
                        Text("The first track was locked by you.")
                    } else {
                        Text("The first track starts at the lowest available BPM for this shape.")
                    }
                }
                Section("Arc") {
                    MixExplanationArcChart(plan: plan)
                        .frame(height: 130)
                }
                Section("Stats") {
                    LabeledContent("Tracks", value: "\(plan.steps.count)")
                    LabeledContent("Harmonic edges", value: "\(plan.summary.harmonicEdges) of \(plan.summary.totalEdges)")
                    LabeledContent("Tempo jumps", value: "\(plan.summary.tempoJumps)")
                    LabeledContent("Duration", value: TimeFmt.mmss(plan.summary.duration))
                }
                if !plan.summary.weakestEdges.isEmpty {
                    Section("Trade-offs") {
                        ForEach(plan.summary.weakestEdges, id: \.self) { edge in
                            let flags = plan.steps[safe: edge + 1]?.edgeIn?.flags ?? []
                            Text("Transition \(edge + 1) was the best available option: \(flags.map(\.label).joined(separator: ", ")).")
                                .foregroundStyle(Palette.inkSecondary)
                        }
                    }
                }
                Section("Why each track is here") {
                    ForEach(plan.steps) { step in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(rows.first(where: { $0.track.id == step.trackID })?.track.title ?? "Unknown track")
                                .font(Typography.body)
                            Text(step.reasons.map(\.label).joined(separator: " · "))
                                .font(Typography.caption)
                                .foregroundStyle(Palette.inkSecondary)
                            ForEach(step.runnersUp, id: \.trackID) { runner in
                                Text("Runner-up \(title(for: runner.trackID)): \(runner.lostBecause.map(\.label).joined(separator: ", "))")
                                    .font(Typography.caption)
                                    .foregroundStyle(Palette.inkTertiary)
                            }
                        }
                    }
                }
                if !plan.excluded.isEmpty {
                    Section("Left out") {
                        ForEach(plan.excluded, id: \.trackID) { exclusion in
                            Text("\(title(for: exclusion.trackID)): \(exclusion.reason.label)")
                                .foregroundStyle(Palette.inkSecondary)
                        }
                    }
                }
            }
            .navigationTitle("Why This Mix?")
        }
    }

    private func title(for trackID: Int64) -> String {
        rows.first(where: { $0.track.id == trackID })?.track.title ?? "Unknown track"
    }
}

private struct MixExplanationArcChart: View {
    let plan: MixPlan

    var body: some View {
        Chart {
            ForEach(plan.steps) { step in
                LineMark(x: .value("Position", step.position), y: .value("BPM", step.effectiveBPM), series: .value("Series", "BPM"))
                    .foregroundStyle(Palette.accent)
                PointMark(x: .value("Position", step.position), y: .value("BPM", step.effectiveBPM))
                    .foregroundStyle(Palette.accent)
            }
            ForEach(plan.steps.compactMap { step -> (Int, Double)? in
                guard let energy = plan.request.candidates.first(where: { $0.trackID == step.trackID })?.energy else { return nil }
                return (step.position, energy)
            }, id: \.0) { position, energy in
                LineMark(x: .value("Position", position), y: .value("Energy", energyValue(energy)), series: .value("Series", "Energy"))
                    .foregroundStyle(Palette.success)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxisLabel("BPM")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mix tempo and energy arc")
        .accessibilityValue("Tempo ranges from \(Int(plan.summary.bpmRange.lowerBound.rounded())) to \(Int(plan.summary.bpmRange.upperBound.rounded())) BPM. \(energyDescription)")
    }

    private var energyDescription: String {
        let values = plan.steps.compactMap { step in
            plan.request.candidates.first(where: { $0.trackID == step.trackID })?.energy
        }
        guard let min = values.min(), let max = values.max() else { return "Energy is unavailable." }
        return "Energy ranges from \(Int(min * 100)) to \(Int(max * 100)) percent."
    }

    private func energyValue(_ energy: Double) -> Double {
        let lower = plan.summary.bpmRange.lowerBound
        let upper = max(lower + 1, plan.summary.bpmRange.upperBound)
        return lower + min(max(energy, 0), 1) * (upper - lower)
    }
}

struct WhyThisTransitionView: View {
    @EnvironmentObject private var player: AudioPlayer
    let plan: TransitionPlan
    let outgoingPayload: DJTrackPrepPayload?
    let incomingPayload: DJTrackPrepPayload?
    var onAudition: (() -> Void)?
    var onUsePlainFade: (() -> Void)?
    var onPrepareNow: (() -> Void)?
    var preparationState: GridPrepState?

    init(plan: TransitionPlan, outgoingPayload: DJTrackPrepPayload? = nil,
         incomingPayload: DJTrackPrepPayload? = nil, onAudition: (() -> Void)? = nil,
         onUsePlainFade: (() -> Void)? = nil, onPrepareNow: (() -> Void)? = nil,
         preparationState: GridPrepState? = nil) {
        self.plan = plan
        self.outgoingPayload = outgoingPayload
        self.incomingPayload = incomingPayload
        self.onAudition = onAudition
        self.onUsePlainFade = onUsePlainFade
        self.onPrepareNow = onPrepareNow
        self.preparationState = preparationState
    }

    var body: some View {
        List {
            Section("What you'll hear") {
                MiniTransitionWaveforms(plan: plan, outgoing: outgoingPayload, incoming: incomingPayload)
                    .frame(height: 84)
                Text(sentence)
                    .font(Typography.body)
            }
            Section("Reasons") {
                ForEach(Array(plan.reasons.enumerated()), id: \.offset) { _, reason in
                    Label(reason.label, systemImage: "checkmark.circle")
                }
            }
            Section("Confidence") {
                ProgressView(value: plan.confidence)
                    .accessibilityLabel("Transition confidence")
                    .accessibilityValue("\(Int(plan.confidence * 100)) percent")
            }
            if let downgrade = plan.downgradedFrom {
                Section("Preparation") {
                    Text("This was downgraded from \(styleName(downgrade)) because the stronger plan was not ready.")
                }
            }
            if let preparationState {
                Section("Preparation") {
                    LabeledContent("Grid", value: preparationState.shortLabel)
                    if onPrepareNow != nil, preparationState != .ready {
                        Button("Prepare now") { onPrepareNow?() }
                    }
                }
            }
            Button("Audition") {
                if let onAudition {
                    onAudition()
                } else if player.currentTrack?.track.id == plan.fromTrackID,
                          player.upNextTracks.first?.track.id == plan.toTrackID {
                    player.seek(to: max(0, plan.exitTime - 10))
                    player.resumePlayback()
                }
            }
            .disabled(onAudition == nil && player.currentTrack?.track.id != plan.fromTrackID)
            Button("Use a Plain Fade Here") { onUsePlainFade?() }
        }
        .navigationTitle("Why This Transition?")
    }

    private var sentence: String {
        switch plan.style {
        case .gapless: "These adjacent album tracks continue without a fade."
        case .beatmatchedBlend: "The next phrase blends in on the beat, then returns to its original tempo."
        case .phraseFade: "The next phrase enters on a short equal-power fade."
        case .plainCrossfade: "The tracks use the regular crossfade."
        }
    }

    private func styleName(_ style: TransitionStyle) -> String {
        switch style {
        case .gapless: "gapless continuation"
        case .beatmatchedBlend: "beat-matched blend"
        case .phraseFade: "phrase-aware fade"
        case .plainCrossfade: "plain crossfade"
        }
    }
}

extension GridPrepState {
    var shortLabel: String {
        switch self {
        case .notPrepared: "Not prepared"
        case .ready: "Ready"
        case .queued: "Queued"
        case .downloading(let progress), .analyzing(let progress): "\(Int(progress * 100))%"
        case .waitingForNetwork: "Waiting for network"
        case .waitingForWiFi: "Waiting for Wi-Fi"
        case .failed: "Failed"
        case .cancelled: "Stopped"
        }
    }
}

private struct MiniTransitionWaveforms: View {
    let plan: TransitionPlan
    let outgoing: DJTrackPrepPayload?
    let incoming: DJTrackPrepPayload?

    var body: some View {
        Canvas { context, size in
            let mid = size.height / 2
            let half = size.width / 2
            drawWave(context: &context, rect: CGRect(x: 0, y: 0, width: half - 4, height: mid - 5), bins: outgoing?.waveform ?? [])
            drawWave(context: &context, rect: CGRect(x: half + 4, y: mid + 5, width: half - 4, height: mid - 5), bins: incoming?.waveform ?? [])
            var marker = Path()
            marker.move(to: CGPoint(x: half, y: 0))
            marker.addLine(to: CGPoint(x: half, y: size.height))
            context.stroke(marker, with: .color(Palette.accent), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .accessibilityElement()
        .accessibilityLabel("Aligned outgoing and incoming transition waveforms")
        .accessibilityValue("Overlap \(String(format: "%.1f", plan.overlapSeconds)) seconds")
    }

    private func drawWave(context: inout GraphicsContext, rect: CGRect,
                          bins: [DJTrackPrepPayload.WaveformBin]) {
        var path = Path()
        let count = max(1, bins.count - 1)
        for index in 0...count {
            let x = rect.minX + rect.width * CGFloat(index) / CGFloat(count)
            let bin = bins.isEmpty ? nil : bins[min(index, bins.count - 1)]
            let minimum = CGFloat(bin?.min ?? 0)
            let maximum = CGFloat(bin?.max ?? 0)
            let y = rect.midY - ((minimum + maximum) / 2) * rect.height * 0.45
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        context.stroke(path, with: .color(Palette.accent.opacity(0.82)), lineWidth: 1.5)
    }
}

private extension MixShape {
    var title: String {
        switch self { case .risingBPM: "rising BPM"; case .steady: "steady"; case .warmUpPeakCoolDown: "warm up, peak, cool down"; case .windDown: "wind down" }
    }
}

extension MixExclusionReason {
    var label: String {
        switch self {
        case .notAnalyzed(let missing): "missing \(missing.contains(.bpm) ? "BPM" : "key") analysis"
        case .overTargetLength: "over the selected length"
        case .duplicate: "duplicate"
        case .unplayable: "not playable"
        }
    }
}

private extension PlacementReason {
    var label: String {
        switch self {
        case .lowestBPMStart: "lowest-BPM start"
        case .followsShape: "follows the shape"
        case .bestKeyNeighbor: "best key neighbor"
        case .closestTempo: "closest tempo"
        case .energyFitsCurve: "fits the energy curve"
        case .lockedByUser: "locked by you"
        case .onlyRemainingOption: "only remaining option"
        case .soundsSimilar: "sounds similar"
        }
    }
}

private extension EdgeFlag {
    var label: String {
        switch self {
        case .againstShape: "against the shape"
        case .tempoJump: "tempo jump"
        case .keyClash: "key clash"
        case .sameArtistBackToBack: "same artist back-to-back"
        case .unavoidable(let reason):
            switch reason {
            case .onlyRemainingOption: "only remaining option"
            case .limitedTempoPool: "limited tempo pool"
            case .missingGrid: "grid not ready"
            case .explanation(let text): text
            }
        }
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension TransitionReason {
    var label: String {
        switch self {
        case .outgoingOutroPhrase(let bar, let beats): "Leaves at the outro phrase, bar \(bar), \(beats) beats"
        case .incomingIntroPhrase(let beats): "Enters on the intro, \(beats) beats"
        case .lastPhraseBoundary(let bar): "Uses the last phrase boundary, bar \(bar)"
        case .skippedLeadingSilence(let seconds): "Skips \(String(format: "%.1f", seconds)) seconds of leading silence"
        case .tempoMatched(let pct): "Tempo changes by \(String(format: "%.1f", pct))%"
        case .tempoReturnsOverBeats(let beats): "Returns to the original tempo over \(beats) beats"
        case .keyCompatible(let relation): "Key relationship: \(relation.displayLabel)"
        case .keyClashShortOverlap: "Key clash kept to a short overlap"
        case .tempoTooFar(let pct): "Tempo is \(String(format: "%.1f", pct))% apart"
        case .lowTempoConfidence(let confidence): "Tempo confidence is \(String(format: "%.0f", confidence))%"
        case .variableTempo: "The track has variable tempo"
        case .gridNotReady(let state): "Transition analysis is \(state.shortLabel.lowercased())"
        case .notBuffered: "The incoming track was not buffered in time"
        case .sameAlbumGapless: "Adjacent tracks on the same album"
        case .loudnessMatched(let db): "Loudness matched by \(String(format: "%.1f", db)) dB"
        case .userChosePlainFade: "You chose a plain fade"
        }
    }
}

private extension KeyRelation {
    var displayLabel: String {
        switch self {
        case .same: "same key"
        case .adjacentUp: "one Camelot step up"
        case .adjacentDown: "one Camelot step down"
        case .relative: "relative major/minor"
        case .energyBoost: "energy lift"
        case .clash(let steps): "key clash, \(steps) steps apart"
        case .unknown: "unknown key relationship"
        }
    }
}
