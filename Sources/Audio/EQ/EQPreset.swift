import Foundation

/// EQ presets (mockup screen 4) plus user-saved curves. Persisted alongside the
/// app's other settings via UserDefaults (mirrors the `@AppStorage` convention).
public struct EQPreset: Equatable, Codable, Identifiable {
    public var id: String { name }
    public let name: String
    public let gains: [Double]
    public let isBuiltIn: Bool

    public static let flat = EQPreset(name: "Flat",
                               gains: Array(repeating: 0, count: EQEngine.bandCount), isBuiltIn: true)

    // Gentle hall: slight low warmth + high air.
    public static let concertHall = EQPreset(name: "Concert hall",
        gains: [3, 2.5, 1.5, 0, -1, -1, 0, 1.5, 2.5, 3], isBuiltIn: true)

    // Spoken: presence boost, reduced rumble.
    public static let spoken = EQPreset(name: "Spoken",
        gains: [-6, -4, -1, 2, 3, 3, 2, 1, 0, -2], isBuiltIn: true)

    // 78 rpm: midrange-forward, rolled-off extremes (nods to IA collectors).
    public static let seventyEight = EQPreset(name: "78 rpm",
        gains: [-9, -7, -3, 2, 4, 4, 2, -2, -6, -10], isBuiltIn: true)

    public static let builtIns: [EQPreset] = [.flat, .concertHall, .spoken, .seventyEight]

    public var floatGains: [Float] {
        gains.map(Float.init)
    }
}
