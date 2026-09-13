import SwiftUI

// MARK: - Mixer column

/// The centre mixer column (§41.9b): the two **per-channel vertical strips**
/// side by side (rule 1 — TRIM → HI → MID → LOW → FILTER above a vertical
/// channel fader and a CUE button), the crossfader **horizontal and
/// bottom-centre** (rule 2), the §35A Beat FX block below it (rule 7, honest
/// unavailable until the echo engine lands in 5.5), and the master/limiter/
/// thermal readouts. Width is the §41.9b 320 pt.
struct MixerColumnView: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("MASTER")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                masterBarReadout
            }

            masterMeter

            recordControl

            HStack(alignment: .top, spacing: 6) {
                ChannelStripView(model: model, deck: .a)
                ChannelStripView(model: model, deck: .b)
            }

            crossfader

            BeatFXBlock(model: model)

            // §44.2a: cue monitoring sits with the mixer, where a club mixer
            // puts it — beside the channel strips whose faders it lets you
            // work around.
            CueModePicker(model: model)

            Divider()

            VStack(spacing: 4) {
                HStack {
                    Text("Downbeat").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.0f%%", model.telemetry.downbeatPhase * 100))
                        .font(.system(size: 11, design: .monospaced))
                }
                BeatPhaseMeter(phase: model.telemetry.downbeatPhase)
            }

            HStack {
                Text("Limiter").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(limiterText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(limiterColor)
            }

            HStack {
                Text("CPU").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(model.telemetry.renderLoad * 100))%")
                    .font(.system(size: 11, design: .monospaced))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(Color.green)
                        .frame(width: proxy.size.width * CGFloat(min(1, model.telemetry.renderLoad)))
                }
            }
            .frame(height: 6)

            HStack {
                Text("Thermal").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(thermalText).font(.system(size: 11, design: .monospaced))
            }
            HStack {
                Text("Buffer").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f ms", model.engine.bufferPeriodMillis))
                    .font(.system(size: 11, design: .monospaced))
            }
        }
        .frame(width: WorkspaceModel.ModuleGeometry.mixerColumnWidth)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.03)))
    }

    /// The `dj.master.bar` readout (§53.11): the master clock's bar:beat,
    /// which the regression driver polls to schedule gestures on phrase
    /// boundaries. Part of the control contract — VoiceOver needs it too.
    private var masterBarReadout: some View {
        Group {
            if let barBeat = model.masterBarBeat {
                Text("BAR \(barBeat.bar) · \(barBeat.beat)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .accessibilityLabel("\(barBeat.bar):\(barBeat.beat)")
                    .accessibilityIdentifier("dj.master.bar")
            } else {
                Text("BAR —")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var masterMeter: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(Color.green)
                    .frame(width: proxy.size.width * CGFloat(min(1, model.telemetry.masterLevel)))
            }
        }
        .frame(height: 8)
    }

    /// The §37.2 record control (mockup `ipad/07`'s "■ Stop & save ·
    /// 00:18:42", plan 5.10, decision 14). The record/elapsed chip is session
    /// VM state shared across every performance surface; the engine's tap +
    /// encoder start on tap-to-record and finalize on tap-to-stop. Carries the
    /// `dj.transport.record` identifier the regression suite drives (§53.11,
    /// dj-regression-suite.md 5.10).
    private var recordControl: some View {
        Button {
            model.toggleRecording()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.isRecording ? Color.red : Color.white.opacity(0.25))
                    .frame(width: 9, height: 9)
                if model.isRecording {
                    Text("Stop & save · \(Self.elapsedText(model.recordingElapsed))")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                } else {
                    Text("REC")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("dj.transport.record")
    }

    private static func elapsedText(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// The crossfader, horizontal and bottom-centre (§41.9b rule 2) — never in
    /// a drawer, never behind a mode. Carries the `dj.mixer.crossfader`
    /// identifier.
    private var crossfader: some View {
        VStack(spacing: 4) {
            HStack {
                Text("A").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("CROSSFADER").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("B").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.10))
                        .frame(height: 10)
                    let t = CGFloat((model.crossfader + 1) / 2)
                    Capsule()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 22, height: 29)
                        .offset(x: max(0, min(width - 22, width * t - 11)))
                }
                .frame(height: 34)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { value in
                        let u = Self.clampUnit(value.location.x / width)
                        model.setCrossfader(Float(u) * 2 - 1, curve: model.crossfaderCurve)
                    }
                )
                .performanceControl("dj.mixer.crossfader", label: "Crossfader",
                                    value: model.crossfader)
                .coachGlow(identifier: "dj.mixer.crossfader")
            }
            .frame(height: 34)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    private var limiterText: String {
        if let ceiling = model.engine.limiterCeiling {
            return String(format: "active · −%.1f dB", (1 - ceiling) * 20)
        }
        return "idle"
    }

    private var limiterColor: Color {
        model.engine.limiterCeiling == nil ? .secondary : .green
    }

    private var thermalText: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    private static func clampUnit(_ value: CGFloat) -> CGFloat {
        max(0, min(1, value))
    }
}
