import Foundation

/// Cue monitoring — the mobile problem and its three answers (§44.2a, FR-HW-3).
///
/// Pre-listening is the one thing a DJ cannot do without and a phone cannot
/// natively provide: there is one stereo output, and it is already carrying the
/// mix the room hears. Every mode below is a different trade against that fact,
/// and the app must be honest about which trade is in force — a cue that
/// silently degrades is worse than no cue, because the user only finds out in
/// front of people.
public enum CueMode: String, Sendable, Equatable, Codable, CaseIterable {
    /// No pre-listen. The default, and bit-exact: the render path is untouched,
    /// which is what keeps the offline harness's frame-exact assertions valid.
    case off
    /// **Split output** (§44.2a mode 2, the specified default for users without
    /// an interface): master summed to mono on the **left**, cue summed to mono
    /// on the **right**, for a $10 stereo-to-dual-mono splitter cable. Works on
    /// every device with a headphone path and no other accessory.
    case splitOutput
    /// **Cue in place** (mode 3): no pre-listen at all — engaging cue solos the
    /// cued deck to the single output, so the room hears what you are auditing.
    /// For practice, and labelled as such wherever it is offered.
    case cueInPlace
    /// **True multichannel** (mode 1): master on channels 1/2, cue on 3/4 of a
    /// >2-channel USB-C interface. The path serious users take. Honest and
    /// inert until such a route exists — selecting it with a 2-channel route
    /// available must not silently behave like something else.
    case multichannel

    public var displayName: String {
        switch self {
        case .off: return "Off"
        case .splitOutput: return "Split output (cable)"
        case .cueInPlace: return "Cue in place"
        case .multichannel: return "Interface (3/4)"
        }
    }

    /// The cost, stated where the user chooses (§44.2a: "the cost is honest and
    /// must be stated in the UI"). §50.1 identifies unfamiliarity, not
    /// technology, as the risk here — so the sentence has to be plain.
    public var costNote: String? {
        switch self {
        case .off:
            return nil
        case .splitOutput:
            return "Your master is mono while split cue is on. Needs a stereo-to-dual-mono "
                 + "splitter cable: speakers on the left plug, headphones on the right."
        case .cueInPlace:
            return "There is no separate headphone feed — cueing a deck plays it out loud, "
                 + "over your mix. For practice only."
        case .multichannel:
            return "Master on channels 1–2, cue on 3–4. Needs an interface with more than "
                 + "two output channels."
        }
    }

    /// Whether this mode can actually be delivered on a route with
    /// `outputChannels` channels.
    ///
    /// The check exists so a mode that cannot work is refused **at selection**,
    /// with the reason, rather than accepted and quietly delivered as something
    /// else. That substitution is the failure §44.2a is written against.
    public func isAvailable(outputChannels: Int) -> Bool {
        switch self {
        case .off, .cueInPlace: return true
        case .splitOutput: return outputChannels >= 2
        case .multichannel: return outputChannels >= 4
        }
    }
}

/// The output matrix for a cue mode: pure sample math, no I/O, so every claim
/// below is testable against a rendered buffer (§53.9's layer 1).
public enum CueMix {

    /// −6 dB on each summed leg. Summing L+R to mono doubles a correlated
    /// signal, so a mix that was fine in stereo would clip the moment split cue
    /// engaged — the attenuation is what keeps switching modes from being a
    /// level event.
    public static let monoSumGain: Float = 0.5

    /// Apply split output in place: master → left (mono), cue → right (mono).
    ///
    /// Both legs are summed from the same stereo pair they came from, so a
    /// deck panned hard left is still audible in the cue — a pre-listen that
    /// loses half the material is not a pre-listen.
    public static func applySplitOutput(master: inout [Float], cue: [Float],
                                        frames: Int, channels: Int) {
        guard channels >= 2, frames > 0 else { return }
        for i in 0..<frames {
            let masterMono = (master[i * channels] + master[i * channels + 1]) * monoSumGain
            let cueMono = (cue[i * channels] + cue[i * channels + 1]) * monoSumGain
            master[i * channels] = masterMono
            master[i * channels + 1] = cueMono
            // Any further channels are silent in this mode: they belong to a
            // route this mode does not know how to fill, and leaving stale
            // audio in them would be worse than silence.
            for c in 2..<channels { master[i * channels + c] = 0 }
        }
    }

    /// Apply multichannel routing in place: master stays on 1/2, cue lands on
    /// 3/4. Stereo is preserved on both legs — this is the mode with nothing to
    /// trade.
    public static func applyMultichannel(master: inout [Float], cue: [Float],
                                         frames: Int, channels: Int) {
        guard channels >= 4, frames > 0 else { return }
        for i in 0..<frames {
            master[i * channels + 2] = cue[i * channels]
            master[i * channels + 3] = cue[i * channels + 1]
        }
    }

    /// Apply cue-in-place: the cue bus *replaces* the master, so the single
    /// output carries the audited deck. Honest to its name — the room hears it.
    public static func applyCueInPlace(master: inout [Float], cue: [Float],
                                       frames: Int, channels: Int) {
        guard frames > 0, channels > 0 else { return }
        for i in 0..<(frames * channels) {
            master[i] = cue[i]
        }
    }
}
