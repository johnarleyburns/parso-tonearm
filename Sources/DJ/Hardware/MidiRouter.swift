import Foundation

/// Turns a mapped MIDI message into an engine intent (§44.4).
///
/// The router is deliberately *not* the engine: it produces an `Intent` value,
/// and the workspace applies it. That keeps the whole translation path — the
/// part with the arithmetic and the edge cases — testable without an engine,
/// an audio device, or a controller, and it means a MIDI message takes exactly
/// the same road into the engine as a finger does (§44.3: "MIDI I/O never runs
/// on the audio thread; it feeds the same command channel everything else
/// uses").
public enum MidiRouter {

    /// What a mapped message asks the app to do.
    public enum Intent: Sendable, Equatable {
        case setContinuous(EngineAction, Float)
        case press(EngineAction)
        /// A recognised binding whose message is a release (value 0) on a
        /// trigger/toggle: deliberately nothing, so a pad does not fire twice
        /// per tap.
        case ignoredRelease(EngineAction)
    }

    /// Resolve a message against a profile. `currentValue` is only consulted
    /// for relative encoders, which describe a change rather than a position.
    ///
    /// Returns nil when nothing is bound to that address — an unmapped control
    /// must do nothing at all, silently. A controller sends a lot of traffic
    /// (LED feedback echoes, touch sensors, jog ticks), and a router that
    /// guessed would make an unmapped surface unpredictable.
    public static func intent(for message: MidiMessage,
                              profile: ControllerProfile,
                              currentValue: Float = 0) -> Intent? {
        guard let binding = profile.binding(for: message.address) else { return nil }
        switch binding.transform.mode {
        case .absolute, .relative:
            let value = binding.transform.apply(message, current: currentValue)
            return .setContinuous(binding.action, value)
        case .toggle, .trigger:
            guard binding.transform.isPress(message) else {
                return .ignoredRelease(binding.action)
            }
            return .press(binding.action)
        }
    }
}
