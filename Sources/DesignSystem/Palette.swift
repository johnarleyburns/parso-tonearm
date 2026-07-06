import SwiftUI

enum Palette {
    static let bg = Color(hex: 0x0A0B0D)
    static let ink = Color(hex: 0xF2F4F6)
    static let ink2 = Color(white: 0.92).opacity(0.58)
    static let ink3 = Color(white: 0.92).opacity(0.34)
    static let brass = Color(hex: 0xE3A44B)
    static let brassDeep = Color(hex: 0xB97F2E)
    static let ok = Color(hex: 0x4CD471)
    static let danger = Color(hex: 0xFF6B5E)
    static let hairline = Color.white.opacity(0.10)

    static var libraryBackground: LinearGradient {
        LinearGradient(colors: [Color(hex: 0x101216), Color(hex: 0x0B0C0F)],
                       startPoint: .top, endPoint: .bottom)
    }

    static var sourcesBackground: LinearGradient {
        LinearGradient(stops: [
            .init(color: Color(hex: 0x241A10), location: 0),
            .init(color: Color(hex: 0x12100C), location: 0.34),
            .init(color: Color(hex: 0x0B0C0F), location: 0.70)
        ], startPoint: .top, endPoint: .bottom)
    }
}

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
