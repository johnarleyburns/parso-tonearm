import Foundation

/// User-facing EQ state. This is a pure value: no UI frameworks, no I/O.
public struct EQSettings: Equatable, Codable {
    public var bands: [Float]
    public var enabled: Bool
    public var activePresetID: String?

    public static let flat = EQSettings(
        bands: Array(repeating: 0, count: EQEngine.bandCount),
        enabled: false,
        activePresetID: EQPreset.flat.id
    )
}

/// Pure EQ policy: clamping, preset resolution, modified detection, and payload
/// serialization for persistence.
public struct EQSettingsStore {
    public static let minGain: Float = -12
    public static let maxGain: Float = 12

    public struct Payload: Equatable, Codable {
        var bands: [Float]
        var enabled: Bool
        var activePresetID: String?
    }

    public var presets: [EQPreset] = EQPreset.builtIns

    public func normalized(_ settings: EQSettings) -> EQSettings {
        var bands = Array(settings.bands.prefix(EQEngine.bandCount))
        if bands.count < EQEngine.bandCount {
            bands.append(contentsOf: Array(repeating: 0, count: EQEngine.bandCount - bands.count))
        }
        bands = bands.map { min(Self.maxGain, max(Self.minGain, $0)) }
        return EQSettings(bands: bands, enabled: settings.enabled, activePresetID: settings.activePresetID)
    }

    public func bands(forPresetID presetID: String?) -> [Float] {
        guard let presetID,
              let preset = presets.first(where: { $0.id == presetID }) else {
            return EQPreset.flat.floatGains
        }
        return normalized(EQSettings(bands: preset.floatGains, enabled: true, activePresetID: preset.id)).bands
    }

    public func applyingPreset(id presetID: String, to settings: EQSettings) -> EQSettings {
        let resolvedID = presets.contains(where: { $0.id == presetID }) ? presetID : EQPreset.flat.id
        return normalized(EQSettings(
            bands: bands(forPresetID: resolvedID),
            enabled: settings.enabled,
            activePresetID: resolvedID
        ))
    }

    public func updatingBand(at index: Int, to gain: Float, in settings: EQSettings) -> EQSettings {
        var next = normalized(settings)
        guard next.bands.indices.contains(index) else { return next }
        next.bands[index] = min(Self.maxGain, max(Self.minGain, gain))
        return next
    }

    public func isModifiedFromPreset(_ settings: EQSettings) -> Bool {
        guard let presetID = settings.activePresetID else { return false }
        return normalized(settings).bands != bands(forPresetID: presetID)
    }

    public func effectiveBands(for settings: EQSettings) -> [Float] {
        settings.enabled ? normalized(settings).bands : EQPreset.flat.floatGains
    }

    public func payload(for settings: EQSettings) -> Payload {
        let normalized = normalized(settings)
        return Payload(
            bands: normalized.bands,
            enabled: normalized.enabled,
            activePresetID: normalized.activePresetID
        )
    }

    public func settings(from payload: Payload?) -> EQSettings {
        guard let payload else { return .flat }
        return normalized(EQSettings(
            bands: payload.bands,
            enabled: payload.enabled,
            activePresetID: payload.activePresetID
        ))
    }

    public func encodedPayload(for settings: EQSettings) -> Data? {
        try? JSONEncoder().encode(payload(for: settings))
    }

    public func settings(fromEncodedPayload data: Data?) -> EQSettings {
        guard let data,
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return .flat
        }
        return settings(from: payload)
    }

    public func userPreset(named name: String, settings: EQSettings) -> EQPreset? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return EQPreset(name: trimmed, gains: normalized(settings).bands.map(Double.init), isBuiltIn: false)
    }
}

/// Thin UserDefaults adapter for EQ state. Persistence stays here; product rules
/// stay in `EQSettingsStore`.
public enum EQSettingsPersistence {
    private static let settingsKey = "eq.settings.payload"
    private static let legacyEnabledKey = "eq.enabled"
    private static let legacyGainsKey = "eq.gains"
    private static let userPresetsKey = "eq.userPresets"

    public static func load(defaults: UserDefaults = .standard) -> EQSettings {
        let store = EQSettingsStore(presets: allPresets(defaults: defaults))
        if let data = defaults.data(forKey: settingsKey) {
            return store.settings(fromEncodedPayload: data)
        }
        if let gains = defaults.array(forKey: legacyGainsKey) as? [Double] {
            return store.normalized(EQSettings(
                bands: gains.map(Float.init),
                enabled: defaults.bool(forKey: legacyEnabledKey),
                activePresetID: nil
            ))
        }
        return .flat
    }

    public static func save(_ settings: EQSettings, defaults: UserDefaults = .standard) {
        let store = EQSettingsStore(presets: allPresets(defaults: defaults))
        defaults.set(store.encodedPayload(for: settings), forKey: settingsKey)
    }

    public static func userPresets(defaults: UserDefaults = .standard) -> [EQPreset] {
        guard let data = defaults.data(forKey: userPresetsKey),
              let presets = try? JSONDecoder().decode([EQPreset].self, from: data) else {
            return []
        }
        return presets
    }

    public static func allPresets(defaults: UserDefaults = .standard) -> [EQPreset] {
        EQPreset.builtIns + userPresets(defaults: defaults)
    }

    public static func saveUserPreset(_ preset: EQPreset, defaults: UserDefaults = .standard) {
        var presets = userPresets(defaults: defaults)
        presets.removeAll { $0.id == preset.id }
        presets.append(preset)
        if let data = try? JSONEncoder().encode(presets) {
            defaults.set(data, forKey: userPresetsKey)
        }
    }
}
