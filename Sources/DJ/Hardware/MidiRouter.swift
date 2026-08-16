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

    /// The dead-band around the engine value inside which a physical control is
    /// considered "already there" and picks up without moving (M2).
    public static let pickupTolerance: Float = 0.02

    /// What a mapped message asks the app to do.
    public enum Intent: Sendable, Equatable {
        case setContinuous(EngineAction, Float)
        case press(EngineAction)
        /// A recognised binding whose message is a release (value 0) on a
        /// trigger/toggle: deliberately nothing, so a pad does not fire twice
        /// per tap.
        case ignoredRelease(EngineAction)
        /// A pickup control whose physical position has not reached the engine
        /// value yet. `distance` is signed — which way the user must move the
        /// control to catch (positive = physical above/right of the engine
        /// value).
        case awaitingPickup(EngineAction, distance: Float)
    }

    /// Resolve a message against a profile. `currentValue` is only consulted
    /// for relative encoders, which describe a change rather than a position,
    /// and `takeover` carries the router's per-address pickup memory.
    ///
    /// Returns nil when nothing is bound to that address — an unmapped control
    /// must do nothing at all, silently. A controller sends a lot of traffic
    /// (LED feedback echoes, touch sensors, jog ticks), and a router that
    /// guessed would make an unmapped surface unpredictable.
    public static func intent(for message: MidiMessage,
                              profile: ControllerProfile,
                              currentValue: Float = 0,
                              takeover: inout TakeoverState) -> Intent? {
        guard let binding = profile.binding(for: message.address) else { return nil }
        switch binding.transform.mode {
        case .absolute, .relative:
            let value = binding.transform.apply(message, current: currentValue)
            switch binding.takeover {
            case .jump:
                return .setContinuous(binding.action, value)
            case .pickup, .scale:
                // Takeover is about *positions*: a relative encoder describes a
                // change and has nothing to claim, so it applies as today.
                guard binding.transform.mode == .absolute else {
                    return .setContinuous(binding.action, value)
                }
                if binding.takeover == .pickup {
                    return pickupIntent(for: message, action: binding.action,
                                        incoming: value, currentValue: currentValue,
                                        takeover: &takeover)
                }
                return scaleIntent(for: message, action: binding.action,
                                   incoming: value, currentValue: currentValue,
                                   range: binding.transform.minimum...binding.transform.maximum,
                                   takeover: &takeover)
            }
        case .toggle, .trigger:
            guard binding.transform.isPress(message) else {
                return .ignoredRelease(binding.action)
            }
            return .press(binding.action)
        }
    }

    /// `.pickup`: ignore the control until its position crosses the engine
    /// value (or is already within tolerance of it); then claim it and follow.
    private static func pickupIntent(for message: MidiMessage, action: EngineAction,
                                     incoming: Float, currentValue: Float,
                                     takeover: inout TakeoverState) -> Intent? {
        let address = message.address
        if takeover.isPickedUp(address) {
            takeover.remember(address, incoming: incoming)
            return .setContinuous(action, incoming)
        }
        let engaged = abs(incoming - currentValue) <= pickupTolerance
            || crossingSinceLast(address, incoming: incoming,
                                 currentValue: currentValue, takeover: &takeover)
        takeover.remember(address, incoming: incoming)
        if engaged {
            takeover.markPickedUp(address)
            return .setContinuous(action, incoming)
        }
        // Not there yet: say which way. distance > 0 = the physical control is
        // above/right of the engine value, so the user moves it down/left.
        return .awaitingPickup(action, distance: incoming - currentValue)
    }

    /// Whether the physical value swept across the engine value since the
    /// previous message — the both-directions crossing detector. A fader that
    /// jumps over the engine value between two messages has been caught.
    private static func crossingSinceLast(_ address: MidiAddress, incoming: Float,
                                          currentValue: Float,
                                          takeover: inout TakeoverState) -> Bool {
        guard let last = takeover.lastIncoming[address] else { return false }
        return (last <= currentValue && incoming >= currentValue)
            || (last >= currentValue && incoming <= currentValue)
    }

    /// `.scale`: anchor at the first message, then move the engine value
    /// relative to its current position, proportional to the physical
    /// control's remaining travel — the full physical travel maps onto the
    /// engine's remaining range, so a fader at the top over an engine at the
    /// bottom does not jump, it scales.
    private static func scaleIntent(for message: MidiMessage, action: EngineAction,
                                    incoming: Float, currentValue: Float,
                                    range: ClosedRange<Float>,
                                    takeover: inout TakeoverState) -> Intent? {
        let address = message.address
        if let anchor = takeover.scaleAnchors[address] {
            let scaled = scaledValue(incoming, from: anchor, range: range)
            takeover.remember(address, incoming: incoming)
            takeover.markPickedUp(address)
            return .setContinuous(action, scaled)
        }
        // First message: record the reference, move nothing.
        takeover.setScaleAnchor(address, physical: incoming, engine: currentValue)
        takeover.remember(address, incoming: incoming)
        return .awaitingPickup(action, distance: incoming - currentValue)
    }

    private static func scaledValue(_ incoming: Float, from anchor: TakeoverState.ScaleAnchor,
                                    range: ClosedRange<Float>) -> Float {
        let lo = min(range.lowerBound, range.upperBound)
        let hi = max(range.lowerBound, range.upperBound)
        let p0 = anchor.physical
        let e0 = anchor.engine
        if incoming > p0 {
            let travel = max(hi - p0, .ulpOfOne)
            return e0 + (incoming - p0) / travel * (hi - e0)
        }
        if incoming < p0 {
            let travel = max(p0 - lo, .ulpOfOne)
            return e0 - (p0 - incoming) / travel * (e0 - lo)
        }
        return e0
    }
}
