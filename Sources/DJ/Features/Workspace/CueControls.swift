import SwiftUI

/// The cue controls (§44.2a, FR-HW-3, plan 6.4): a per-deck CUE button and the
/// mode picker that states what each mode costs.
///
/// Identifiers are `dj.cue.<a|b>` and `dj.cue.mode` — deliberately **not**
/// `dj.deck.<a|b>.cue`, which is already the CDJ cue *point* (§53.11). Two
/// different controls called "cue" is the reality of DJ equipment; sharing one
/// identifier between them would make a regression lane drive the wrong one.
struct CueButton: View {
    @ObservedObject var model: WorkspaceModel
    let deck: Deck
    var height: CGFloat = 32

    private var isCued: Bool { model.isCued(deck) }

    var body: some View {
        Button {
            model.toggleCue(deck)
        } label: {
            Text("CUE")
                .font(.system(size: 11, weight: .heavy))
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(isCued ? Color.orange : Color.white.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(isCued ? .black : .white.opacity(0.8))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("dj.cue.\(deck == .a ? "a" : "b")")
        .accessibilityLabel("Headphone cue deck \(deck == .a ? "A" : "B")")
        .accessibilityValue(isCued ? "on" : "off")
        .coachGlow(identifier: "dj.cue.\(deck == .a ? "a" : "b")")
    }
}

/// The mode picker. Every mode shows its cost, because on a phone every mode
/// has one and the user is choosing which trade to make (§44.2a, §50.1).
struct CueModePicker: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("CUE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: 0)
            }
            Picker("Cue mode", selection: Binding(
                get: { model.cueMode },
                set: { model.setCueMode($0) }
            )) {
                ForEach(CueMode.allCases, id: \.self) { mode in
                    Text(mode.displayName)
                        .tag(mode)
                        // A mode this route cannot deliver is shown and
                        // disabled rather than hidden: "why is there no
                        // interface option?" is a worse question than "why is
                        // it greyed out?", which the note below answers.
                        .disabled(!mode.isAvailable(outputChannels: model.outputChannelCount))
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("dj.cue.mode")
            .accessibilityValue(model.cueMode.displayName)

            if let note = model.cueMode.costNote {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("dj.cue.mode.note")
            }
        }
    }
}
