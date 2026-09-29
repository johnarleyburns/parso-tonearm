import Foundation

/// Optional musical metadata shared by My Music and Mixes. It stays optional
/// so an unanalysed track is never presented as a fabricated 120 BPM/key.
public struct DJLoadTrackInfo: Equatable, Sendable {
    public var bpm: Double?
    public var camelotKey: String?

    public init(bpm: Double? = nil, camelotKey: String? = nil) {
        self.bpm = bpm
        self.camelotKey = camelotKey
    }

    public var bpmLabel: String {
        guard let bpm, bpm.isFinite, bpm > 0 else { return "— BPM" }
        return String(format: "%.1f BPM", bpm)
    }

    public var keyLabel: String { "KEY \(DJKeyFormatter.format(camelotKey))" }
}

/// Deterministic filtering for BPM and Camelot metadata in library lists.
public struct DJLoadTrackFilter: Equatable, Sendable {
    public var bpmMin: Double?
    public var bpmMax: Double?
    public var camelotKey: String?

    public init(bpmMin: Double? = nil, bpmMax: Double? = nil, camelotKey: String? = nil) {
        self.bpmMin = bpmMin
        self.bpmMax = bpmMax
        self.camelotKey = camelotKey
    }

    public var isEmpty: Bool { bpmMin == nil && bpmMax == nil && camelotKey == nil }

    public func matches(_ info: DJLoadTrackInfo) -> Bool {
        if bpmMin != nil || bpmMax != nil {
            guard let bpm = info.bpm, bpm.isFinite, bpm > 0 else { return false }
            if let bpmMin, (!bpmMin.isFinite || bpm < bpmMin) { return false }
            if let bpmMax, (!bpmMax.isFinite || bpm > bpmMax) { return false }
        }
        if let camelotKey, !camelotKey.isEmpty {
            guard let expected = DJKeyFormatter.normalized(camelotKey),
                  let actual = DJKeyFormatter.normalized(info.camelotKey) else { return false }
            guard expected == actual else { return false }
        }
        return true
    }
}

public enum DJKeyFormatter {
    public static func format(_ raw: String?) -> String { normalized(raw) ?? "—" }

    public static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard value.range(of: #"^(1[0-2]|[1-9])[AB]$"#, options: .regularExpression) != nil else {
            return nil
        }
        return value
    }

    public static func shifted(_ raw: String?, semitones: Int) -> String {
        let value = format(raw)
        guard value != "—", semitones != 0 else { return value }
        let number = Int(value.dropLast()) ?? 1
        let letter = value.last!
        let shiftedNumber = ((number - 1 + semitones * 7) % 12 + 12) % 12 + 1
        let sign = semitones > 0 ? "+" : ""
        return "\(shiftedNumber)\(letter) \(sign)\(semitones)"
    }
}
