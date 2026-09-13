import SwiftUI

/// A "draw your own" canvas: `points` are evenly-spaced values in [0,1]; a drag
/// writes the slot nearest the finger, so the user sketches the shape the
/// `custom` arc interpolates (§28A.5).
public struct DrawArcView: View {
    @Binding var points: [Double]

    public init(points: Binding<[Double]>) {
        _points = points
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let count = max(points.count, 2)
            ZStack(alignment: .topLeading) {
                Color.clear
                gridLines(width: w, height: h)
                polyline(width: w, height: h, count: count)
                    .stroke(Color.indigo, style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            updatePoints(at: value.location, width: w, height: h, count: count)
                        })
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary, lineWidth: 1))
        .accessibilityLabel("Draw your own energy arc")
    }

    private func updatePoints(at location: CGPoint, width: CGFloat, height: CGFloat,
                              count: Int) {
        let t = min(1, max(0, location.x / width))
        let value = min(1, max(0, 1 - location.y / height))
        let index = Int((Double(t) * Double(count - 1)).rounded())
        var updated = points
        if updated.count < count {
            updated = [Double](repeating: 0.5, count: count)
        }
        updated[index] = value
        points = updated
    }

    private func gridLines(width: CGFloat, height: CGFloat) -> some View {
        Path { path in
            for fraction in [0.25, 0.5, 0.75] {
                let y = height * fraction
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: width, y: y))
            }
        }
        .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
    }

    private func polyline(width: CGFloat, height: CGFloat, count: Int) -> Path {
        var path = Path()
        let values = points.count >= count ? points : [Double](repeating: 0.5, count: count)
        for index in values.indices {
            let x = CGFloat(index) / CGFloat(count - 1) * width
            let y = (1 - CGFloat(values[index])) * height
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }
}
