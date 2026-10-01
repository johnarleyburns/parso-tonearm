import SwiftUI

/// Watch-local semantic tokens. The watch target intentionally does not link
/// the iPhone design module, but it still needs the same Dynamic Type and
/// appearance guarantees as the phone UI.
///
/// Watch redesign §3 (`docs/plans/watch-redesign/DESIGN.md`): the Watch Listening Kit. Every size
/// below is a semantic text style or a minimum hit target — never a fixed text size.
enum WatchTypography {
    static let display = Font.largeTitle.weight(.bold)
    static let title = Font.title2.weight(.semibold)
    static let headline = Font.headline
    static let body = Font.body
    static let callout = Font.callout
    static let caption = Font.caption
    static let micro = Font.caption2
    static let iconLarge = Font.title
    static let iconMedium = Font.callout
    static let iconSmall = Font.caption
    /// The diagnostic code under a Problem Card.
    static let code = Font.system(.caption2, design: .monospaced)
}

enum WatchPalette {
    /// Platterhead brass (`#E3A44B`), the accent for primary pills and the active target.
    static let accent = Color(red: 0xE3 / 255, green: 0xA4 / 255, blue: 0x4B / 255)
    /// Dark ink used on top of the accent fill.
    static let accentInk = Color(red: 0x1A / 255, green: 0x11 / 255, blue: 0x08 / 255)
    static let accentSoft = Color(red: 0x3A / 255, green: 0x29 / 255, blue: 0x14 / 255)
    static let surface = Color(red: 0x1C / 255, green: 0x1F / 255, blue: 0x24 / 255)
    static let surfaceRaised = Color(red: 0x2A / 255, green: 0x2E / 255, blue: 0x35 / 255)
    static let success = Color(red: 0x4C / 255, green: 0xD4 / 255, blue: 0x71 / 255)
    static let warning = Color(red: 0xFF / 255, green: 0xCC / 255, blue: 0x5C / 255)
    static let failure = Color(red: 0xFF / 255, green: 0x6B / 255, blue: 0x5E / 255)
    /// The translucent fill behind round transport and toolbar buttons.
    static let control = Color.white.opacity(0.08)
}

/// Minimum control sizes (§3): the transport never shrinks below these at any text size.
enum WatchMetrics {
    static let playButton: CGFloat = 58
    static let sideButton: CGFloat = 44
    static let toolButton: CGFloat = 30
    static let pillHeight: CGFloat = 40
    static let smallPillHeight: CGFloat = 34
}

extension Color {
    /// `#RRGGBB` → colour; `nil` for anything malformed (the phone's artwork colour is optional).
    init?(watchHex hex: String?) {
        guard let hex else { return nil }
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}
