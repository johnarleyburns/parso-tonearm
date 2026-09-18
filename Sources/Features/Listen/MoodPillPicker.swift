import SwiftUI
import TonearmCore

/// A horizontally-scrolling row of toggleable mood pills (docs/plans/
/// mood-based-listening-plan.md §3.1 point 3 / §5 step 4). Styled after
/// `MyMusicView.scopePicker`'s capsule-chip pattern, but multi-select
/// (toggle on/off) rather than single-select, since pills here combine
/// additively rather than switching between exclusive scopes.
struct MoodPillPicker: View {
    let pills: [MoodPill]
    @Binding var selection: Set<MoodPill.ID>

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pills) { pill in
                    let selected = selection.contains(pill.id)
                    Button {
                        if selected { selection.remove(pill.id) } else { selection.insert(pill.id) }
                    } label: {
                        Text(pill.label)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(selected ? .white : Palette.ink2)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(selected ? Palette.brassDeep : Color.white.opacity(0.07),
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("listen.mood.pill.\(pill.id)")
                }
            }
            .padding(.horizontal, 2)
        }
        .accessibilityIdentifier("listen.mood.pills")
    }
}
