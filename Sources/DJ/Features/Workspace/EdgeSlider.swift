import SwiftUI

/// The §42.7a **screen-edge filter slider** (mockup `iphone/05d`'s `edge`;
/// §42.7b idiom 2): a 24 pt vertical slider pinned to the true screen edge.
/// It costs zero layout width, sits at the innermost point of each thumb arc,
/// and stays reachable with a bank drawer open — filter and EQ get worked
/// together, and the edge is the one place the drawer never reaches.
///
/// Rule 2 is structural, not visual. The momentary drawer is exactly one deck
/// column wide (`WorkspaceModel.DrawerGeometry.width`, 228 pt) and begins at
/// the §42.7a 30 pt margin inside the 59 pt dead band, so its frame on a
/// 734 pt usable width — screen x ≈ 89…317 for deck A — never intersects the
/// outer 24 pt this slider owns. The slider renders *over* the dead-band
/// padding at the true screen edge, above the drawer in z-order, so no modal
/// idiom can occlude it (§42.7b).
struct EdgeSlider: View {
    let value: Float
    let onChanged: (Float) -> Void

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let t = CGFloat(min(1, max(0, (value + 1) / 2)))
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(Color.white.opacity(0.10))
                Capsule()
                    .fill(Color.accentColor.opacity(0.9))
                    .frame(width: 3)
                    .frame(height: max(8, height * t))
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 20, height: 4)
                    .offset(y: -(max(8, height * t)) + 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { gesture in
                    let fill = min(1, max(0, 1 - gesture.location.y / height))
                    onChanged(Float(fill) * 2 - 1)
                }
            )
        }
    }
}
