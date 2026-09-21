// Native Mac app (docs/plans/native-mac-app-plan.md §2a): `AVRoutePickerView`
// is UIKit-only with no AppKit equivalent — macOS has no in-app AirPlay
// route-picker API at all. Real Mac apps in this position (Music.app
// included) don't show an in-app AirPlay button; output-route selection goes
// through the system Sound menu-bar item instead. Omitted entirely on Mac
// rather than inventing a nonstandard substitute — this is a removal, not a
// porting task.
#if !os(macOS)
import SwiftUI
import AVKit

struct AirPlayButton: UIViewRepresentable {
    var activeTintColor: UIColor = .systemBlue
    var inactiveTintColor: UIColor = .white

    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.activeTintColor = activeTintColor
        v.tintColor = inactiveTintColor
        v.prioritizesVideoDevices = false
        v.setContentHuggingPriority(.required, for: .horizontal)
        v.setContentHuggingPriority(.required, for: .vertical)
        return v
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.activeTintColor = activeTintColor
        uiView.tintColor = inactiveTintColor
    }
}
#endif
