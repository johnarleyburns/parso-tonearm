import SwiftUI

/// Watch-local semantic tokens. The watch target intentionally does not link
/// the iPhone design module, but it still needs the same Dynamic Type and
/// appearance guarantees as the phone UI.
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
}

enum WatchPalette {
    static let success = Color.accentColor
}
