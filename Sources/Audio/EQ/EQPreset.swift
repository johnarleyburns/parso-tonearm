import Foundation

/// EQ presets (mockup screen 4) plus user-saved curves. Persisted alongside the
/// app's other settings via UserDefaults (mirrors the `@AppStorage` convention).
struct EQPreset: Equatable, Codable, Identifiable {
    var id: String { name }
    let name: String
    let gains: [Double]
    let isBuiltIn: Bool

    static let flat = EQPreset(name: "Flat",
                               gains: Array(repeating: 0, count: EQEngine.bandCount), isBuiltIn: true)

    // Gentle hall: slight low warmth + high air.
    static let concertHall = EQPreset(name: "Concert hall",
        gains: [3, 2.5, 1.5, 0, -1, -1, 0, 1.5, 2.5, 3], isBuiltIn: true)

    // Spoken: presence boost, reduced rumble.
    static let spoken = EQPreset(name: "Spoken",
        gains: [-6, -4, -1, 2, 3, 3, 2, 1, 0, -2], isBuiltIn: true)

    // 78 rpm: midrange-forward, rolled-off extremes (nods to IA collectors).
    static let seventyEight = EQPreset(name: "78 rpm",
        gains: [-9, -7, -3, 2, 4, 4, 2, -2, -6, -10], isBuiltIn: true)

    static let builtIns: [EQPreset] = [.flat, .concertHall, .spoken, .seventyEight]
}

/// Storage + selection surface for EQ state, gated by `ProFeature.eq` at the UI.
enum EQSettings {
    private static let enabledKey = "eq.enabled"
    private static let gainsKey = "eq.gains"
    private static let userPresetsKey = "eq.userPresets"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var gains: [Double] {
        get {
            guard let arr = UserDefaults.standard.array(forKey: gainsKey) as? [Double],
                  arr.count == EQEngine.bandCount else {
                return Array(repeating: 0, count: EQEngine.bandCount)
            }
            return arr
        }
        set { UserDefaults.standard.set(newValue, forKey: gainsKey) }
    }

    static var userPresets: [EQPreset] {
        get {
            guard let data = UserDefaults.standard.data(forKey: userPresetsKey),
                  let presets = try? JSONDecoder().decode([EQPreset].self, from: data) else { return [] }
            return presets
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: userPresetsKey)
            }
        }
    }

    static func saveUserPreset(name: String, gains: [Double]) {
        var presets = userPresets
        presets.removeAll { $0.name == name }
        presets.append(EQPreset(name: name, gains: gains, isBuiltIn: false))
        userPresets = presets
    }

    static var allPresets: [EQPreset] { EQPreset.builtIns + userPresets }
}
