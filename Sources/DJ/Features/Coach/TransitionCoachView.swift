import SwiftUI

/// The §41.18 transition coach panel (mockup `ipad/16-transitions.html`,
/// FR-TRANS-6): the §35B five as teaching lessons. Selecting a lesson lights
/// the **real controls in place** on the performance surface behind the panel —
/// `TransitionCoachModel.highlightedIdentifiers` is the §53.11 identifier set
/// the surface highlights, so the walkthrough can never drift from the app.
///
/// Three rules (§41.18, the mockup's caption): it **never takes over** (a
/// dismissible overlay; the decks keep playing underneath), it **never
/// performs the transition** (no auto-mix affordance exists anywhere in this
/// view — a lesson is copy and a highlight set, nothing more), and it is
/// **free** (no gate — the panel renders identically for free and Pro users).
public struct TransitionCoachView: View {
    @ObservedObject var model: TransitionCoachModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(model: TransitionCoachModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            if horizontalSizeClass == .compact {
                ScrollView(.vertical) {
                    VStack(spacing: 10) {
                        lessonList
                        detail
                    }
                    .padding(12)
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    lessonList
                    detail
                }
                .padding(12)
            }
        }
        .background(Color(red: 0.04, green: 0.043, blue: 0.055))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .accessibilityIdentifier("dj.coach.panel")
    }

    /// The mockup's top bar: the Free pill, the title, the "nothing to turn on"
    /// note, and the Close button.
    private var header: some View {
        HStack(spacing: 10) {
            Text("Free")
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.green.opacity(0.12), in: Capsule())
                .foregroundStyle(Color.green)

            Text("The five transitions")
                .font(.system(size: 15, weight: .bold))

            Text("Everything here works on the surface you already have — nothing to turn on.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                model.dismiss()
            } label: {
                Label("Close", systemImage: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.06), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.white.opacity(0.03))
        .overlay(alignment: .bottom) {
            Divider().overlay(Color.white.opacity(0.06))
        }
    }

    /// The five §35B lessons as a selectable list (left column on a wide
    /// surface, above the detail on a narrow one). Each row names the
    /// transition and marks the selected one.
    private var lessonList: some View {
        VStack(spacing: 6) {
            ForEach(Array(TransitionCoachModel.allLessons.enumerated()), id: \.offset) { index, lesson in
                let selected = model.selectedIndex == index
                Button {
                    model.select(index)
                } label: {
                    HStack(spacing: 9) {
                        Text("\(index + 1)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .frame(width: 21, height: 21)
                            .background(
                                selected ? Color.accentColor.opacity(0.3)
                                         : Color.white.opacity(0.07),
                                in: Circle())
                            .foregroundStyle(selected ? Color.accentColor : .secondary)
                        Text(lesson.id)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(selected ? Color.accentColor : .primary)
                        Spacer()
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(
                        selected ? Color.accentColor.opacity(0.10)
                                 : Color.white.opacity(0.02),
                        in: RoundedRectangle(cornerRadius: 9))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(selected ? Color.accentColor.opacity(0.45)
                                             : Color.white.opacity(0.05),
                                    lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 190, alignment: .leading)
    }

    /// The selected lesson's walkthrough (right column, mockup `ipad/16`): the
    /// description, when to reach for it, the control chips, and the "coach
    /// never does it for you" note. Purely presentational — the highlight
    /// happens on the surface behind the panel.
    private var detail: some View {
        let lesson = model.selectedLesson
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(lesson.id) · where your hands go")
                    .font(.system(size: 10, weight: .bold))
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("on your surface")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }

            Text(lesson.summary)
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.92))
                .lineSpacing(2)

            Text("When to reach for it")
                .font(.system(size: 9, weight: .bold))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Text(lesson.whenToUse)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)

            Text("Controls it moves")
                .font(.system(size: 9, weight: .bold))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            WrapChips(chips: lesson.steps)

            Spacer(minLength: 0)

            Text("The coach never does it for you. There is no auto-mix button "
                 + "here and there never will be — it shows you where the hands "
                 + "go, and you move them. The decks keep playing while this "
                 + "panel is open.")
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary.opacity(0.85))
                .lineSpacing(1.5)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.03)))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.05), lineWidth: 1))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(minHeight: 230, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.02)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.05), lineWidth: 1))
    }
}

/// The walkthrough's control chips (mockup `ipad/16`'s `.ctl` row): the named
/// controls wrap into rows, the key ones (LOW, FILTER, ECHO, faders, crossfader)
/// render as filled chips and the descriptive ones as plain text.
private struct WrapChips: View {
    let chips: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Self.rows(chips), id: \.self) { row in
                HStack(spacing: 5) {
                    ForEach(row, id: \.self) { chip in
                        Text(chip)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                Self.isKey(chip) ? Color.accentColor.opacity(0.14)
                                                 : Color.white.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 5))
                            .foregroundStyle(Self.isKey(chip) ? Color.accentColor : .secondary)
                    }
                }
            }
        }
    }

    /// Wrap chips greedily into rows of a bounded width (the detail column is
    /// ~300 pt on a wide surface) — the mockup's `.ctl` flex-wrap.
    private static func rows(_ chips: [String]) -> [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        var width: CGFloat = 0
        for chip in chips {
            let chipWidth = 18 + CGFloat(chip.count) * 6
            if !current.isEmpty && width + chipWidth > 300 {
                result.append(current)
                current = []
                width = 0
            }
            current.append(chip)
            width += chipWidth + 5
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// The chip the coach treats as the key control — filled, accent-coloured.
    private static func isKey(_ chip: String) -> Bool {
        chip.contains("LOW") || chip.contains("FILTER") || chip.contains("ECHO")
            || chip.contains("fader") || chip.contains("MID") || chip.contains("crossfader")
            || chip.contains("sharp")
    }
}
