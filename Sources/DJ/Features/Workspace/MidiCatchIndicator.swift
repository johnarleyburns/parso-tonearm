import SwiftUI

/// The M2 soft-takeover catch indicator: while a MIDI control is awaiting
/// pickup, a small pill names the control and which way to move it. Without
/// this, pickup feels identical to a broken fader — the physical control is
/// deliberately doing nothing, and the user has to be told that and why.
struct MidiCatchIndicator: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        let items = model.midiCatchItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.target) { item in
                    Label(item.label, systemImage: "arrow.up.arrow.down")
                        .font(.caption)
                        .accessibilityIdentifier("dj.midi.catch.\(item.target)")
                }
            }
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
            )
            .accessibilityIdentifier("dj.midi.catch")
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
