import Foundation

/// MIDI mapping as **data, not code** (§44.4, FR-HW-1/2).
///
/// Everything in this file is pure: an incoming message is a value, a binding
/// is a value, and translation is a function between them. That is what makes
/// controller support testable without a controller — the CoreMIDI plumbing in
/// `HardwareService` does discovery and delivery and nothing else, so the part
/// that can be wrong in interesting ways is the part that runs in `swift test`.

/// Where a message came from: the identity a binding matches on.
public struct MidiAddress: Sendable, Equatable, Hashable, Codable {
    public enum MessageType: String, Sendable, Equatable, Codable {
        case cc
        case note
        case pitchBend
    }

    public let type: MessageType
    /// 1…16, as printed on every controller — not the 0…15 on the wire. The
    /// conversion happens once, at the boundary, because a user reading "ch 1"
    /// on their hardware and "ch 0" in the app will assume the app is broken.
    public let channel: Int
    /// CC number or note number. Ignored for pitch bend, which has one per
    /// channel.
    public let number: Int

    public init(type: MessageType, channel: Int, number: Int) {
        self.type = type
        self.channel = channel
        self.number = number
    }
}

/// One incoming MIDI message, normalised.
public struct MidiMessage: Sendable, Equatable {
    public let address: MidiAddress
    /// 0…127 for CC and note; 0…16383 for pitch bend.
    public let value: Int

    public init(address: MidiAddress, value: Int) {
        self.address = address
        self.value = value
    }

    /// The message's value as 0…1, whatever its wire range.
    public var normalised: Float {
        switch address.type {
        case .cc, .note: return Float(value) / 127.0
        case .pitchBend: return Float(value) / 16383.0
        }
    }
}

/// What a binding does. The illustrative subset in §44.4, made real.
public enum EngineAction: Sendable, Equatable, Hashable, Codable {
    case play(deck: DeckID)
    case cue(deck: DeckID)
    case sync(deck: DeckID)
    case channelFader(deck: DeckID)
    case eq(deck: DeckID, band: EQBand)
    case filter(deck: DeckID)
    case tempo(deck: DeckID)
    case crossfader
    case headphoneCue(deck: DeckID)
    case stemGain(deck: DeckID, stem: StemKind)
    case hotCue(deck: DeckID, index: Int)
    case loopToggle(deck: DeckID)
    case echoToggle(deck: DeckID)
    case record

    public enum DeckID: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
        case a, b
    }

    public enum EQBand: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
        case low, mid, high
    }

    /// Whether this action takes a continuous value (a knob or fader) or is
    /// triggered (a pad or button). A relative encoder bound to `play` is
    /// meaningless, and the learn UI uses this to stop a user building one.
    public var isContinuous: Bool {
        switch self {
        case .channelFader, .eq, .filter, .tempo, .crossfader, .stemGain:
            return true
        case .play, .cue, .sync, .headphoneCue, .hotCue, .loopToggle, .echoToggle, .record:
            return false
        }
    }

    /// What the learn UI offers. Excludes `hotCue`: the action exists in the
    /// vocabulary so a profile can carry it, but nothing reads stored cue
    /// points into the workspace yet, and offering a binding that will not do
    /// anything is how a user concludes their controller is broken.
    public static var bindableActions: [EngineAction] {
        var actions: [EngineAction] = [.crossfader, .record]
        for deck in DeckID.allCases {
            actions += [.play(deck: deck), .cue(deck: deck), .sync(deck: deck),
                        .channelFader(deck: deck), .filter(deck: deck), .tempo(deck: deck),
                        .headphoneCue(deck: deck), .echoToggle(deck: deck),
                        .loopToggle(deck: deck)]
            actions += EQBand.allCases.map { .eq(deck: deck, band: $0) }
            actions += StemKind.allCases.map { .stemGain(deck: deck, stem: $0) }
        }
        return actions
    }

    /// A human label for the learn UI.
    public var displayName: String {
        switch self {
        case .play(let d): return "Deck \(d.rawValue.uppercased()) · Play/Pause"
        case .cue(let d): return "Deck \(d.rawValue.uppercased()) · Cue point"
        case .sync(let d): return "Deck \(d.rawValue.uppercased()) · Sync"
        case .channelFader(let d): return "Deck \(d.rawValue.uppercased()) · Channel fader"
        case .eq(let d, let b): return "Deck \(d.rawValue.uppercased()) · EQ \(b.rawValue)"
        case .filter(let d): return "Deck \(d.rawValue.uppercased()) · Filter"
        case .tempo(let d): return "Deck \(d.rawValue.uppercased()) · Tempo"
        case .crossfader: return "Crossfader"
        case .headphoneCue(let d): return "Deck \(d.rawValue.uppercased()) · Headphone cue"
        case .stemGain(let d, let s): return "Deck \(d.rawValue.uppercased()) · Stem \(s.rawValue)"
        case .hotCue(let d, let i): return "Deck \(d.rawValue.uppercased()) · Hot cue \(i)"
        case .loopToggle(let d): return "Deck \(d.rawValue.uppercased()) · Loop"
        case .echoToggle(let d): return "Deck \(d.rawValue.uppercased()) · Echo"
        case .record: return "Record"
        }
    }

    /// The transform a control of this kind wants by default, so learning a
    /// knob does not require the user to also understand value ranges.
    public var defaultTransform: ValueTransform {
        switch self {
        case .eq, .filter, .tempo, .crossfader:
            return .bipolar
        case .channelFader, .stemGain:
            return .unipolar
        default:
            return ValueTransform(mode: .trigger)
        }
    }

    /// The soft-takeover mode this action wants by default (plan dj-midi-alpha
    /// M2). Every continuous absolute control defaults to `pickup` — the
    /// difference between a controller that works and one that slams the
    /// channel on the first touch mid-set. Relative encoders and buttons are
    /// `jump`: a relative encoder has no position to pick up, and buttons are
    /// not continuous.
    public var defaultTakeover: Takeover {
        switch self {
        case .channelFader, .crossfader, .eq, .filter, .tempo, .stemGain:
            return .pickup
        default:
            // Buttons, toggles and (later) the relative jog encoder: jump — a
            // relative encoder has no position to pick up, and a button is not
            // continuous.
            return .jump
        }
    }

    /// The persisted `midi_binding.target` string (§15).
    public var target: String {
        switch self {
        case .play(let d): return "deck\(d.rawValue.uppercased()).play"
        case .cue(let d): return "deck\(d.rawValue.uppercased()).cue"
        case .sync(let d): return "deck\(d.rawValue.uppercased()).sync"
        case .channelFader(let d): return "deck\(d.rawValue.uppercased()).fader"
        case .eq(let d, let b): return "deck\(d.rawValue.uppercased()).eq.\(b.rawValue)"
        case .filter(let d): return "deck\(d.rawValue.uppercased()).filter"
        case .tempo(let d): return "deck\(d.rawValue.uppercased()).tempo"
        case .crossfader: return "xfader"
        case .headphoneCue(let d): return "deck\(d.rawValue.uppercased()).headphoneCue"
        case .stemGain(let d, let s): return "deck\(d.rawValue.uppercased()).stem.\(s.rawValue)"
        case .hotCue(let d, let i): return "deck\(d.rawValue.uppercased()).hotcue.\(i)"
        case .loopToggle(let d): return "deck\(d.rawValue.uppercased()).loop"
        case .echoToggle(let d): return "deck\(d.rawValue.uppercased()).echo"
        case .record: return "transport.record"
        }
    }

    /// Parse a persisted target back. Unknown targets return nil rather than a
    /// default: a mapping file from a newer version must not silently bind a
    /// user's crossfader to something else.
    public static func parse(target: String) -> EngineAction? {
        if target == "xfader" { return .crossfader }
        if target == "transport.record" { return .record }
        let parts = target.split(separator: ".").map(String.init)
        guard parts.count >= 2, parts[0].hasPrefix("deck") else { return nil }
        let deckLetter = String(parts[0].dropFirst(4)).lowercased()
        guard let deck = DeckID(rawValue: deckLetter) else { return nil }
        switch parts[1] {
        case "play": return .play(deck: deck)
        case "cue": return .cue(deck: deck)
        case "sync": return .sync(deck: deck)
        case "fader": return .channelFader(deck: deck)
        case "filter": return .filter(deck: deck)
        case "tempo": return .tempo(deck: deck)
        case "headphoneCue": return .headphoneCue(deck: deck)
        case "loop": return .loopToggle(deck: deck)
        case "echo": return .echoToggle(deck: deck)
        case "eq":
            guard parts.count == 3, let band = EQBand(rawValue: parts[2]) else { return nil }
            return .eq(deck: deck, band: band)
        case "stem":
            guard parts.count == 3, let stem = StemKind(rawValue: parts[2]) else { return nil }
            return .stemGain(deck: deck, stem: stem)
        case "hotcue":
            guard parts.count == 3, let index = Int(parts[2]) else { return nil }
            return .hotCue(deck: deck, index: index)
        default: return nil
        }
    }
}

/// How a message's value becomes an engine value (§44.4).
public struct ValueTransform: Sendable, Equatable, Codable {
    public enum Mode: String, Sendable, Equatable, Codable {
        /// The control's position is the value (a fader, a knob).
        case absolute
        /// The control sends increments (an endless encoder). 64 is the usual
        /// centre: 65 = +1, 63 = −1.
        case relative
        /// A button that flips state on press.
        case toggle
        /// A button that fires on press and does nothing on release.
        case trigger
    }

    public let mode: Mode
    /// The engine-side range this control spans.
    public let minimum: Float
    public let maximum: Float
    public let invert: Bool

    public init(mode: Mode, minimum: Float = 0, maximum: Float = 1, invert: Bool = false) {
        self.mode = mode
        self.minimum = minimum
        self.maximum = maximum
        self.invert = invert
    }

    /// An EQ knob or a filter: −1…1 with the centre at 0.
    public static let bipolar = ValueTransform(mode: .absolute, minimum: -1, maximum: 1)
    /// A channel fader: 0…1.
    public static let unipolar = ValueTransform(mode: .absolute, minimum: 0, maximum: 1)

    /// Map a message onto the engine value, given the control's current value
    /// (needed by `relative`, which describes a change rather than a position).
    public func apply(_ message: MidiMessage, current: Float) -> Float {
        switch mode {
        case .absolute:
            let unit = invert ? 1 - message.normalised : message.normalised
            return minimum + unit * (maximum - minimum)
        case .relative:
            // Two's-complement-around-64, the common "relative 2" encoding.
            let delta = Float(message.value - 64) / 127.0 * (maximum - minimum)
            return clamp(current + (invert ? -delta : delta))
        case .toggle, .trigger:
            // A press is any non-zero value; the engine side decides what a
            // press means (`isPress`).
            return message.value > 0 ? maximum : minimum
        }
    }

    /// Whether this message counts as a press for a toggle/trigger binding.
    /// Note-offs and the release half of a button send 0 and must not fire a
    /// second time — a pad that triggers twice per tap is unusable.
    public func isPress(_ message: MidiMessage) -> Bool {
        message.value > 0
    }

    private func clamp(_ value: Float) -> Float {
        min(max(value, min(minimum, maximum)), max(minimum, maximum))
    }
}

/// One control on one controller, bound to one action (§44.4).
public struct MidiBinding: Sendable, Equatable, Codable {
    public let address: MidiAddress
    public let action: EngineAction
    public let transform: ValueTransform
    /// How the control's position claims the engine value when they disagree
    /// (plan dj-midi-alpha M2). Defaults to the action's choice — a fader
    /// picks up, a button jumps — and a profile can carry a per-binding
    /// override.
    public let takeover: Takeover

    public init(address: MidiAddress, action: EngineAction, transform: ValueTransform,
                takeover: Takeover? = nil) {
        self.address = address
        self.action = action
        self.transform = transform
        self.takeover = takeover ?? action.defaultTakeover
    }
}

/// How a bound continuous control claims an engine value that differs from the
/// physical control's position (plan dj-midi-alpha M2).
///
/// A physical fader at 100 % over an app at 20 % is not an edge case: it is
/// what happens the moment a user loads a controller mid-set or re-binds a
/// control. Without soft takeover the first touch slams the channel in front
/// of people.
public enum Takeover: String, Sendable, Equatable, Codable {
    /// The control's position is the value immediately — today's behaviour.
    /// Correct for a control the user is already holding, or a relative
    /// encoder, which has no position.
    case jump
    /// Ignore the control until its physical position crosses the engine
    /// value; until then the routed intent is `.awaitingPickup`, and the UI
    /// shows which way to move it.
    case pickup
    /// Move the engine value relative to its current position, proportional to
    /// the physical control's remaining travel from its pickup point — a
    /// scaled pickup rather than a jump.
    case scale
}

/// The router's takeover memory (plan dj-midi-alpha M2).
///
/// Deliberately **not** inside `MidiRouter`: the router stays a pure function
/// so it is testable without a controller, and the caller owns the state —
/// one per attached workspace — including the resets (re-attach, or a finger
/// driving the action on the touchscreen).
public struct TakeoverState: Sendable, Equatable {
    /// A `scale` control's pickup anchor (physical + engine value at the first
    /// message after a reset).
    public struct ScaleAnchor: Sendable, Equatable {
        public var physical: Float
        public var engine: Float

        public init(physical: Float, engine: Float) {
            self.physical = physical
            self.engine = engine
        }
    }

    public private(set) var pickedUp: [MidiAddress: Bool] = [:]
    /// The last engine-scale value seen per address — the crossing detector.
    public private(set) var lastIncoming: [MidiAddress: Float] = [:]
    public private(set) var scaleAnchors: [MidiAddress: ScaleAnchor] = [:]

    public init() {}

    public func isPickedUp(_ address: MidiAddress) -> Bool { pickedUp[address] ?? false }

    public mutating func remember(_ address: MidiAddress, incoming: Float) {
        lastIncoming[address] = incoming
    }

    public mutating func markPickedUp(_ address: MidiAddress) {
        pickedUp[address] = true
        scaleAnchors[address] = nil
    }

    public mutating func setScaleAnchor(_ address: MidiAddress, physical: Float, engine: Float) {
        scaleAnchors[address] = ScaleAnchor(physical: physical, engine: engine)
    }

    /// Forget one address — a finger drove the action on the touchscreen, or
    /// the binding was re-attached, so the physical control must re-pick-up.
    public mutating func resetPickup(for address: MidiAddress) {
        pickedUp[address] = nil
        lastIncoming[address] = nil
        scaleAnchors[address] = nil
    }

    public mutating func reset() {
        pickedUp = [:]
        lastIncoming = [:]
        scaleAnchors = [:]
    }
}

/// A named set of bindings — what a user exports, imports and shares (FR-HW-2).
public struct ControllerProfile: Sendable, Equatable, Codable {
    public var name: String
    public var vendor: String?
    /// The CoreMIDI endpoint this profile was learned from, so plugging the
    /// same controller in again selects it without asking.
    public var endpointName: String?
    public var bindings: [MidiBinding]

    public init(name: String, vendor: String? = nil, endpointName: String? = nil,
                bindings: [MidiBinding] = []) {
        self.name = name
        self.vendor = vendor
        self.endpointName = endpointName
        self.bindings = bindings
    }

    /// The binding for an incoming message, if any. First match wins, and a
    /// later binding on the same address replaces an earlier one at learn time,
    /// so a user re-learning a control does not end up with two.
    public func binding(for address: MidiAddress) -> MidiBinding? {
        bindings.first { $0.address == address }
    }

    /// Bind `action` to `address`, replacing anything already on that address
    /// **and** any other binding of the same action. Both halves matter: a
    /// control should do one thing, and an action should have one control —
    /// otherwise a half-relearned map moves the crossfader from two knobs.
    public mutating func learn(_ action: EngineAction, at address: MidiAddress,
                               transform: ValueTransform, takeover: Takeover? = nil) {
        bindings.removeAll { $0.address == address || $0.action == action }
        bindings.append(MidiBinding(address: address, action: action, transform: transform,
                                    takeover: takeover ?? action.defaultTakeover))
    }
}
