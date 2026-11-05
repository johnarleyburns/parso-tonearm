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
                    LabeledContent(String(localized: "Collection"), value: sourcePlaylist?.title ?? String(localized: "Listen library"))
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
                            Text(rows.first(where: { $0.track.id == step.trackID })?.track.title ?? String(localized: "Unknown track"))
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
        rows.first(where: { $0.track.id == trackID })?.track.title ?? String(localized: "Unknown track")
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
        .accessibilityChartDescriptor(MixArcChartDescriptor(plan: plan))
        .accessibilityValue("Tempo ranges from \(Int(plan.summary.bpmRange.lowerBound.rounded())) to \(Int(plan.summary.bpmRange.upperBound.rounded())) BPM. \(energyDescription)")
    }

    private var energyDescription: String {
        let values = plan.steps.compactMap { step in
            plan.request.candidates.first(where: { $0.trackID == step.trackID })?.energy
        }
        guard let min = values.min(), let max = values.max() else { return String(localized: "Energy is unavailable.") }
        return String(localized: "Energy ranges from \(Int(min * 100)) to \(Int(max * 100)) percent.")
    }

    private func energyValue(_ energy: Double) -> Double {
        let lower = plan.summary.bpmRange.lowerBound
        let upper = max(lower + 1, plan.summary.bpmRange.upperBound)
        return lower + min(max(energy, 0), 1) * (upper - lower)
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
