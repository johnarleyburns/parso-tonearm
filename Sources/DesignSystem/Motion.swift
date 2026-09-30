import SwiftUI

enum Motion {
    static let standard = Animation.easeInOut(duration: 0.22)
    static let emphasized = Animation.easeInOut(duration: 0.36)

    @MainActor static func perform(_ animation: Animation = standard, _ changes: () -> Void) {
        withAnimation(animation, changes)
    }
}

extension View {
    func motion<Value: Equatable>(_ animation: Animation = Motion.standard, value: Value) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }
}

private struct MotionModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: Value

    func body(content: Content) -> some View {
        content
            .animation(reduceMotion ? nil : animation, value: value)
            .contentTransition(.opacity)
            .transaction { transaction in
                if reduceMotion {
                    transaction.animation = nil
                }
            }
    }
}
