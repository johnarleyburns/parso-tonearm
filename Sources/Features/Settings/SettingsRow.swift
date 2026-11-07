import SwiftUI
import TonearmCore

/// A single disclosure-style Settings row: leading icon chip, title/detail,
/// optional count badge, trailing glyph (chevron for navigation, an
/// up-right arrow for an external link, or none for a plain info row).
///
/// Modeled on `../parso-voxglass`'s `DisclosureListRow`, using Tonearm's own
/// design tokens rather than Voxglass's — this is a structural/layout lesson,
/// not a re-skin. Every row in Settings that navigates somewhere (a sheet, a
/// pushed screen, or an external link) should build its label from this one
/// component instead of hand-rolling its own `HStack`, so icon placement and
/// spacing stay consistent across the whole screen.
struct SettingsRow: View {
    var icon: String
    var title: LocalizedStringKey
    var detail: Text?
    var count: Int?
    var trailingIcon: String? = "chevron.right"
    var tint: Color = Palette.accent

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(Typography.callout)
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(tint.opacity(0.14))
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typography.callout).minimumScaleFactor(0.82)
                if let detail {
                    detail.font(Typography.caption).foregroundStyle(Palette.inkTertiary)
                        .contentTransition(.numericText())
                }
            }

            Spacer(minLength: 10)

            if let count {
                Text("\(count)")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Palette.ink.opacity(0.07), in: Capsule())
            }

            if let trailingIcon {
                Image(systemName: trailingIcon)
                    .font(Typography.callout)
                    .foregroundStyle(Palette.inkTertiary)
            }
        }
    }
}
