import SwiftUI

/// Semantic colors are backed by dynamic asset-catalog colors so the same
/// component remains legible in both appearances.
enum Palette {
    static let background = Color("Palette/background")
    static let surface = Color("Palette/surface")
    static let surfaceRaised = Color("Palette/surfaceRaised")
    static let ink = Color("Palette/ink")
    static let inkSecondary = Color("Palette/inkSecondary")
    static let inkTertiary = Color("Palette/inkTertiary")
    static let hairline = Color("Palette/hairline")
    static let accent = Color("Palette/accent")
    static let accentOnFill = Color("Palette/accentOnFill")
    static let success = Color("Palette/success")
    static let danger = Color("Palette/danger")

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
        [accent, Color("Palette/genreBlue"), Color("Palette/genrePurple"),
         Color("Palette/genreGreen"), Color("Palette/genreRed"),
         Color("Palette/genreTeal"), Color("Palette/genrePink"),
         Color("Palette/genreOrange")][abs(index) % 8]
    }
}
