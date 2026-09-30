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
