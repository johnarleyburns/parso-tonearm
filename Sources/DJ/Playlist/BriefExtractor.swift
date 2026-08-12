import Foundation

/// One thing the extractor understood about a brief, shown as an editable chip
/// (§28A.6, mockups `ipad/05a` / `iphone/03`). The UI renders the `kind` as a
/// sign (+/−) or a label and lets the user add, remove and edit chips; the
/// machine value keeps the slot computable without re-parsing.
public struct BriefChip: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case duration     // value: seconds
        case trackCount   // value: track count
        case bpm          // value: BPM midpoint (lo/hi live on the parse)
        case arc
        case positive
        case negative
    }

    public var kind: Kind
    public var label: String
    /// Machine value for duration (seconds) / trackCount (count) / bpm (midpoint).
    public var value: Double?

    public init(kind: Kind, label: String, value: Double? = nil) {
        self.kind = kind
        self.label = label
        self.value = value
    }

    public var id: String { "\(kind.rawValue)-\(label)" }
}

/// What the deterministic extractor pulled out of a brief (§28A.6, plan §2.8).
/// Everything the extractor did *not* recognise stays in the prompt and reaches
/// CLAP unchanged — an unparsed brief is good vibe search, never an error.
public struct BriefParse: Sendable, Equatable {
    public var targetSeconds: Double?
    public var targetTrackCount: Int?
    public var bpmLo: Double?
    public var bpmHi: Double?
    public var arc: EnergyArc?
    public var positiveTerms: [String]
    public var negativeTerms: [String]
    /// nil = not mentioned (the brief's default `allowExplicit` stands).
    public var allowExplicit: Bool?
    public var chips: [BriefChip]

    public init(targetSeconds: Double? = nil,
                targetTrackCount: Int? = nil,
                bpmLo: Double? = nil,
                bpmHi: Double? = nil,
                arc: EnergyArc? = nil,
                positiveTerms: [String] = [],
                negativeTerms: [String] = [],
                allowExplicit: Bool? = nil,
                chips: [BriefChip] = []) {
        self.targetSeconds = targetSeconds
        self.targetTrackCount = targetTrackCount
        self.bpmLo = bpmLo
        self.bpmHi = bpmHi
        self.arc = arc
        self.positiveTerms = positiveTerms
        self.negativeTerms = negativeTerms
        self.allowExplicit = allowExplicit
        self.chips = chips
    }
}

/// The deterministic brief extractor (§28A.6, plan §2.8). No LLM — ~200 lines of
/// fixed, ordered rules. Deterministic (NFR-DET-3): same prompt, same parse.
public enum BriefExtractor {

    public static func parse(_ prompt: String) -> BriefParse {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        var chips: [BriefChip] = []
        var parse = BriefParse()

        let duration = duration(from: text, lower: lower)
        if let duration {
            parse.targetSeconds = duration
            chips.append(BriefChip(kind: .duration,
                                   label: Self.durationLabel(duration),
                                   value: duration))
        }

        let count = trackCount(from: text, lower: lower)
        if let count {
            parse.targetTrackCount = count
            chips.append(BriefChip(kind: .trackCount,
                                   label: "\(count) tracks",
                                   value: Double(count)))
        }

        let bpm = bpmRange(from: text, lower: lower)
        if let bpm {
            parse.bpmLo = bpm.lo
            parse.bpmHi = bpm.hi
            let label = bpm.lo == bpm.hi
                ? "\(Self.bpmLabel(bpm.lo)) BPM"
                : "\(Self.bpmLabel(bpm.lo))–\(Self.bpmLabel(bpm.hi)) BPM"
            chips.append(BriefChip(kind: .bpm, label: label,
                                   value: (bpm.lo + bpm.hi) / 2))
        }

        let arc = arc(from: lower)
        if let arc {
            parse.arc = arc
            chips.append(BriefChip(kind: .arc, label: Self.arcLabel(arc)))
        }

        let terms = terms(from: lower)
        parse.positiveTerms = terms.positive
        parse.negativeTerms = terms.negative
        parse.allowExplicit = terms.allowExplicit
        chips += terms.positive.map { BriefChip(kind: .positive, label: $0) }
        chips += terms.negative.map { BriefChip(kind: .negative, label: $0) }

        parse.chips = chips
        return parse
    }

    // MARK: - Durations

    /// "2 hours", "1 hour 30 minutes", "45 min", "an hour", "two and a half hours",
    /// "half an hour". First structured match wins (deterministic).
    private static func duration(from text: String, lower: String) -> Double? {
        // Digit hours, optionally followed by minutes: "1 hour 30 minutes".
        if let m = match(#"(\d+(?:\.\d+)?)\s*(?:hours?|hrs?)\s*(?:(?:and\s+)?(\d+)\s*(?:minutes?|mins?))?"#,
                         in: lower),
           let hours = Double(m[1]) {
            var minutes = 0.0
            if m.count > 2, !m[2].isEmpty, let mins = Double(m[2]) { minutes = mins }
            return hours * 3600 + minutes * 60
        }
        // Digit minutes: "90 minutes", "45 min".
        if let m = match(#"(\d+(?:\.\d+)?)\s*(?:minutes?|mins?)"#, in: lower),
           let minutes = Double(m[1]) {
            return minutes * 60
        }
        // "N and a half hours" (word or digit N).
        if let m = match(#"(?:(an?|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|\d+))\s+and\s+(?:a\s+)?half\s+(?:hours?|hrs?)"#,
                         in: lower),
           let base = Self.number(m[1]) {
            return (base + 0.5) * 3600
        }
        // "half an hour" / "half hour".
        if Self.match(#"half\s+(?:an\s+)?(?:hours?|hrs?|hr)"#, in: lower) != nil {
            return 1800
        }
        // Word hours: "two hours", "an hour".
        if let amount = wordAmount(units: ["hours?", "hrs?"], in: lower) {
            return amount * 3600
        }
        // Word minutes: "twenty minutes".
        if let amount = wordAmount(units: ["minutes?", "mins?"], in: lower) {
            return amount * 60
        }
        return nil
    }

    /// "20 tracks", "a twelve-track set", "ten songs".
    private static func trackCount(from text: String, lower: String) -> Int? {
        if let m = match(#"(\d+)\s*(?:tracks?|songs?)\b"#, in: lower), let n = Int(m[1]) {
            return n
        }
        if let m = match(#"(\w+)\s*-\s*track\b"#, in: lower) {
            return Self.number(m[1]).map(Int.init)
        }
        if let m = match(#"(\w+)\s*(?:tracks?|songs?)\b"#, in: lower) {
            return Self.number(m[1]).map(Int.init)
        }
        return nil
    }

    /// "120–128 BPM", "120 to 128 bpm", "around 118 bpm", "118 bpm".
    private static func bpmRange(from text: String, lower: String) -> (lo: Double, hi: Double)? {
        if let m = match(#"(\d{2,3})\s*(?:-|–|—|to)\s*(\d{2,3})\s*bpm"#, in: lower),
           let lo = Double(m[1]), let hi = Double(m[2]) {
            return (lo, hi)
        }
        if let m = match(#"(?:(?:around|about|~|approx\.?)\s*)?(\d{2,3})\s*bpm\b"#, in: lower),
           let n = Double(m[1]) {
            return (n, n)
        }
        return nil
    }

    // MARK: - Arc phrase table (§28A.6)

    /// Fixed phrase table, checked in a fixed precedence so a brief mentioning
    /// several arc words ("builds after the food, ends euphoric") maps to the
    /// most specific shape rather than the first keyword (deterministic).
    private static func arc(from lower: String) -> EnergyArc? {
        if containsAny(lower, ["starts mellow and ends", "ends euphoric", "euphoric",
                               "peak and release", "peak & release", "peaks and",
                               "climax", "climaxes", "peak"]) {
            return .peakAndRelease(peakAt: EnergyArc.defaultPeakAt)
        }
        if containsAny(lower, ["wind down", "wind-down", "winds down", "cool down",
                               "calm down", "end of the night", "mellow out"]) {
            return .windDown
        }
        if containsAny(lower, ["steady", "studying", "study", "background",
                               "ambient", "focus", "concentration", "work"]) {
            return .steady(level: EnergyArc.defaultLevel)
        }
        if containsAny(lower, ["builds up", "build", "builds", "build up", "rises",
                               "ramp up", "crescendo", "rising"]) {
            return .build
        }
        if containsAny(lower, ["waves", "undulating", "ebb and flow", "flowing", "wave"]) {
            return .wave(cycles: EnergyArc.defaultCycles)
        }
        return nil
    }

    // MARK: - +/− vocal and explicit terms

    private struct TermParse {
        var positive: [String] = []
        var negative: [String] = []
        var allowExplicit: Bool?
    }

    private static func terms(from lower: String) -> TermParse {
        var result = TermParse()
        // "shouty vocals" is always a minus, never also a plus.
        let shouty = containsAny(lower, ["nothing with shouty vocals", "no shouty vocals",
                                         "without shouty vocals", "shouty vocals",
                                         "screaming vocals"])
        if shouty {
            result.negative.append("shouty vocals")
        }
        // Vocal preference: "no vocals" reads negative, plain "vocals" positive.
        // A "shouty vocals" minus already implies the vocal preference, so it
        // must not also add a positive "vocals" chip.
        if containsAny(lower, ["no vocals", "without vocals", "instrumental",
                               "no singing", "not vocal"]) {
            result.negative.append("vocals")
        } else if !shouty, containsAny(lower, ["with vocals", "some vocals", "vocals",
                                               "vocal", "singing", "lyrics"]) {
            result.positive.append("vocals")
        }
        // Explicit-content preference.
        if containsAny(lower, ["no explicit", "without explicit", "explicit-free",
                               "clean version", "clean lyrics"]) {
            result.allowExplicit = false
            result.negative.append("explicit")
        } else if containsAny(lower, ["explicit"]) {
            result.positive.append("explicit")
        }
        return result
    }

    // MARK: - Helpers

    private static let numberWords: [String: Double] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40,
        "fifty": 50, "sixty": 60,
    ]

    private static func number(_ token: String) -> Double? {
        numberWords[token] ?? Double(token)
    }

    /// The first `<word> <unit>` pair where `<word>` is a number word.
    private static func wordAmount(units: [String], in lower: String) -> Double? {
        let unitPattern = units.joined(separator: "|")
        let wordPattern = numberWords.keys.joined(separator: "|")
        if let m = match("(\(wordPattern))\\s+(\(unitPattern))\\b", in: lower),
           let amount = number(m[1]) {
            return amount
        }
        return nil
    }

    private static func durationLabel(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0, minutes > 0 { return "\(hours) h \(minutes) min" }
        if hours > 0 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        return "\(minutes) min"
    }

    private static func bpmLabel(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    private static func arcLabel(_ arc: EnergyArc) -> String {
        switch arc {
        case .steady: return "Steady"
        case .build: return "Build"
        case .peakAndRelease: return "Build → peak → gentle release"
        case .windDown: return "Wind down"
        case .wave: return "Wave"
        case .custom: return "Custom"
        }
    }

    private static func containsAny(_ lower: String, _ phrases: [String]) -> Bool {
        phrases.contains { lower.contains($0) }
    }

    /// First regex match, deterministic. Capture 0 is the whole match.
    private static func match(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: text) else { return "" }
            return String(text[range])
        }
    }
}
