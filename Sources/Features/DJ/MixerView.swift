import ParsoDJEngine
import SwiftUI

/// The center mixer: monitoring row, EQ (3 channels), isolator, channel volumes + meter, and the
/// output-route control — matching the mockup, plus the route control the mockup predates.
/// Channel volume knobs, each channel's PFL button, and the output route are real this pass
/// (Workstreams G/H); REC (Workstream I) lands next. Monitoring, EQ and isolator stay static,
/// wired up later one at a time.
struct MixerView: View {
    @EnvironmentObject private var model: DJConsoleModel

    var body: some View {
        VStack(spacing: 10) {
            monitoringRow
            eqBlock
            isolatorBlock
            channelVolumesRow
            outputRouteControl
        }
        .padding(.horizontal, 6)
        .accessibilityIdentifier("dj.mixer")
    }

    /// Single-output "split cue": PFL a channel first, then Split L/Split R sends that deck to
    /// one ear and the master to the other. Disabled (and visually dimmed) until a PFL is
    /// engaged, rather than letting the control silently produce an undefined mix.
    private var outputRouteControl: some View {
        VStack(spacing: 4) {
            Text("OUTPUT").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.5))
            HStack(spacing: 4) {
                routeButton("Stereo", .stereo)
                routeButton("Split L", .splitLeft)
                routeButton("Split R", .splitRight)
            }
        }
        .accessibilityIdentifier("dj.mixer.outputRoute")
    }

    private func routeButton(_ title: String, _ route: MasterOutputRoute) -> some View {
        let enabled = route == .stereo || model.hasPFLSelection
        let active = model.outputRoute == route
        return Button {
            model.outputRoute = route
        } label: {
            Text(title).font(.system(size: 8, weight: .bold))
                .padding(.horizontal, 6).padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .background(active ? Color(red: 0x56 / 255, green: 0xb7 / 255, blue: 1) : .white.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(active ? .black : .white.opacity(enabled ? 1 : 0.35))
        }
        .disabled(!enabled)
        .accessibilityIdentifier("dj.mixer.outputRoute.\(title.replacingOccurrences(of: " ", with: ""))")
    }

    private var monitoringRow: some View {
        HStack(spacing: 10) {
            monitorKnob(label: "HOUSE")
            Text("REC")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 36, height: 28)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.white.opacity(0.5))
            monitorKnob(label: "BOOTH")
        }
    }

    private func monitorKnob(label: String) -> some View {
        VStack(spacing: 3) {
            KnobView(value: 0.5)
            Text(label).font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.6))
            HStack(spacing: 3) {
                Text("PH").font(.system(size: 7)).padding(.horizontal, 4).padding(.vertical, 2)
                    .background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.black)
                Text("LINE").font(.system(size: 7)).padding(.horizontal, 4).padding(.vertical, 2)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.white)
            }
        }
    }

    private var eqBlock: some View {
        HStack(spacing: 8) {
            eqChannel(name: "A", pfl: { model.isPFL(.left) }, onPFL: { model.togglePFL(.left) })
            eqChannel(name: "MIC", pfl: { false }, onPFL: {})
            eqChannel(name: "B", pfl: { model.isPFL(.right) }, onPFL: { model.togglePFL(.right) })
        }
        .padding(8)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12)))
    }

    private func eqChannel(name: String, pfl: () -> Bool, onPFL: @escaping () -> Void) -> some View {
        VStack(spacing: 4) {
            Text(name).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
            ForEach(["HIGH", "MID", "BASS"], id: \.self) { band in
                VStack(spacing: 2) {
                    Text(band).font(.system(size: 7)).foregroundStyle(.white.opacity(0.6))
                    KnobView(value: 0.5)
                }
            }
            Button(action: onPFL) {
                Text("PFL").font(.system(size: 7, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(pfl() ? Color(red: 0x56 / 255, green: 0xb7 / 255, blue: 1) : .white.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(pfl() ? .black : .white)
            }
            .accessibilityIdentifier(name == "A" ? "dj.mixer.channelA.pfl" : name == "B" ? "dj.mixer.channelB.pfl" : "dj.mixer.mic.pfl")
        }
    }

    private var isolatorBlock: some View {
        VStack(spacing: 4) {
            Text("ISOLATOR").font(.system(size: 9, weight: .bold)).foregroundStyle(Color(red: 1, green: 0.84, blue: 0.65))
            HStack(spacing: 10) {
                ForEach(["BASS", "MID", "HIGH"], id: \.self) { band in
                    VStack(spacing: 2) {
                        KnobView(value: 0.5, indicatorColor: Color(red: 0.3, green: 0.2, blue: 0.1))
                        Text(band).font(.system(size: 7)).foregroundStyle(Color(red: 1, green: 0.82, blue: 0.63))
                    }
                }
            }
        }
        .padding(8)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.orange.opacity(0.25)))
    }

    private var channelVolumesRow: some View {
        HStack(spacing: 14) {
            channelVolumeKnob(label: "CH A\nVOL", value: Binding(
                get: { model.leftVolume }, set: { model.leftVolume = $0 }))
            VStack(spacing: 3) {
                ForEach([0.7, 1.0, 0.55], id: \.self) { height in
                    Capsule().fill(
                        LinearGradient(colors: [.green, .yellow, .red], startPoint: .bottom, endPoint: .top)
                    ).frame(width: 5, height: 40 * height)
                }
            }
            channelVolumeKnob(label: "CH B\nVOL", value: Binding(
                get: { model.rightVolume }, set: { model.rightVolume = $0 }))
        }
    }

    private func channelVolumeKnob(label: String, value: Binding<Double>) -> some View {
        VStack(spacing: 3) {
            KnobView(value: value.wrappedValue, onChange: { value.wrappedValue = $0 })
            Text(label).font(.system(size: 7, weight: .bold)).foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
        }
    }
}
