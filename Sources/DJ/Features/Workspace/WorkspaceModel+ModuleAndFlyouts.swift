import Combine
import CoreGraphics
import Foundation
import TonearmCore

extension WorkspaceModel {
    // MARK: - Release-to-commit flyout (§42.7b idiom 3, §41.9a)

    /// §42.7b idiom 3: the **release-to-commit flyout** anchored to LOOP. The
    /// §41.9a beat counts; release over a size commits, release outside
    /// cancels — the loop never changes on the way out. CUE keeps its existing
    /// §33.1 press-jump-preview / release-return, which is the same idiom's
    /// cue semantics (hold to preview, release to return; nothing changes on
    /// the way out).
    public enum LoopAction: Equatable {
        case set(Double)
        case exit
    }

    /// The flyout's geometry and release resolution, laid out in the flyout's
    /// own coordinate space (origin = the flyout's top-left, including the
    /// kicker header). The view anchors the flyout over the LOOP button and
    /// renders each chip at exactly its `chipFrame`, so the drag's release
    /// point resolves honestly against what the user sees:
    /// `releasedAction(at:)` returns the commit — `nil` means the finger slid
    /// out and nothing changes.
    public enum LoopFlyout {
        public static let beats: [Double] = [1, 2, 4, 8, 16, 32]
        public static let width: CGFloat = 150
        public static let chipWidth: CGFloat = 44
        public static let chipHeight: CGFloat = 34
        public static let gap: CGFloat = 6
        public static let horizontalPadding: CGFloat = 8
        public static let headerHeight: CGFloat = 26
        public static let topPadding: CGFloat = 8
        public static let beatsPerRow = 3
        public static let exitChipWidth: CGFloat = 96

        static var gridHeight: CGFloat {
            let rows = (beats.count + beatsPerRow - 1) / beatsPerRow
            return CGFloat(rows) * chipHeight + CGFloat(max(0, rows - 1)) * gap
        }

        public static var height: CGFloat {
            headerHeight + topPadding + gridHeight + gap + chipHeight + topPadding
        }

        static func chipFrame(index: Int) -> CGRect {
            let row = index / beatsPerRow
            let col = index % beatsPerRow
            return CGRect(x: horizontalPadding + CGFloat(col) * (chipWidth + gap),
                          y: headerHeight + topPadding + CGFloat(row) * (chipHeight + gap),
                          width: chipWidth, height: chipHeight)
        }

        static var exitChipFrame: CGRect {
            CGRect(x: (width - exitChipWidth) / 2,
                   y: headerHeight + topPadding + gridHeight + gap,
                   width: exitChipWidth, height: chipHeight)
        }

        /// The action a release point commits, `nil` when it slides out.
        /// Nothing changes on the way out — the engine is touched only here.
        public static func releasedAction(at point: CGPoint) -> LoopAction? {
            for (index, beats) in beats.enumerated() where chipFrame(index: index).contains(point) {
                return .set(beats)
            }
            if exitChipFrame.contains(point) { return .exit }
            return nil
        }
    }

    // MARK: - iPad module slot (§41.9a, mockup `ipad/07b`)

    /// The per-deck module slot on the iPad workspace (§41.9a). The lower
    /// third of a deck column offers `JOG · STEMS · PADS · FX`, is remembered
    /// per deck, and **defaults to `STEMS`** so §41.9 is what an existing user
    /// sees unless they ask for something else.
    public enum DeckModuleSlot: String, CaseIterable, Sendable, Equatable {
        case jog = "JOG"
        case stems = "STEMS"
        case pads = "PADS"
        case fx = "FX"
    }

    /// The persisted per-deck choices (§41.9a): the module slot and the jog's
    /// platter mode. Injectable `UserDefaults` keeps the persistence testable
    /// off-device (the VibeSearchModel convention).
    public static let moduleSlotDefaultsPrefix = "workspace.moduleSlot."
    public static let jogModeDefaultsPrefix = "workspace.jogMode."

    /// The module slot a deck currently occupies — the remembered selection,
    /// `STEMS` by default (§41.9a).
    public func moduleSlot(_ deck: Deck) -> DeckModuleSlot {
        deck == .a ? moduleSlotA : moduleSlotB
    }

    /// Switch a deck's module slot (`JOG · STEMS · PADS · FX`). The choice is
    /// remembered per deck and across launches. **View-only**: swapping the
    /// module changes no engine state — the decks keep playing, the mixer and
    /// transport stay live, and only the deck's own lower third re-renders
    /// (AT-TWIN-2).
    public func setModuleSlot(_ slot: DeckModuleSlot, deck: Deck) {
        switch deck {
        case .a: moduleSlotA = slot
        case .b: moduleSlotB = slot
        }
        defaults.set(slot.rawValue, forKey: Self.moduleSlotKey(deck))
        Haptics.confirm()
    }

    /// The deck's jog platter action (§41.9a): vinyl = scratch, CDJ = nudge.
    /// Remembered per deck, defaulting to vinyl.
    public func jogMode(_ deck: Deck) -> JogGestureModel.JogMode {
        deck == .a ? jogModeA : jogModeB
    }

    /// Set the deck's jog platter action. Remembered per deck. **View-only** —
    /// it changes the jog's gesture model, never the engine (FR-ENG-11).
    public func setJogMode(_ mode: JogGestureModel.JogMode, deck: Deck) {
        switch deck {
        case .a: jogModeA = mode
        case .b: jogModeB = mode
        }
        defaults.set(mode == .vinyl ? "vinyl" : "cdj", forKey: Self.jogModeKey(deck))
        Haptics.confirm()
    }

    /// The deck's jog sensitivity, 0.5–2.0 (§40.7.4).
    public func jogSensitivity(_ deck: Deck) -> Double {
        deck == .a ? jogSensitivityA : jogSensitivityB
    }

    /// Set the deck's jog sensitivity, clamped into the §40.7.4 range. **View-
    /// only** — sensitivity scales the jog gesture's displacement; it never
    /// reaches the engine.
    public func setJogSensitivity(_ deck: Deck, value: Double) {
        let clamped = JogGestureModel.clampSensitivity(value)
        switch deck {
        case .a: jogSensitivityA = clamped
        case .b: jogSensitivityB = clamped
        }
    }

    private static func deckName(_ deck: Deck) -> String {
        deck == .a ? "a" : "b"
    }

    private static func moduleSlotKey(_ deck: Deck) -> String {
        moduleSlotDefaultsPrefix + deckName(deck)
    }

    private static func jogModeKey(_ deck: Deck) -> String {
        jogModeDefaultsPrefix + deckName(deck)
    }

    static func readModuleSlot(defaults: UserDefaults,
                                       deck: Deck) -> DeckModuleSlot {
        let raw = defaults.string(forKey: moduleSlotKey(deck)) ?? ""
        return DeckModuleSlot(rawValue: raw) ?? .stems
    }

    static func readJogMode(defaults: UserDefaults,
                                    deck: Deck) -> JogGestureModel.JogMode {
        defaults.string(forKey: jogModeKey(deck)) == "cdj" ? .cdj : .vinyl
    }

    /// §41.9a/§41.9b module and club geometry. The jog module is the widest
    /// module — a 248 pt jog flanked by the ± pitch-bend columns — and must fit
    /// its deck column without pushing into the mixer column (AT-TWIN-2: a
    /// module never occludes shared controls; it is a layout member of its own
    /// column, not an overlay). §41.9b widens the mixer column to 320 pt and
    /// narrows each deck column to ~416 pt; the 392 pt jog module still fits
    /// the deck column alone (the module slot's JOG option), and the deck
    /// column's permanent §41.9b jog is the plain 248 pt platter beside the
    /// tempo fader, which also fits (decision 19: the geometry tests are
    /// updated against the new numbers, never weakened).
    public enum ModuleGeometry {
        /// The §41.9a jog diameter: 248 pt ≈ 48 mm at the iPad's 131 pt/in — a
        /// whole-hand control rather than the iPhone's thumb control.
        public static let jogSize: CGFloat = 248
        /// Each ± pitch-bend column's width (mockup `ipad/07b`).
        public static let bendColumnWidth: CGFloat = 58
        /// The jog ↔ bend-column gap (mockup `ipad/07b`'s 14 px).
        public static let bendGap: CGFloat = 14
        /// The jog module's normative total width: jog + two bend columns +
        /// two gaps.
        public static var jogModuleWidth: CGFloat {
            jogSize + 2 * bendColumnWidth + 2 * bendGap
        }
        /// The §41.9b mixer column width (mockup `07`'s `320px` — widened from
        /// M4's 268 so the two channel strips fit side by side).
        public static let mixerColumnWidth: CGFloat = 320
        /// The §41.9b normative deck column width (~416 pt; the mockup grid
        /// `1fr 320px 1fr`'s flexible fraction on a 1180 canvas is 406 pt after
        /// padding, and the 328 pt jog module fits both).
        public static let deckColumnWidth: CGFloat = 416
        /// The §41.9b tempo fader's column width on the deck's outer edge
        /// (rule 4). The fader rides beside the jog module: 416 − 328 − gap ≥
        /// this, so the pair fits the deck column.
        public static let tempoFaderWidth: CGFloat = 58
        /// The workspace's column gap and outer padding (mockup `07`'s 12 px).
        public static let columnGap: CGFloat = 12
        public static let outerPadding: CGFloat = 12

        /// A deck column's width on a `canvas`-wide workspace — the §41.9b
        /// grid `1fr 320px 1fr`. The jog module is a member of its deck column,
        /// so `jogModuleWidth ≤ deckColumnWidth` is what keeps it from ever
        /// reaching the mixer column (AT-TWIN-2).
        public static func deckColumnWidth(canvas: CGFloat) -> CGFloat {
            max(0, (canvas - 2 * outerPadding - mixerColumnWidth - 2 * columnGap) / 2)
        }
    }

    /// The §41.9b club arrangement's normative constants — the things the
    /// layout and the FR-TRANS-2 layout assertions pin down off-device:
    /// per-channel strip order, CUE-left-of-PLAY, the tempo fader's range, and
    /// the eight pads under their mode selector (rule 5).
    public enum ClubGeometry {
        /// §41.9b rule 1: the channel strip's reading order, top to bottom.
        public static let channelStripOrder: [String] =
            ["TRIM", "HI", "MID", "LOW", "FILTER", "FADER", "CUE"]
        /// §41.9b rule 3: CUE sits to the LEFT of PLAY at each deck's inner
        /// base, both ≥ 54 pt. Deck B mirrors horizontally (PLAY nearest the
        /// mixer on both decks — the inner thumb).
        public static let deckTransportOrder: [String] = ["CUE", "PLAY"]
        /// §41.9b rule 4: the tempo fader's range, ±8% — the §31.2 range
        /// "typical in beatmatching" (FR-ENG-6).
        public static let tempoFaderRange: ClosedRange<Double> = -0.08...0.08
        /// §41.9b rule 5: eight performance pads, two rows of four.
        public static let padColumns = 4
        public static let padRows = 2
        public static let padCount = padColumns * padRows
        /// §41.9b rule 5: the pad mode selector, immediately above the pads.
        public static let padModes: [String] = ["HOT CUE", "PAD FX", "BEAT JUMP", "SAMPLER"]
        /// §41.9b rule 7 / §35A: the beat-synced echo's beat lengths. The
        /// engine lands in commit 5.5; until then the Beat FX block renders the
        /// honest unavailable state (the stems convention).
        public static let echoBeats: [Double] = [0.25, 0.5, 1, 2, 4]
    }

    // MARK: - §35B transition → control mapping (AT-TRANS layout half, plan 5.5)

    /// The role a §35B transition needs from a performance surface. The table
    /// is the §35B five (rows) × their control sets (columns), encoded once so
    /// the AT-TRANS layout assertions and the transition coach (5.13) read the
    /// same mapping. `FR-TRANS-1` — all five performable on the default surface
    /// with no configuration — is asserted against these sets.
    public enum TransitionRole: String, CaseIterable, Sendable {
        case lowEQ
        case midEQ
        case highEQ
        case channelFader
        case phraseRibbon
        case filter
        case echo
        case crossfader
        case beatPhase
        case sharedWaveform
    }

    /// The §35B five, each with the controls that perform it (the normative
    /// mapping; "a transition is a test, not a mode").
    public static let transitionRoleSets: [(transition: String, roles: Set<TransitionRole>)] = [
        ("Bass Swap", [.lowEQ, .channelFader, .phraseRibbon]),
        ("Filter Transition", [.filter, .channelFader]),
        ("Echo Out", [.echo, .channelFader]),
        ("Fader Cut", [.crossfader]),
        ("Blend / Mix", [.channelFader, .lowEQ, .midEQ, .highEQ, .beatPhase, .sharedWaveform])
    ]

    /// The controls the §41.9b iPad surface keeps **always visible** — nothing
    /// a transition needs is behind a mode on the tablet (FR-TRANS-1/2).
    public static let tabletAlwaysVisibleRoles: Set<TransitionRole> =
        Set(TransitionRole.allCases)

    /// The controls the §42.7c compact surface keeps **always visible**, never
    /// in a drawer: the transferable core — crossfader, channel faders, edge
    /// filters, CUE-left-of-PLAY, jog, shared waveforms, and the **ECHO button**
    /// (Echo Out is a two-control transition, so echo and the fader must both
    /// be reachable without a drawer, §42.7c).
    public static let compactAlwaysVisibleRoles: Set<TransitionRole> = [
        .channelFader, .filter, .echo, .crossfader, .beatPhase,
        .sharedWaveform, .phraseRibbon
    ]

    /// The controls the compact surface reaches through the §42.7b momentary
    /// bank drawer (EQ — the spring-loading idiom makes Bass Swap performable:
    /// press, kill the low, release, drawer gone within one frame).
    public static let compactDrawerRoles: Set<TransitionRole> = [
        .lowEQ, .midEQ, .highEQ
    ]

    /// Everything the compact surface can reach — always-visible plus drawer.
    public static var compactReachableRoles: Set<TransitionRole> {
        compactAlwaysVisibleRoles.union(compactDrawerRoles)
    }

    // MARK: - §42.7c / §35A compact ECHO release-to-commit flyout

    /// The §42.7c compact **ECHO** treatment: a long-press flyout for beat
    /// length, depth and channel, using the same release-to-commit idiom as
    /// LOOP (§42.7b idiom 3). The flyout's geometry and release resolution are
    /// pure so the commit/cancel decision is pinned off-device — nothing
    /// changes on the way out, the engine is touched only on a release inside a
    /// commit target.
    public enum EchoFlyout {
        public static let beats: [Double] = ClubGeometry.echoBeats
        public static let width: CGFloat = 190
        public static let headerHeight: CGFloat = 24
        public static let topPadding: CGFloat = 6
        public static let channelChipWidth: CGFloat = 44
        public static let channelChipHeight: CGFloat = 26
        public static let channelGap: CGFloat = 6
        public static let beatsRowTop: CGFloat =
            headerHeight + topPadding + channelChipHeight + 6
        public static let chipWidth: CGFloat = 30
        public static let chipHeight: CGFloat = 28
        public static let chipGap: CGFloat = 5
        public static let depthTop: CGFloat = beatsRowTop + chipHeight + 8
        public static let depthHeight: CGFloat = 26
        public static let horizontalPadding: CGFloat = 8
        public static let bottomPadding: CGFloat = 8

        public static var height: CGFloat {
            depthTop + depthHeight + bottomPadding
        }

        /// The two channel chips (A/B) in the flyout's header row.
        public static func channelChipFrame(index: Int) -> CGRect {
            let total = 2 * channelChipWidth + channelGap
            let x0 = (width - total) / 2
            return CGRect(x: x0 + CGFloat(index) * (channelChipWidth + channelGap),
                          y: headerHeight + topPadding,
                          width: channelChipWidth, height: channelChipHeight)
        }

        /// A beat-length chip's frame, centred in the flyout.
        public static func chipFrame(index: Int) -> CGRect {
            let total = CGFloat(beats.count) * chipWidth
                + CGFloat(max(0, beats.count - 1)) * chipGap
            let x0 = (width - total) / 2
            return CGRect(x: x0 + CGFloat(index) * (chipWidth + chipGap),
                          y: beatsRowTop,
                          width: chipWidth, height: chipHeight)
        }

        /// The depth strip's frame (0 at its left edge … 1 at its right).
        public static func depthTrackFrame() -> CGRect {
            CGRect(x: horizontalPadding, y: depthTop,
                   width: width - 2 * horizontalPadding, height: depthHeight)
        }

        /// What a release point commits, `nil` when it slides out (nothing
        /// changes on the way out).
        public enum EchoAction: Equatable {
            /// `0` = deck A, `1` = deck B.
            case channel(Int)
            case beats(Double)
            case depth(Float)
        }

        /// Resolve a release point to the commit it lands on: the channel
        /// chips, a beat chip, the depth track, or `nil` outside all of them.
        public static func releasedAction(at point: CGPoint) -> EchoAction? {
            for index in 0..<2 where channelChipFrame(index: index).contains(point) {
                return .channel(index)
            }
            for (index, beats) in beats.enumerated() where chipFrame(index: index).contains(point) {
                return .beats(beats)
            }
            if depthTrackFrame().contains(point) {
                let track = depthTrackFrame()
                let t = min(1, max(0, (point.x - track.minX) / max(1, track.width)))
                return .depth(Float(t))
            }
            return nil
        }
    }
}
