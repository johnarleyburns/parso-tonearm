import SwiftUI

/// The §41.9b pad block (rule 5): the `HOT CUE · PAD FX · BEAT JUMP · SAMPLER`
/// mode selector immediately above **eight** pads in two rows of four. The pads
/// render the honest placeholder state — the pad *features* (hot cues, pad FX,
/// beat jump, sampler) land with their own commits; the block's job in 5.4 is
/// the club-standard geometry (eight, under the selector, ≥ 44 pt).
struct PadBlock: View {
    @ObservedObject var model: WorkspaceModel
    let deck: Deck

    @State private var modeIndex = 0

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(Array(WorkspaceModel.ClubGeometry.padModes.enumerated()), id: \.offset) { index, mode in
                    Button {
                        modeIndex = index
                    } label: {
                        Text(mode)
                            .font(.system(size: 9, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                            .background(
                                modeIndex == index ? Color.accentColor.opacity(0.28)
                                                   : Color.white.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                            .foregroundStyle(modeIndex == index ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(height: 34)

            ForEach(0..<WorkspaceModel.ClubGeometry.padRows, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(0..<WorkspaceModel.ClubGeometry.padColumns, id: \.self) { col in
                        let index = row * WorkspaceModel.ClubGeometry.padColumns + col
                        Text(padLabel(index: index))
                            .font(.system(size: 12, weight: .bold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private func padLabel(index: Int) -> String {
        // Honest placeholder until the pad features land: the pad row carries
        // the mode's implied labels (A–H hot cues) without pretending the
        // engine is wired.
        String(UnicodeScalar(("A" as UnicodeScalar).value + UInt32(index)) ?? "A")
    }
}
