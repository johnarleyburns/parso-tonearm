import Combine
import CoreGraphics
import Foundation
import TonearmCore

extension WorkspaceModel {
    // MARK: - MIDI (§44.4, FR-HW-1, plan 6.5)

    /// The controller profile in force, and the task feeding it (§44.3).
    ///
    /// Attaching is explicit rather than automatic: the workspace should not
    /// open a MIDI client just because it appeared, and a user with no
    /// controller pays nothing for the feature existing.
    public func attachMidi(_ hardware: HardwareService, profile: ControllerProfile) {
        midiProfile = profile
        midiHardware = hardware
        midiTask?.cancel()
        midiAssemblerTask?.cancel()
        midiAssembler = MidiValueAssembler()
        midiTask = Task { [weak self] in
            for await message in hardware.messages {
                guard let self, let profile = self.midiProfile else { continue }
                let messages = self.midiAssembler.submit(message, profile: profile,
                                                         at: DispatchTime.now().uptimeNanoseconds)
                for message in messages { self.routeMidiMessage(message, profile: profile) }
            }
        }
        midiAssemblerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: MidiValueAssembler.defaultWindowNanoseconds)
                guard !Task.isCancelled else { break }
                self?.flushMidiAssembler()
            }
        }
    }

    private func flushMidiAssembler() {
        guard let profile = midiProfile else { return }
        let messages = midiAssembler.flush(at: DispatchTime.now().uptimeNanoseconds)
        for message in messages { routeMidiMessage(message, profile: profile) }
    }

    private func routeMidiMessage(_ message: MidiMessage, profile: ControllerProfile) {
        // A controller must not drive a Pro-gated surface it cannot otherwise
        // reach — the gate is checked at the intent boundary (T.3), which is
        // exactly here.
        guard isDecksEnabled else { return }
        // Look the binding up once: an unbound address must return before any
        // value is read, or an unmapped relative encoder reads some other
        // control's value as its base (plan M1's latent-bug fix).
        guard let binding = profile.binding(for: message.address) else { return }
        guard let intent = MidiRouter.intent(
            for: message, profile: profile,
            currentValue: currentValue(of: binding.action),
            takeover: &midiTakeover) else { return }
        apply(intent)
    }

    public func detachMidi() {
        midiTask?.cancel()
        midiTask = nil
        midiAssemblerTask?.cancel()
        midiAssemblerTask = nil
        midiProfile = nil
        midiHardware = nil
        midiAssembler = MidiValueAssembler()
        midiTakeover.reset()
        midiPendingPickup = [:]
    }

    /// Apply a routed MIDI intent.
    ///
    /// Every case below goes through the **same public method a finger goes
    /// through** — `setEQKnobs`, `toggleCue`, `setCrossfader` — so a mapped
    /// controller inherits the gesture journal, the transition recognisers and
    /// the Pro gate for free, and cannot become a second path into the engine
    /// that behaves subtly differently (§44.3).
    public func apply(_ intent: MidiRouter.Intent) {
        switch intent {
        case .ignoredRelease(let action):
            // The one deliberate exception to "a release does nothing": the
            // platter's touch sensor (jogTouch) releases the held jog — the
            // exact opposite of a pad, where a release must not fire again.
            if case .jogTouch(let deck) = action {
                midiJogTouchRelease(engineDeck(deck))
            }
            publishMidiFeedback(for: action, release: true)
            return
        case .awaitingPickup(let action, let distance):
            // The physical control has not caught the engine value yet: surface
            // the "which way" indicator, move nothing (M2).
            midiPendingPickup[action] = distance
        case .setContinuous(let action, let value):
            midiPendingPickup[action] = nil
            isApplyingMidi = true
            defer { isApplyingMidi = false }
            applyContinuous(action, value)
        case .press(let action):
            midiPendingPickup[action] = nil
            isApplyingMidi = true
            defer { isApplyingMidi = false }
            applyPress(action)
            publishMidiFeedback(for: action)
        }
    }

    /// Reflect only button state back to the controller. Continuous controls
    /// are intentionally excluded: LED feedback for faders/encoders is both
    /// noisy and unsupported by the alpha contract. The state is read after
    /// the same public action method that a finger uses, so there is no second
    /// source of truth.
    private func publishMidiFeedback(for action: EngineAction, release: Bool = false) {
        guard let profile = midiProfile,
              let binding = profile.bindings.first(where: { $0.action == action }),
              binding.transform.mode == .toggle || binding.transform.mode == .trigger,
              let hardware = midiHardware else { return }
        if release, binding.transform.mode != .trigger { return }
        let value: Int
        if binding.transform.mode == .trigger {
            value = release ? 0 : 127
        } else {
            switch action {
            case .play(let deck):
                value = (deck == .a ? telemetry.deckA.playing : telemetry.deckB.playing) ? 127 : 0
            case .cue(let deck), .headphoneCue(let deck):
                value = isCued(engineDeck(deck)) ? 127 : 0
            case .sync(let deck):
                value = isSynced(engineDeck(deck)) ? 127 : 0
            case .echoToggle(let deck):
                value = echoEnabled(engineDeck(deck)) ? 127 : 0
            case .record:
                value = isRecording ? 127 : 0
            case .loopToggle:
                // Loop state is owned by the engine; the action is still useful as
                // a trigger, so acknowledge the press without inventing state.
                value = 127
            default:
                value = 0
            }
        }
        hardware.sendFeedback(MidiFeedbackEvent(address: binding.address, value: value))
    }

    /// The pending-pickup list for the catch indicator: one row per awaiting
    /// action, naming the control and which way to move it in surface terms
    /// (horizontal for the crossfader, vertical for the faders/knobs).
    public var midiCatchItems: [(label: String, target: String)] {
        midiPendingPickup
            .map { action, distance in
                let direction: String
                if case .crossfader = action {
                    direction = distance > 0 ? "move left" : "move right"
                } else {
                    direction = distance > 0 ? "move down" : "move up"
                }
                return (label: "\(action.displayName) — \(direction) to catch",
                        target: action.target)
            }
            .sorted { $0.target < $1.target }
    }

    /// A finger drove `action` on the touchscreen, so the physical control's
    /// claim on it is stale and must re-pick-up (M2). Guarded by
    /// `isApplyingMidi` so a MIDI-driven setter never resets its own claim.
    func resetMidiPickup(for action: EngineAction) {
        guard !isApplyingMidi, let profile = midiProfile else { return }
        for binding in profile.bindings where binding.action == action {
            midiTakeover.resetPickup(for: binding.address)
        }
        midiPendingPickup[action] = nil
    }

    /// The current engine-side value of a continuous action — what a relative
    /// encoder's increment is applied to.
    public func currentValue(of action: EngineAction) -> Float {
        switch action {
        case .channelFader(let deck): return deck == .a ? channelA : channelB
        case .crossfader: return crossfader
        case .filter(let deck): return deck == .a ? filterA : filterB
        case .eq(let deck, let band):
            switch (deck, band) {
            case (.a, .low): return eqALow
            case (.a, .mid): return eqAMid
            case (.a, .high): return eqAHigh
            case (.b, .low): return eqBLow
            case (.b, .mid): return eqBMid
            case (.b, .high): return eqBHigh
            }
        default: return 0
        }
    }

    private func applyContinuous(_ action: EngineAction, _ value: Float) {
        switch action {
        case .channelFader(let deck):
            setChannelFader(engineDeck(deck), gain: value)
        case .crossfader:
            setCrossfader(value, curve: crossfaderCurve)
        case .filter(let deck):
            setFilter(engineDeck(deck), knob: value)
        case .eq(let deck, let band):
            let d = engineDeck(deck)
            let low = deck == .a ? eqALow : eqBLow
            let mid = deck == .a ? eqAMid : eqBMid
            let high = deck == .a ? eqAHigh : eqBHigh
            switch band {
            case .low: setEQKnobs(d, low: value, mid: mid, high: high)
            case .mid: setEQKnobs(d, low: low, mid: value, high: high)
            case .high: setEQKnobs(d, low: low, mid: mid, high: value)
            }
        case .tempo(let deck):
            // The tempo fader's engine range is ±8% (ClubGeometry), and the
            // transform hands over a bipolar −1…1 — map, do not pass through.
            setTempo(engineDeck(deck),
                     fraction: Double(value) * ClubGeometry.tempoFaderRange.upperBound)
        case .stemGain(let deck, let stem):
            setStemGain(engineDeck(deck), stem: stem, gain: value)
        case .jog(let deck):
            // A relative encoder's ticks are the platter's rotation. Touched in
            // vinyl mode they scrub; otherwise they bend tempo like the ring
            // (plan dj-midi-alpha M3).
            let d = engineDeck(deck)
            if midiJogHeld[d] == true, jogMode(d) == .vinyl {
                midiJogRadians[d] = (midiJogRadians[d] ?? 0)
                    + Double(value) * Self.midiJogSweepToRadians
                jogTransport(for: d).route(.scrub(radians: midiJogRadians[d] ?? 0))
            } else {
                midiJogNudge(d, delta: Double(value))
            }
        default:
            // A continuous message on a trigger action does nothing rather
            // than firing on every increment — a knob bound to PLAY would
            // otherwise machine-gun the transport.
            return
        }
    }

    private func applyPress(_ action: EngineAction) {
        switch action {
        case .play(let deck):
            let d = engineDeck(deck)
            (deck == .a ? telemetry.deckA.playing : telemetry.deckB.playing) ? pause(d) : play(d)
        case .cue(let deck):
            cue(engineDeck(deck))
        case .sync(let deck):
            let d = engineDeck(deck)
            sync(d, to: d == .a ? .b : .a, barSync: true)
        case .headphoneCue(let deck):
            toggleCue(engineDeck(deck))
        case .echoToggle(let deck):
            setEchoEnabled(engineDeck(deck), enabled: !echoEnabled(engineDeck(deck)))
        case .record:
            toggleRecording()
        case .loopToggle(let deck):
            setLoop(engineDeck(deck), beats: 4)
        case .jogTouch(let deck):
            // The platter's touch sensor: press = hold (touch = hold §40.7.3),
            // release = the `ignoredRelease` case handled in `apply(_:)`.
            midiJogTouchHold(engineDeck(deck))
        case .hotCue:
            // **Deliberately inert, and not silently so.** Hot cues have an
            // engine path (`triggerHotCue`) and a §15 table, but nothing yet
            // reads stored cue points into the workspace — the eight pads from
            // 5.4 are the surface, not the storage. Firing this with a made-up
            // sample would jump the track to zero mid-set, so the binding
            // exists in the vocabulary (a profile can carry it) and does
            // nothing until hot-cue storage lands. `bindableActions` leaves it
            // out of the learn UI so nobody maps a dead pad.
            return
        default:
            return
        }
    }

    private func engineDeck(_ deck: EngineAction.DeckID) -> Deck {
        deck == .a ? .a : .b
    }

    // MARK: - MIDI jog (plan dj-midi-alpha M3)

    /// A full relative-encoder sweep — 127 ticks, the jog transform's ±0.16
    /// range — maps to one full platter revolution, i.e. one beat of scrub at
    /// the deck's tempo. One tick ≈ 1/127 revolution.
    static let midiJogSweepToRadians: Double = 2 * .pi / 0.32
    /// How long a jog encoder may go quiet before the MIDI jog releases the
    /// bend — controllers do not send "I stopped".
    private static let midiJogIdleNanoseconds: UInt64 = 150_000_000

    /// Accumulate a relative-encoder delta into the deck's jog bend (clamped
    /// to the ring's ±16 % ceiling) and push it through the shared transport.
    /// An idle timer releases the bend; a controller never says "I stopped".
    private func midiJogNudge(_ deck: Deck, delta: Double) {
        midiJogReleaseTasks[deck]?.cancel()
        let next = min(max((midiJogBend[deck] ?? 0) + delta,
                           -JogGestureModel.maxBendRate), JogGestureModel.maxBendRate)
        midiJogBend[deck] = next
        jogTransport(for: deck).route(.nudge(rate: next))
        midiJogReleaseTasks[deck] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.midiJogIdleNanoseconds)
            guard !Task.isCancelled else { return }
            self?.midiJogRelease(deck)
        }
    }

    /// The encoder went quiet. If the platter is still held, only the bend is
    /// restored — the hold (and the deck paused behind it) survives; otherwise
    /// the transport fully releases.
    private func midiJogRelease(_ deck: Deck) {
        midiJogBend[deck] = 0
        guard midiJogHeld[deck] != true else {
            jogTransport(for: deck).restoreBend()
            return
        }
        midiJogReleaseTasks[deck] = nil
        jogTransport(for: deck).route(.release)
    }

    private func midiJogTouchHold(_ deck: Deck) {
        midiJogHeld[deck] = true
        midiJogRadians[deck] = 0
        jogTransport(for: deck).route(.hold)
    }

    private func midiJogTouchRelease(_ deck: Deck) {
        midiJogHeld[deck] = false
        midiJogRadians[deck] = nil
        midiJogReleaseTasks[deck]?.cancel()
        midiJogReleaseTasks[deck] = nil
        midiJogBend[deck] = 0
        jogTransport(for: deck).route(.release)
    }

}
