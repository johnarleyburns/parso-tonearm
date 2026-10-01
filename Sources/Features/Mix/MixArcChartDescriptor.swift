import Accessibility
import SwiftUI
import TonearmCore

/// Audio Graph for the Mix tempo/energy arc, so VoiceOver users can hear the
/// shape of the mix (rotor → Audio Graph) instead of only reading a summary.
/// Tempo is the plotted BPM per position; energy is the track's analysed
/// energy as a percentage.
struct MixArcChartDescriptor: AXChartDescriptorRepresentable {
    let plan: MixPlan

    func makeChartDescriptor() -> AXChartDescriptor {
        let positions = plan.steps.map { Double($0.position + 1) }
        let tempos = plan.steps.map(\.effectiveBPM)
        let energies: [(Double, Double)] = plan.steps.compactMap { step in
            guard let energy = plan.request.candidates.first(where: { $0.trackID == step.trackID })?.energy else {
                return nil
            }
            return (Double(step.position + 1), energy * 100)
        }

        let xAxis = AXNumericDataAxisDescriptor(
            title: String(localized: "Track position"),
            range: (positions.min() ?? 1)...max(positions.max() ?? 1, (positions.min() ?? 1) + 1),
            gridlinePositions: []
        ) { String(localized: "Track \(Int($0))") }

        let lowTempo = tempos.min() ?? 0
        let yAxis = AXNumericDataAxisDescriptor(
            title: String(localized: "BPM"),
            range: lowTempo...max(tempos.max() ?? lowTempo, lowTempo + 1),
            gridlinePositions: []
        ) { String(localized: "\(Int($0.rounded())) BPM") }

        var series = [
            AXDataSeriesDescriptor(
                name: String(localized: "Tempo"),
                isContinuous: true,
                dataPoints: zip(positions, tempos).map { AXDataPoint(x: $0, y: $1) }
            )
        ]
        if !energies.isEmpty {
            series.append(AXDataSeriesDescriptor(
                name: String(localized: "Energy"),
                isContinuous: true,
                dataPoints: energies.map { position, percent in
                    AXDataPoint(x: position, y: percent,
                                label: String(localized: "Energy \(Int(percent.rounded())) percent"))
                }
            ))
        }

        return AXChartDescriptor(
            title: String(localized: "Mix tempo and energy arc"),
            summary: String(localized: "Tempo from \(Int(lowTempo.rounded())) to \(Int((tempos.max() ?? lowTempo).rounded())) BPM across \(plan.steps.count) tracks."),
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: series
        )
    }
}
