import SwiftUI
import TonearmCore

struct DJFocusDock: View {
    @ObservedObject var model: DJPerformanceModel
    let onLoad: () -> Void
    let onMixer: () -> Void
    @State private var crossedCenter = false

    var body: some View {
        VStack(spacing: 6) {
            Text("CROSSFADER")
                .font(.caption2.monospaced())
            Slider(value: crossfaderBinding)
                .accessibilityLabel("Crossfader")
                .onChange(of: model.crossfader) { _, value in
                    let atCenter = abs(value - 0.5) < 0.0001
                    if atCenter != crossedCenter { crossedCenter = atCenter }
                }
                .sensoryFeedback(.selection, trigger: crossedCenter)
                .accessibilityIdentifier("dj.focus.crossfader")
            HStack {
                Button("Library", action: onLoad)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .accessibilityIdentifier("dj.focus.library")
                Button("Mixer", action: onMixer)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .accessibilityIdentifier("dj.focus.mixer")
            }
        }
        .padding(10)
        .accessibilityIdentifier("dj.focus.dock")
    }

    private var crossfaderBinding: Binding<Double> {
        Binding(
            get: { model.crossfader },
            set: { value in model.setCrossfader(DJFaderMapping.snapped(value)) }
        )
    }
}
