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
                        .accessibilityLabel("Mix BPM arc")
                        .accessibilityValue("From \(Int(plan.summary.bpmRange.lowerBound.rounded())) to \(Int(plan.summary.bpmRange.upperBound.rounded())) BPM")
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
                            Text(rows.first(where: { $0.track.id == step.trackID })?.track.title ?? "Track \(step.trackID)")
                                .font(Typography.body)
                            Text(step.reasons.map(\.label).joined(separator: " · "))
                                .font(Typography.caption)
                                .foregroundStyle(Palette.inkSecondary)
                            ForEach(step.runnersUp, id: \.trackID) { runner in
                                Text("Runner-up \(runner.trackID): \(runner.lostBecause.map(\.label).joined(separator: ", "))")
                                    .font(Typography.caption)
                                    .foregroundStyle(Palette.inkTertiary)
                            }
                        }
                    }
                }
                if !plan.excluded.isEmpty {
                    Section("Left out") {
                        ForEach(plan.excluded, id: \.trackID) { exclusion in
                            Text("Track \(exclusion.trackID): \(exclusion.reason.label)")
                                .foregroundStyle(Palette.inkSecondary)
                        }
                    }
                }
            }
            .navigationTitle("Why This Mix?")
        }
    }
}

private struct MixExplanationArcChart: View {
    let plan: MixPlan

    var body: some View {
        Chart(plan.steps) { step in
            LineMark(x: .value("Position", step.position), y: .value("BPM", step.effectiveBPM))
                .foregroundStyle(Palette.accent)
            PointMark(x: .value("Position", step.position), y: .value("BPM", step.effectiveBPM))
                .foregroundStyle(Palette.accent)
        }
        .chartXAxis(.hidden)
        .chartYAxisLabel("BPM")
    }
}

struct WhyThisTransitionView: View {
    @EnvironmentObject private var player: AudioPlayer
    let plan: TransitionPlan
    var onUsePlainFade: (() -> Void)?
    var onPrepareNow: (() -> Void)?
    var preparationState: GridPrepState?

    var body: some View {
        List {
            Section("What you'll hear") {
                MiniTransitionWaveforms(plan: plan)
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
                    Text("This was downgraded from \(downgrade.rawValue) because the stronger plan was not ready.")
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
                player.seek(to: max(0, plan.exitTime - 10))
                player.resumePlayback()
            }
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
}

extension GridPrepState {
    var shortLabel: String {
        switch self {
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

    var body: some View {
        Canvas { context, size in
            let mid = size.height / 2
            let half = size.width / 2
            drawWave(context: &context, rect: CGRect(x: 0, y: 0, width: half - 4, height: mid - 5), seed: plan.fromTrackID)
            drawWave(context: &context, rect: CGRect(x: half + 4, y: mid + 5, width: half - 4, height: mid - 5), seed: plan.toTrackID)
            var marker = Path()
            marker.move(to: CGPoint(x: half, y: 0))
            marker.addLine(to: CGPoint(x: half, y: size.height))
            context.stroke(marker, with: .color(Palette.accent), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .accessibilityElement()
        .accessibilityLabel("Aligned outgoing and incoming transition waveforms")
        .accessibilityValue("Overlap \(String(format: "%.1f", plan.overlapSeconds)) seconds")
    }

    private func drawWave(context: inout GraphicsContext, rect: CGRect, seed: Int64) {
        var path = Path()
        let count = 24
        for index in 0...count {
            let x = rect.minX + rect.width * CGFloat(index) / CGFloat(count)
            let phase = Double(seed % 31) * 0.17 + Double(index) * 0.75
            let y = rect.midY + sin(phase) * rect.height * 0.38
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
        case .keyCompatible(let relation): "Key relationship: \(String(describing: relation))"
        case .keyClashShortOverlap: "Key clash kept to a short overlap"
        case .tempoTooFar(let pct): "Tempo is \(String(format: "%.1f", pct))% apart"
        case .lowTempoConfidence(let confidence): "Tempo confidence is \(String(format: "%.0f", confidence))%"
        case .variableTempo: "The track has variable tempo"
        case .gridNotReady: "Transition analysis is still preparing"
        case .notBuffered: "The incoming track was not buffered in time"
        case .sameAlbumGapless: "Adjacent tracks on the same album"
        case .loudnessMatched(let db): "Loudness matched by \(String(format: "%.1f", db)) dB"
        case .userChosePlainFade: "You chose a plain fade"
        }
    }
}
