import SwiftUI

enum Motion {
    static let standard = Animation.easeInOut(duration: 0.22)
    static let emphasized = Animation.easeInOut(duration: 0.36)

    static func perform(_ animation: Animation = standard, _ changes: () -> Void) {
        withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : animation, changes)
    }
}

extension View {
    @ViewBuilder
    func motion<Value: Equatable>(_ animation: Animation = Motion.standard, value: Value) -> some View {
        if UIAccessibility.isReduceMotionEnabled {
            self.animation(nil, value: value)
        } else {
            self.animation(animation, value: value)
        }
    }
}
