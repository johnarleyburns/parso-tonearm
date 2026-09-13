import SwiftUI

/// The beat-phase meter: the master's downbeat phase as four beat segments
/// (mockup `ipad/07`'s centre-column readout). Carries the §53.11
/// `dj.master.phase` identifier so the §41.18 coach can light it as the Blend
/// transition's beat-phase role (§35B row 5).
struct BeatPhaseMeter: View {
    let phase: Double
    private let beatsPerBar = 4

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<beatsPerBar, id: \.self) { index in
                Capsule()
                    .fill(phase * Double(beatsPerBar) > Double(index + 1)
                          ? Color.cyan
                          : Color.cyan.opacity(0.18))
                    .frame(maxWidth: .infinity, maxHeight: 8)
            }
        }
        .accessibilityIdentifier("dj.master.phase")
        .coachGlow(identifier: "dj.master.phase")
    }
}
/// One accessibility element per continuous performance control, carrying its
/// §53.11 identifier **and its current position**. Shared by all three
/// performance surfaces.
///
/// Two things depend on it. VoiceOver otherwise reads a knob that says nothing
/// about where it is set. And the DJ regression lanes can tell a gesture that
/// moved a control from one that landed on scenery: a synthesised drag on a
/// control that is present but unreachable is silent, and with no value to
/// compare it stays silent all the way to a missing transition signature in the
/// recording, hours later (§53.5).
///
/// `children: .ignore` is what makes it *one* element. A decorated control
/// otherwise scatters its identifier across every label inside it, and a driver
/// that takes the first match ends up dragging within a 7-point letter "A".
extension View {
    func performanceControl(_ identifier: String?, label: String, value: Float) -> some View {
        let element = accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(String(format: "%.3f", value))
        if let identifier {
            return AnyView(element.accessibilityIdentifier(identifier))
        }
        return AnyView(element)
    }
}
