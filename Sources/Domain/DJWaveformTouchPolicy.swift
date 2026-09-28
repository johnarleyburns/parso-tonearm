import CoreGraphics
import Foundation

public enum DJWaveformTouchMode: Sendable, Equatable { case nudge, scratch }
public enum DJWaveformTouchAction: Sendable, Equatable {
    case seek(CGFloat), nudge(CGFloat), scratch(CGFloat), frameSearch(CGFloat), flick(CGFloat, CGFloat), focus, none
}

public enum DJWaveformTouchPolicy {
    public static func action(phase: Double, isPlaying: Bool, touchMode: DJWaveformTouchMode,
                              heldFor: Double, translation: CGFloat, predictedTranslation: CGFloat = 0,
                              width: CGFloat) -> DJWaveformTouchAction {
        guard phase.isFinite, heldFor.isFinite, translation.isFinite, predictedTranslation.isFinite,
              width.isFinite, width > 0 else { return .none }
        if abs(translation) < 0.5 && heldFor < 0.1 { return .focus }
        if heldFor >= 0.35 {
            return isPlaying ? .scratch(translation) : .frameSearch(translation)
        }
        guard isPlaying else { return .seek(translation) }
        switch touchMode { case .nudge: return .nudge(translation); case .scratch: return .scratch(translation) }
    }
}
