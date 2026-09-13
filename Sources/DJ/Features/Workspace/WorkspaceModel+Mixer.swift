import Combine
import CoreGraphics
import Foundation
import TonearmCore

extension WorkspaceModel {
    // MARK: - Sync (§32)

    public func sync(_ deck: Deck, to master: Deck,
                     barSync: Bool = false) {
        engine.sync(deck, to: master, barSync: barSync)
    }

    public func unsync(_ deck: Deck) {
        engine.unsync(deck)
    }

    public func isSynced(_ deck: Deck) -> Bool {
        engine.isSynced(deck)
    }

    // MARK: - Mixer (§35)

    public func setEQKnobs(_ deck: Deck, low: Float, mid: Float, high: Float) {
        detectBassSwap(deck: deck, newLow: low)
        engine.setEQKnobs(deck, low: low, mid: mid, high: high)
        switch deck {
        case .a:
            eqALow = low; eqAMid = mid; eqAHigh = high
        case .b:
            eqBLow = low; eqBMid = mid; eqBHigh = high
        }
        let id = midiDeckID(deck)
        resetMidiPickup(for: .eq(deck: id, band: .low))
        resetMidiPickup(for: .eq(deck: id, band: .mid))
        resetMidiPickup(for: .eq(deck: id, band: .high))
    }

    public func setFilter(_ deck: Deck, knob: Float) {
        detectFilter(deck: deck, newKnob: knob)
        engine.setFilter(deck, knob: knob)
        switch deck {
        case .a: filterA = knob
        case .b: filterB = knob
        }
        resetMidiPickup(for: .filter(deck: midiDeckID(deck)))
    }

    public func setChannelFader(_ deck: Deck, gain: Float) {
        detectChannelFader(deck: deck, newGain: gain)
        engine.setChannelFader(deck, gain: gain)
        switch deck {
        case .a: channelA = gain
        case .b: channelB = gain
        }
        resetMidiPickup(for: .channelFader(deck: midiDeckID(deck)))
    }

    // MARK: - Cue monitoring (§44.2a, FR-HW-3, plan 6.4)

    /// Which decks are routed to the headphone cue, and in which mode.
    ///
    /// Two separate pieces of state on purpose: a DJ leaves cue *armed* on the
    /// incoming deck for a whole transition, and switching modes must not
    /// silently disarm it.
    ///
    /// (`cueMode`, `cuedDecks` and `outputChannelCount` are declared as stored
    /// properties on `WorkspaceModel` itself — see WorkspaceModel.swift —
    /// because Swift extensions cannot hold stored instance properties.)

    public func isCued(_ deck: Deck) -> Bool { cuedDecks.contains(deck) }

    /// Toggle a deck's pre-listen. Engaging cue on a deck while the mode is
    /// `.off` also selects a usable mode — otherwise the button does nothing
    /// visible and the user concludes cue is broken.
    public func toggleCue(_ deck: Deck) {
        let enabled = !cuedDecks.contains(deck)
        if enabled {
            cuedDecks.insert(deck)
            if cueMode == .off { setCueMode(defaultCueMode) }
        } else {
            cuedDecks.remove(deck)
        }
        engine.setHeadphoneCue(deck, enabled: enabled)
    }

    /// The mode chosen when a user cues a deck without having picked one:
    /// split output where the route can carry it, cue-in-place otherwise.
    private var defaultCueMode: CueMode {
        CueMode.splitOutput.isAvailable(outputChannels: outputChannelCount)
            ? .splitOutput : .cueInPlace
    }

    /// Select a cue mode. A mode the current route cannot deliver is **not**
    /// selected — the caller gets `false` and the reason belongs on screen
    /// (§44.2a: the substitution is the failure).
    @discardableResult
    public func setCueMode(_ mode: CueMode) -> Bool {
        guard mode.isAvailable(outputChannels: outputChannelCount) else { return false }
        cueMode = mode
        engine.setCueMode(mode)
        return true
    }

    /// Observe the route's channel count (§44.2, FR-HW-4). A route that loses
    /// channels demotes an unavailable mode rather than leaving it selected and
    /// inert.
    public func updateOutputChannelCount(_ channels: Int) {
        outputChannelCount = max(1, channels)
        if !cueMode.isAvailable(outputChannels: outputChannelCount) {
            setCueMode(defaultCueMode)
        }
    }

    public func setCrossfader(_ position: Float, curve: CrossfaderCurve) {
        detectCrossfader(position)
        engine.setCrossfader(position, curve: curve)
        crossfader = position
        crossfaderCurve = curve
        resetMidiPickup(for: .crossfader)
    }

    // MARK: - Beat FX — the §35A post-fader echo (FR-TRANS-4, plan 5.5)

    /// Whether a deck's echo is currently on.
    public func echoEnabled(_ deck: Deck) -> Bool {
        deck == .a ? echoEnabledA : echoEnabledB
    }

    /// A deck's echo beat length (1/4 … 4, §35A.2).
    public func echoBeats(_ deck: Deck) -> Double {
        deck == .a ? echoBeatsA : echoBeatsB
    }

    /// A deck's echo wet depth (0…1, §35A.2).
    public func echoDepth(_ deck: Deck) -> Float {
        deck == .a ? echoDepthA : echoDepthB
    }

    /// A deck's echo feedback — tail length, 0…0.85 (clamped below unity).
    public func echoFeedback(_ deck: Deck) -> Float {
        deck == .a ? echoFeedbackA : echoFeedbackB
    }

    /// Turn a deck's echo on/off. Disabling stops new input to the line but
    /// the tail keeps ringing until it decays, then bypasses (§35A.2) — this
    /// is what makes Echo Out an exit rather than a cut (FR-TRANS-4).
    public func setEchoEnabled(_ deck: Deck, enabled: Bool) {
        engine.setEchoEnabled(deck, enabled: enabled)
        switch deck {
        case .a: echoEnabledA = enabled
        case .b: echoEnabledB = enabled
        }
    }

    /// Set a deck's echo beat length, clamped into the §35A.2 range (1/4 … 4).
    /// The delay is derived from the master clock, so a tempo change moves the
    /// echo with it.
    public func setEchoBeats(_ deck: Deck, beats: Double) {
        let clamped = min(BeatEcho.maxBeats, max(BeatEcho.minBeats, beats))
        engine.setEchoBeats(deck, beats: clamped)
        switch deck {
        case .a: echoBeatsA = clamped
        case .b: echoBeatsB = clamped
        }
    }

    /// Set a deck's echo wet depth, clamped into 0…1.
    public func setEchoDepth(_ deck: Deck, depth: Float) {
        let clamped = min(BeatEcho.maxDepth, max(0, depth))
        engine.setEchoDepth(deck, depth: clamped)
        switch deck {
        case .a: echoDepthA = clamped
        case .b: echoDepthB = clamped
        }
    }

    /// Set a deck's echo feedback, clamped into 0…0.85 — always below unity so
    /// the tail always decays (§35A.2).
    public func setEchoFeedback(_ deck: Deck, feedback: Float) {
        let clamped = min(BeatEcho.maxFeedback, max(BeatEcho.minFeedback, feedback))
        engine.setEchoFeedback(deck, feedback: clamped)
        switch deck {
        case .a: echoFeedbackA = clamped
        case .b: echoFeedbackB = clamped
        }
    }

    // MARK: - §41.9b tempo fader (rule 4)

    /// A deck's tempo-fader position: the signed fraction off unity in
    /// `ClubGeometry.tempoFaderRange`.
    public func tempo(_ deck: Deck) -> Double {
        deck == .a ? tempoA : tempoB
    }

    /// Move a deck's tempo fader (§41.9b rule 4). The fader sets the deck's
    /// rate directly (`rate = 1 + fraction`), clamped to the ±8% range. A
    /// synced deck's continuous rate tracking may override it, exactly as a
    /// pitch fader on club gear overrides sync while it is moved.
    public func setTempo(_ deck: Deck, fraction: Double) {
        let clamped = min(ClubGeometry.tempoFaderRange.upperBound,
                          max(ClubGeometry.tempoFaderRange.lowerBound, fraction))
        switch deck {
        case .a: tempoA = clamped
        case .b: tempoB = clamped
        }
        engine.setRate(deck, rate: Float(1 + clamped))
        resetMidiPickup(for: .tempo(deck: midiDeckID(deck)))
    }

    // MARK: - Master clock bar:beat readout (§53.11)

    /// The master clock's bar and beat (1-indexed) at an absolute master
    /// sample position: `bar = floor(samples / samplesPerBar) + 1`, `beat`
    /// the offset within the bar. `nil` until a master clock exists (no deck
    /// loaded / no tempo). Pure so the regression driver's bar scheduling
    /// (`waitForBar`) is pinned to the same math the UI renders (§53.11's
    /// `dj.master.bar`).
    public static func masterBarBeat(masterSample: Int64,
                                     bpm: Double,
                                     sampleRate: Double) -> (bar: Int, beat: Int)? {
        guard bpm > 0, sampleRate > 0 else { return nil }
        let samplesPerBeat = sampleRate * 60 / bpm
        let samplesPerBar = 4 * samplesPerBeat
        let bar = Int(Double(masterSample) / samplesPerBar) + 1
        let inBar = Double(masterSample).truncatingRemainder(dividingBy: samplesPerBar)
        let beat = min(4, Int(inBar / samplesPerBeat) + 1)
        return (bar, beat)
    }

    /// The master clock's current bar:beat, rendered by `dj.master.bar`.
    public var masterBarBeat: (bar: Int, beat: Int)? {
        Self.masterBarBeat(masterSample: telemetry.masterSample,
                           bpm: telemetry.masterBPM,
                           sampleRate: engine.sampleRate)
    }
}
