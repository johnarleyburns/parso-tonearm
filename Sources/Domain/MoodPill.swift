import Foundation

/// A selectable mood/feeling pill for the Listen tab's mood entry point
/// (docs/plans/mood-based-listening-plan.md §3.2). `queryTerm` is what gets
/// added to `DiscoverySearchQuery.positiveRefinements` — kept separate from
/// `label` so the taxonomy can carry a richer embedding phrase than what's
/// shown on the pill itself (e.g. label "Calm" → term "calm, relaxed, low
/// energy"), and so the whole taxonomy lives in one editable place instead
/// of scattered across view code.
public struct MoodPill: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var queryTerm: String

    public init(id: String, label: String, queryTerm: String) {
        self.id = id
        self.label = label
        self.queryTerm = queryTerm
    }
}

/// First-draft taxonomy (plan §3.2) — validated against a real library, not
/// ported from the sibling app's classical-catalog set. The Era/Vibe
/// category is intentionally absent here: it's generated per-library at
/// runtime from `SuggestionChips.seed(from:)` (real BPM/key/energy/duration
/// distribution), not hand-picked, so it can't be a fixed array.
public enum MoodPillTaxonomy {
    public static let energy: [MoodPill] = [
        MoodPill(id: "calm", label: String(localized: "Calm", bundle: .module), queryTerm: "calm, relaxed, low energy"),
        MoodPill(id: "upbeat", label: String(localized: "Upbeat", bundle: .module), queryTerm: "upbeat, energetic, lively"),
        MoodPill(id: "intense", label: String(localized: "Intense", bundle: .module), queryTerm: "intense, driving, powerful"),
        MoodPill(id: "mellow", label: String(localized: "Mellow", bundle: .module), queryTerm: "mellow, laid back, easygoing")
    ]

    public static let setting: [MoodPill] = [
        MoodPill(id: "focus", label: String(localized: "Focus", bundle: .module), queryTerm: "focus music, concentration, no distraction"),
        MoodPill(id: "background", label: String(localized: "Background", bundle: .module), queryTerm: "background music, unobtrusive, ambient"),
        MoodPill(id: "deepListen", label: String(localized: "Deep Listen", bundle: .module), queryTerm: "deep listening, immersive, attentive"),
        MoodPill(id: "sleep", label: String(localized: "Sleep", bundle: .module), queryTerm: "sleep music, soothing, quiet, restful")
    ]

    public static let character: [MoodPill] = [
        MoodPill(id: "instrumental", label: String(localized: "Instrumental", bundle: .module), queryTerm: "instrumental, no vocals"),
        MoodPill(id: "vocalForward", label: String(localized: "Vocal-forward", bundle: .module), queryTerm: "vocal forward, singing, lyrics"),
        MoodPill(id: "acoustic", label: String(localized: "Acoustic", bundle: .module), queryTerm: "acoustic, unplugged, organic instruments"),
        MoodPill(id: "electronic", label: String(localized: "Electronic", bundle: .module), queryTerm: "electronic, synthesized, produced")
    ]

    /// Fixed categories only — the Era/Vibe category is appended by the
    /// caller from `SuggestionChips` (library-derived), not included here.
    public static var fixedCategories: [MoodPill] {
        energy + setting + character
    }
}
