// iPhone-only: `AVRoutePickerView` on macOS needs an `AVPlayer` to route, and
// Platterhead plays through its own audio engine. Mac apps (Music included)
// leave output-route selection to the system Sound menu / Control Center, so
// the Mac app omits this button rather than invent a nonstandard substitute.
#if os(iOS)
import SwiftUI
import AVKit

struct AirPlayButton: UIViewRepresentable {
    var activeTintColor: UIColor = .systemBlue
    var inactiveTintColor: UIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark ? .white : .black
    }

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
