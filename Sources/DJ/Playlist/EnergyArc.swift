import Foundation

/// The energy-arc presets and the drawn-arc form (§28A.5). Each arc is a pure
/// closed-form shape over normalized position `t` in [0,1]; `value(at:)` returns
/// a normalized [0,1] quantile that the generator maps through the candidate
/// set's empirical energy CDF — so "1.0" always means "the most energetic thing
/// that fits this brief", never an absolute scale.
///
/// The database stores an arc as `arcKind` (`steady|build|peakRelease|windDown|
/// wave|custom`, §14.3) plus `arcPointsJSON`, the canonical JSON encoding of the
/// arc's parameter payload (`level` / `peakAt` / `cycles` / custom `points`).
/// `from(kindCode:pointsJSON:)` round-trips a row back to an `EnergyArc`, so a
/// dragged peak or a drawn arc survives persistence.
public enum EnergyArc: Codable, Sendable, Equatable {
    case steady(level: Double)
    case build
    case peakAndRelease(peakAt: Double)
    case windDown
    case wave(cycles: Double)
    case custom(points: [Double])

    public static let defaultLevel = 0.5
    public static let defaultPeakAt = 0.7
    public static let defaultCycles = 1.0

    /// §14.3 `arcKind` values.
    public var kindCode: String {
        switch self {
        case .steady: return "steady"
        case .build: return "build"
        case .peakAndRelease: return "peakRelease"
        case .windDown: return "windDown"
        case .wave: return "wave"
        case .custom: return "custom"
        }
    }

    /// The closed-form value at normalized position `t`. Pure and deterministic
    /// (NFR-DET-3): same arc, same `t`, same value, on every device.
    public func value(at t: Double) -> Double {
        let x = min(1, max(0, t))
        switch self {
        case .steady(let level):
            return min(1, max(0, level))
        case .build:
            return Self.smoothstep(x)
        case .peakAndRelease(let peakAt):
            return Self.peakAndRelease(x, peakAt: peakAt)
        case .windDown:
            return 1 - Self.smoothstep(x)
        case .wave(let cycles):
            let c = cycles > 0 ? cycles : EnergyArc.defaultCycles
            return 0.5 + 0.5 * sin(2 * .pi * c * x)
        case .custom(let points):
            return Self.interpolate(x, points: points)
        }
    }

    /// The `arcPointsJSON` payload for the row: `{"level":…}` / `{"peakAt":…}` /
    /// `{"cycles":…}` / `{"points":[…]}` / `{}`. `.sortedKeys` + fixed field
    /// order ⇒ byte-exact for a given arc (NFR-DET-3), so the row round-trips.
    public var pointsJSON: String {
        let payload: ArcPayload
        switch self {
        case .steady(let level): payload = ArcPayload(level: level)
        case .build: payload = ArcPayload()
        case .peakAndRelease(let peakAt): payload = ArcPayload(peakAt: peakAt)
        case .windDown: payload = ArcPayload()
        case .wave(let cycles): payload = ArcPayload(cycles: cycles)
        case .custom(let points): payload = ArcPayload(points: points)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(payload)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Rebuild an arc from its `auto_playlist_brief` columns (§14.3).
    public static func from(kindCode: String, pointsJSON: String?) -> EnergyArc? {
        let payload = pointsJSON
            .flatMap { try? JSONDecoder().decode(ArcPayload.self, from: Data($0.utf8)) }
        switch kindCode {
        case "steady": return .steady(level: payload?.level ?? EnergyArc.defaultLevel)
        case "build": return .build
        case "peakRelease":
            return .peakAndRelease(peakAt: payload?.peakAt ?? EnergyArc.defaultPeakAt)
        case "windDown": return .windDown
        case "wave": return .wave(cycles: payload?.cycles ?? EnergyArc.defaultCycles)
        case "custom": return .custom(points: payload?.points ?? [])
        default: return nil
        }
    }

    // MARK: - Closed forms

    /// Smoothstep, the "gentle S-curve" of §28A.5's build (and its mirror for
    /// wind-down): 0 at 0, 1 at 1, zero slope at both ends.
    private static func smoothstep(_ t: Double) -> Double {
        t * t * (3 - 2 * t)
    }

    /// Rise to 1 at `peakAt`, then fall to 0 at 1 — both halves smoothstep, so
    /// the curve is continuous and non-differentiable only at the peak itself.
    private static func peakAndRelease(_ x: Double, peakAt: Double) -> Double {
        let p = max(0.01, min(1.0, peakAt))
        if x <= p {
            return smoothstep(x / p)
        }
        return 1 - smoothstep((x - p) / (1 - p))
    }

    /// Piecewise-linear interpolation of user-drawn points over [0,1] (§28A.5
    /// `custom`). Clamped to [0,1]; a single point is a constant; empty is the
    /// neutral 0.5.
    private static func interpolate(_ x: Double, points: [Double]) -> Double {
        guard !points.isEmpty else { return 0.5 }
        if points.count == 1 { return min(1, max(0, points[0])) }
        let scaled = min(1, max(0, x)) * Double(points.count - 1)
        let index = min(points.count - 2, Int(scaled.rounded(.down)))
        let fraction = scaled - Double(index)
        let value = points[index] + (points[index + 1] - points[index]) * fraction
        return min(1, max(0, value))
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case kind, value, points
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .steady(let level):
            try container.encode("steady", forKey: .kind)
            try container.encode(level, forKey: .value)
        case .build:
            try container.encode("build", forKey: .kind)
        case .peakAndRelease(let peakAt):
            try container.encode("peakRelease", forKey: .kind)
            try container.encode(peakAt, forKey: .value)
        case .windDown:
            try container.encode("windDown", forKey: .kind)
        case .wave(let cycles):
            try container.encode("wave", forKey: .kind)
            try container.encode(cycles, forKey: .value)
        case .custom(let points):
            try container.encode("custom", forKey: .kind)
            try container.encode(points, forKey: .points)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "steady":
            self = .steady(level: try container.decodeIfPresent(Double.self, forKey: .value)
                           ?? EnergyArc.defaultLevel)
        case "build":
            self = .build
        case "peakRelease":
            self = .peakAndRelease(peakAt: try container.decodeIfPresent(Double.self, forKey: .value)
                                   ?? EnergyArc.defaultPeakAt)
        case "windDown":
            self = .windDown
        case "wave":
            self = .wave(cycles: try container.decodeIfPresent(Double.self, forKey: .value)
                         ?? EnergyArc.defaultCycles)
        case "custom":
            self = .custom(points: try container.decode([Double].self, forKey: .points))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container,
                debugDescription: "Invalid arc kind: \(kind)")
        }
    }
}

/// The parameter payload stored in `arcPointsJSON` (§28A.5, plan §2). All
/// optional so the all-nil case encodes as `{}`.
private struct ArcPayload: Codable {
    var level: Double?
    var peakAt: Double?
    var cycles: Double?
    var points: [Double]?
}

/// Deterministic mapping of a candidate set's stored energies (0...10 scalar)
/// onto the [0,1] percentile ranks the sequencer compares against the arc
/// (§28A.5). "The most energetic thing that fits the brief" is rank 1.0; ties
/// share the CDF rank of their highest member; a missing energy is the neutral
/// 0.5. Ordering is by (energy, trackID), so the mapping is stable and
/// reproducible (NFR-DET-3).
public enum EmpiricalEnergyCDF {

    public static func ranks(energies: [(trackID: Int64, energy: Double?)]) -> [Int64: Double] {
        let present = energies.compactMap { entry -> (trackID: Int64, energy: Double)? in
            entry.energy.map { (entry.trackID, $0) }
        }.sorted { a, b in
            if a.energy != b.energy { return a.energy < b.energy }
            return a.trackID < b.trackID
        }

        var result: [Int64: Double] = [:]
        let count = Double(present.count)
        guard count > 0 else {
            for entry in energies { result[entry.trackID] = 0.5 }
            return result
        }

        var index = 0
        while index < present.count {
            let value = present[index].energy
            var upper = index
            while upper < present.count, present[upper].energy == value { upper += 1 }
            let rank = Double(upper) / count
            for k in index..<upper { result[present[k].trackID] = rank }
            index = upper
        }
        for entry in energies where entry.energy == nil { result[entry.trackID] = 0.5 }
        return result
    }
}
