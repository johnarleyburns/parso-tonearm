import Foundation

/// A point on the jog surface (§40.7.2). `Double` coordinates keep the model
/// pure — no CoreGraphics, no SwiftUI — so it runs deterministically on any
/// host and is unit-tested without a view.
public struct JogPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public func distance(to other: JogPoint) -> Double {
        hypot(x - other.x, y - other.y)
    }
}

/// The contact-relative jog gesture state machine (§40.7.2–40.7.4, plan 4.8).
///
/// A pure value type — no SwiftUI, no UIKit, no engine reference. The view
/// drives it from touch events (touch-down / move / lift) and consumes the
/// `Intent`s it emits; the only things that cross the seam are the four
/// transport intents of FR-ENG-11 (`hold`, `scrub`, `nudge`, `release`), so
/// the jog can never execute anything on the render thread (§40.7.7).
///
/// Two properties make the small platter usable (§40.7.1):
/// - rotation is measured **contact-relative** from wherever the finger lands
///   (§40.7.2), so the thumb never has to reach across the disc;
/// - the **radius split** (platter = inner 58%, ring = outer 42%) is decided at
///   touch-down and **fixed for the duration of the gesture** — a drag that
///   crosses the boundary mid-gesture must not change mode (§40.7.3).
public struct JogGestureModel: Sendable, Equatable {

    /// The region a touch landed in, fixed at touch-down (§40.7.3).
    public enum Region: Sendable, Equatable {
        /// Inner 58% — **position**: touch = hold, rotation = scrub.
        case platter
        /// Outer 42% — **pitch bend**: a temporary tempo offset, released on lift.
        case ring
    }

    /// The intent a jog gesture emits (§40.7.7, FR-ENG-11). These are the only
    /// four intents the jog may produce; the model performs no engine work.
    public enum Intent: Sendable, Equatable {
        /// Touch-down on the platter — touch = hold (§40.7.3).
        case hold
        /// Platter rotation while held: the contact-relative,
        /// sensitivity-scaled angular displacement in radians (the position /
        /// scratch intent).
        case scrub(radians: Double)
        /// Ring rotation: a temporary tempo bend, `rate` = signed offset
        /// (0.04 = +4%), released on lift.
        case nudge(rate: Double)
        /// Lift — ends the gesture (both regions).
        case release
    }

    /// The inner-platter fraction of the radius (§40.7.3: platter 58% / ring 42%).
    public static let platterFraction: Double = 0.58
    /// The ring's bend saturates at ±π of contact-relative rotation (a half turn).
    public static let maxBendAngle: Double = .pi
    /// The maximum temporary tempo offset the ring applies: ±16% (§40.7.3's
    /// coarse, forgiving bend surface).
    public static let maxBendRate: Double = 0.16
    /// The jog sensitivity range (§40.7.4). Clamped at init.
    public static let sensitivityRange: ClosedRange<Double> = 0.5...2.0

    /// Per-deck jog sensitivity, 0.5–2.0 (§40.7.4). Scratchers raise it,
    /// nudgers lower it; it scales the effective angular displacement.
    public var sensitivity: Double
    /// The inner-platter fraction of the radius (0.58, §40.7.3).
    public var platterFraction: Double

    /// Whether a finger is currently down on the jog.
    public private(set) var isTracking = false
    /// The region fixed at touch-down (nil before touch / after lift).
    public private(set) var region: Region?
    /// The contact-relative displacement accumulated since touch-down
    /// (sensitivity-scaled, radians). 0 before touch and after lift.
    public private(set) var displacementRadians: Double = 0

    private var center = JogPoint(x: 0, y: 0)
    private var touchDownAngle: Double = 0

    public init(sensitivity: Double = 1.0,
                platterFraction: Double = JogGestureModel.platterFraction) {
        self.sensitivity = Self.clampSensitivity(sensitivity)
        self.platterFraction = min(max(platterFraction, 0), 1)
    }

    /// Clamp sensitivity into the §40.7.4 range (0.5–2.0).
    public static func clampSensitivity(_ value: Double) -> Double {
        min(max(value, sensitivityRange.lowerBound), sensitivityRange.upperBound)
    }

    /// A touch lands. Returns `.hold` when it lands on the platter (touch =
    /// hold); the ring is a bend surface and emits nothing until it rotates.
    /// The region is fixed here and never changes for the gesture (§40.7.3).
    public mutating func touchDown(at point: JogPoint, center: JogPoint,
                                   radius: Double) -> Intent? {
        guard radius > 0, !isTracking else { return nil }
        self.center = center
        isTracking = true
        displacementRadians = 0
        let isPlatter = point.distance(to: center) <= radius * platterFraction
        region = isPlatter ? .platter : .ring
        touchDownAngle = Self.angle(of: point, around: center)
        return isPlatter ? .hold : nil
    }

    /// The finger moves. Emits `.scrub` for platter rotation or `.nudge` for
    /// ring rotation, measured contact-relative from wherever the finger landed
    /// (§40.7.2) and scaled by sensitivity (§40.7.4). A move that crosses the
    /// platter/ring boundary keeps the touch-down region — mode never changes.
    public mutating func touchMoved(to point: JogPoint) -> Intent? {
        guard isTracking, let region else { return nil }
        let delta = Self.normalizedAngle(Self.angle(of: point, around: center) - touchDownAngle)
        let scaled = delta * sensitivity
        displacementRadians = scaled
        switch region {
        case .platter:
            if abs(scaled) > 1e-9 { return .scrub(radians: scaled) }
        case .ring:
            let bend = Self.bendRate(angle: scaled)
            if abs(bend) > 1e-9 { return .nudge(rate: bend) }
        }
        return nil
    }

    /// The finger lifts. Emits `.release` and resets the gesture (both regions).
    public mutating func touchUp() -> Intent? {
        guard isTracking else { return nil }
        isTracking = false
        region = nil
        displacementRadians = 0
        return .release
    }

    /// The temporary tempo offset for a ring rotation: saturates at
    /// `±maxBendRate` across `±maxBendAngle` of rotation (§40.7.3).
    public static func bendRate(angle: Double) -> Double {
        let clamped = min(max(angle / maxBendAngle, -1), 1)
        return clamped * maxBendRate
    }

    /// The angle of a point around the jog centre, in radians (−π … π). The
    /// exact centre is defined as angle 0 so a touch at the hub is well-behaved.
    static func angle(of point: JogPoint, around center: JogPoint) -> Double {
        let dx = point.x - center.x
        let dy = point.y - center.y
        guard dx != 0 || dy != 0 else { return 0 }
        return atan2(dy, dx)
    }

    /// Normalize an angle into (−π, π] so a finger crossing the touch-down
    /// axis mid-gesture cannot read as a full-turn jump (§40.7.2's single-thumb
    /// arc — a thumb sweeps < π before regripping).
    static func normalizedAngle(_ angle: Double) -> Double {
        var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if a > .pi { a -= 2 * .pi }
        if a <= -.pi { a += 2 * .pi }
        return a
    }
}
