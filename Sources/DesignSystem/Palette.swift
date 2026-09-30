import SwiftUI

/// Semantic colors are backed by dynamic asset-catalog colors so the same
/// component remains legible in both appearances.
enum Palette {
    // The assets live in the `Palette` group in the catalog, but the group is
    // not part of the runtime asset name. Including it here makes every
    // lookup miss and leaves the views with an invalid/clear color.
    static let background = Color("background")
    static let surface = Color("surface")
    static let surfaceRaised = Color("surfaceRaised")
    static let ink = Color("ink")
    static let inkSecondary = Color("inkSecondary")
    static let inkTertiary = Color("inkTertiary")
    static let hairline = Color("hairline")
    static let accent = Color("accent")
    static let accentOnFill = Color("accentOnFill")
    static let success = Color("success")
    static let danger = Color("danger")

    static var libraryBackground: LinearGradient {
        LinearGradient(colors: [surface, background], startPoint: .top, endPoint: .bottom)
    }

    static var sourcesBackground: LinearGradient {
        LinearGradient(stops: [
            .init(color: accent.opacity(0.18), location: 0),
            .init(color: surface, location: 0.34),
            .init(color: background, location: 0.70)
        ], startPoint: .top, endPoint: .bottom)
    }

    static func genre(_ index: Int) -> Color {
        [accent, Color("genreBlue"), Color("genrePurple"),
         Color("genreGreen"), Color("genreRed"),
         Color("genreTeal"), Color("genrePink"),
         Color("genreOrange")][abs(index) % 8]
    }
}
