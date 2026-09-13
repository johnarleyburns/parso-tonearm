import SwiftUI

/// A single arc's closed-form curve as a SwiftUI `Shape` — the picker previews
/// and the result plot both draw through it (one geometry, §49.3).
public struct ArcShape: Shape {
    public let arc: EnergyArc
    public var sampleCount = 64

    public init(arc: EnergyArc, sampleCount: Int = 64) {
        self.arc = arc
        self.sampleCount = sampleCount
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        for index in 0...sampleCount {
            let t = Double(index) / Double(sampleCount)
            let x = rect.minX + CGFloat(t) * rect.width
            let y = rect.minY + (1 - CGFloat(arc.value(at: t))) * rect.height
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }
}
