import Combine
import Foundation

/// The §41.18 transition coach (plan 5.13, FR-TRANS-6; mockup
/// `ipad/16-transitions.html`): the §35B five as teaching lessons — what each
/// is, when to reach for it, and a **control walkthrough that highlights the
/// real controls in place** on the performance surface rather than depicting
/// them in an illustration that would drift from the app.
///
/// Three rules from the mockup and §41.18, all encoded here:
///
/// - **It never takes over.** The panel is a dismissible overlay; the decks
///   keep playing. Presentation, selection and dismissal are view-only — the
///   model holds **no engine reference**, so nothing the coach does can reach
///   the audio path (the §42.7b drawer discipline, the 4.10 precedent).
/// - **It never performs the transition.** A lesson is copy + a highlight set
///   and nothing else — there is no "do it for me" affordance anywhere in the
///   model (an app that auto-mixes teaches nothing).
/// - **It is free tier.** FR-TRANS-6 is `[F]` — teaching, not performing — so
///   the model has no entitlement seam and is available before purchase.
///
/// The highlight set is the whole point: `Lesson.controlIdentifiers` is
/// computed from the §35B roles through the one pure role → §53.11 identifier
/// map, so a lesson can never name a control the surfaces do not actually
/// carry — "in place" is made structural, not aspirational.
@MainActor
public final class TransitionCoachModel: ObservableObject {

    /// One §35B lesson. The `roles` MUST equal the §35B table
    /// (`WorkspaceModel.transitionRoleSets` — the AT-TRANS layout assertions
    /// and the coach read the *same* mapping, so the coach cannot teach a
    /// transition the surface cannot perform). `controlIdentifiers` derives
    /// from `roles`, which is what makes the highlight honest.
    public struct Lesson: Identifiable, Equatable, Sendable {
        /// The transition's name — matches the §35B row and
        /// `WorkspaceModel.transitionRoleSets`.
        public let id: String
        /// The one-paragraph description of what the transition is (§41.18).
        public let summary: String
        /// When to reach for it (§41.18).
        public let whenToUse: String
        /// The control-walkthrough chips — what the hands do (§41.18).
        public let steps: [String]
        /// The §35B control roles the transition needs — equal to the table.
        public let roles: Set<WorkspaceModel.TransitionRole>

        public init(id: String,
                    summary: String,
                    whenToUse: String,
                    steps: [String],
                    roles: Set<WorkspaceModel.TransitionRole>) {
            self.id = id
            self.summary = summary
            self.whenToUse = whenToUse
            self.steps = steps
            self.roles = roles
        }

        /// The §53.11 identifiers of the **real controls** the transition
        /// moves, in their actual positions — the coach's highlight set. A
        /// per-deck role lights up *both* decks' controls (Bass Swap's LOW is
        /// both `dj.deck.a.eq.low` and `dj.deck.b.eq.low`). Computed from
        /// `roles` through the one pure role → identifier map, so the walkthrough
        /// can never drift from the app (§41.18's "in place").
        public var controlIdentifiers: Set<String> {
            roles.reduce(into: Set<String>()) { ids, role in
                ids.formUnion(TransitionCoachModel.controlIdentifiers(for: role))
            }
        }
    }

    /// The §35B five, in table order — the coach's single source of teaching
    /// copy. The tests assert each lesson's `roles` equals the §35B table's
    /// role set, so what the coach teaches is exactly what the surface can do.
    public static let allLessons: [Lesson] = [
        Lesson(
            id: "Bass Swap",
            summary: "Bring the new track in with its LOW killed — two basslines "
                + "at once is what mud sounds like. On the phrase boundary, swap "
                + "them: outgoing LOW down, incoming LOW up, in one movement. The "
                + "crowd hears one continuous low end.",
            whenToUse: "Both tracks have strong bass and you want the swap to be one clean movement.",
            steps: ["CH A · LOW", "CH B · LOW", "channel faders",
                    "phrase ribbon → find the boundary"],
            roles: [.lowEQ, .channelFader, .phraseRibbon]
        ),
        Lesson(
            id: "Filter Transition",
            summary: "Sweep the outgoing track's FILTER clockwise into high-pass "
                + "— the bass thins out and the track lifts away — while the "
                + "incoming comes up underneath it. Release both to centre when "
                + "the swap is done. Forgiving, and it works even when the "
                + "phrasing isn't perfect.",
            whenToUse: "The phrasing is imperfect, or you want a gentle exit that works anywhere.",
            steps: ["CH A · FILTER", "CH B · FILTER", "channel faders"],
            roles: [.filter, .channelFader]
        ),
        Lesson(
            id: "Echo Out",
            summary: "Turn ECHO on over the outgoing track, then cut its channel "
                + "fader. The track stops but its tail keeps ringing — one bar, "
                + "then two, fading — and the new track walks in underneath. The "
                + "exit that buys you time when a track has no outro.",
            whenToUse: "The outgoing track has no outro — the ringing tail buys you the time.",
            steps: ["Beat FX · ECHO", "beat length", "CH A fader → 0"],
            roles: [.echo, .channelFader]
        ),
        Lesson(
            id: "Fader Cut",
            summary: "No blend at all. On the downbeat, cut — crossfader or "
                + "channel fader, straight across. Set the crossfader curve to "
                + "sharp first. The waveform's heavy downbeat tick is your visual "
                + "metronome; land on it.",
            whenToUse: "A track ends hard on the one and you want the drop-and-swap.",
            steps: ["crossfader · sharp", "channel faders", "downbeat ticks"],
            roles: [.crossfader]
        ),
        Lesson(
            id: "Blend / Mix",
            summary: "The long one. Both tracks playing together for 16–32 bars, "
                + "EQ trimmed so they don't fight — usually pulling MID on one of "
                + "them. Watch the two waveforms on the shared playhead: when the "
                + "grids line up, you're in phase.",
            whenToUse: "You have room to let two tracks sit together and build.",
            steps: ["CH A · MID", "CH B · MID", "channel faders",
                    "beat-phase meter", "stacked waveforms"],
            roles: [.channelFader, .lowEQ, .midEQ, .highEQ, .beatPhase, .sharedWaveform]
        )
    ]

    /// The pure role → §53.11 identifier map — "highlighting the real controls
    /// in place" made executable: a lesson never names an identifier the
    /// surfaces do not use, because this *is* the identifier the surfaces use.
    /// Display roles (phrase ribbon, waveform, beat-phase meter) carry their
    /// own identifiers so the coach can light them too. Nonisolated so a
    /// `Lesson` (a Sendable value) can compute its highlight set anywhere.
    nonisolated public static func controlIdentifiers(for role: WorkspaceModel.TransitionRole) -> Set<String> {
        switch role {
        case .lowEQ:
            return ["dj.deck.a.eq.low", "dj.deck.b.eq.low"]
        case .midEQ:
            return ["dj.deck.a.eq.mid", "dj.deck.b.eq.mid"]
        case .highEQ:
            return ["dj.deck.a.eq.high", "dj.deck.b.eq.high"]
        case .channelFader:
            return ["dj.deck.a.fader", "dj.deck.b.fader"]
        case .filter:
            return ["dj.deck.a.filter", "dj.deck.b.filter"]
        case .echo:
            return ["dj.fx.echo"]
        case .crossfader:
            return ["dj.mixer.crossfader"]
        case .phraseRibbon:
            return ["dj.phrase"]
        case .sharedWaveform:
            return ["dj.waveform"]
        case .beatPhase:
            return ["dj.master.phase"]
        }
    }

    /// Whether the panel is open. When it is, the performance surface lights
    /// the controls in `highlightedIdentifiers` (§41.18). View-only: opening,
    /// selecting and dismissing touch no engine state.
    @Published public private(set) var isPresented = false
    /// The selected lesson's index into `allLessons` (clamped on read).
    @Published public var selectedIndex = 0

    /// The selected lesson.
    public var selectedLesson: Lesson {
        Self.allLessons[min(max(0, selectedIndex), Self.allLessons.count - 1)]
    }

    /// The §53.11 identifiers of the real controls the selected lesson moves —
    /// the set the surface highlights while the panel is open (§41.18).
    public var highlightedIdentifiers: Set<String> {
        selectedLesson.controlIdentifiers
    }

    public init() {}

    /// Open the panel. The decks keep playing underneath; the highlight set is
    /// driven from `selectedLesson`.
    public func present() {
        isPresented = true
    }

    /// Dismiss the panel. The highlight clears with it.
    public func dismiss() {
        isPresented = false
    }

    /// Select a lesson. Out-of-range indices are ignored — selection stays on
    /// the last valid one.
    public func select(_ index: Int) {
        guard Self.allLessons.indices.contains(index) else { return }
        selectedIndex = index
    }
}
