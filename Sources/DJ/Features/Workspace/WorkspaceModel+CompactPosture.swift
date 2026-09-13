import Combine
import CoreGraphics
import Foundation
import TonearmCore

extension WorkspaceModel {
    // MARK: - Compact posture (§42.1, §42.6–42.7)

    /// The deck in focus on the compact solo-deck surface. The swap is a
    /// view-only change: both decks stay live in the engine and swapping or
    /// rotating changes no engine state (FR-ENG-10, §42.1).
    ///
    /// (`focusedDeck` is declared as a stored property on `WorkspaceModel`
    /// itself — see WorkspaceModel.swift — because Swift extensions cannot
    /// hold stored instance properties.)

    /// Swap which deck the compact surface focuses. View-only — no engine
    /// call is made, telemetry is untouched, both decks remain live (§42.1).
    public func swapFocus() {
        focusedDeck = focusedDeck == .a ? .b : .a
        Haptics.confirm()
    }

    /// Whether the browse-while-performing crate sheet is raised (§42.7,
    /// mockup `iphone/05b`). Raising it changes no engine state — the decks
    /// keep playing under the sheet.
    ///
    /// (`isCrateSheetPresented` is a stored property on `WorkspaceModel`
    /// itself — see WorkspaceModel.swift.)

    public func raiseCrateSheet() {
        isCrateSheetPresented = true
        Haptics.confirm()
        // A live performance can add/import a crate while the workspace is
        // already on screen. Refresh immediately when the user asks to browse;
        // the sheet must never look like Crate did nothing because it is still
        // displaying the queue captured when the decks were opened.
        Task { [weak self] in
            await self?.refreshDeckQueues()
        }
    }

    public func dismissCrateSheet() {
        isCrateSheetPresented = false
    }

    /// The band reserved for the always-visible crossfader bottom bar on the
    /// compact surface. The crate sheet's layout is bounded below by this
    /// band: it may never cover the crossfader (§42.7, mockup `iphone/05b`'s
    /// `bottom: 96px` inset).
    public static let crossfaderBarHeight: CGFloat = 96

    /// The tallest the crate sheet may be inside a `containerHeight`-tall
    /// container: roughly 60% of the height (mockup `iphone/05b`), but never
    /// reaching into the crossfader bar — both decks stay visible above the
    /// sheet and the crossfader stays reachable (§42.7).
    public static func crateSheetMaxHeight(containerHeight: CGFloat) -> CGFloat {
        max(0, min(containerHeight * 0.6, containerHeight - crossfaderBarHeight))
    }

    // MARK: - Compact posture (§42.1, §42.7a)

    /// The two iPhone postures (§42.1): **orientation is the mode switch** —
    /// there is no toggle, no setting, no button. Portrait is the solo-deck
    /// surface (`SoloDeckView`), landscape the twin-deck surface
    /// (`TwinDeckView`). The posture is presentation state on the one shared
    /// session VM (like `focusedDeck`); the `CompactPerformanceView` container
    /// maps the OS orientation to it, and both postures run over the same
    /// `WorkspaceModel` and the same live engine.
    public enum CompactPosture: Sendable, Equatable {
        /// Portrait — one deck in focus, one in a strip (§42.6–42.7).
        case solo
        /// Landscape — both decks resident, a jog each (§42.7a).
        case twin
    }

    /// The compact posture the surface currently renders. View-only state:
    /// rotating changes **no** engine state (FR-ENG-10, AT-TWIN-1).
    ///
    /// (`compactPosture` is a stored property on `WorkspaceModel` itself —
    /// see WorkspaceModel.swift.)

    /// Rotate the compact surface between the solo and twin postures
    /// (§42.1). View-only — no engine call is made, telemetry is untouched,
    /// both decks stay live under the swap (AT-TWIN-1). The container drives
    /// this from the OS orientation.
    public func setPosture(_ posture: CompactPosture) {
        compactPosture = posture
    }

    // MARK: - Beat-phase readout (§42.7a mixer column)

    /// The signed beat-phase error between the two decks in (−0.5, 0.5],
    /// positive when deck A is ahead (beat 0.9 vs 0.1 is a −0.2, not +0.8 —
    /// the minimal circular difference). Pure, so the twin mixer column's
    /// readout is testable off-device (AT-TWIN-1's phase meter).
    public static func beatPhaseError(phaseA: Double, phaseB: Double) -> Double {
        var error = (phaseA - phaseB).truncatingRemainder(dividingBy: 1)
        if error > 0.5 {
            error -= 1
        } else if error <= -0.5 {
            error += 1
        }
        return error
    }

    /// The phase error rendered as signed milliseconds at a tempo: `error`
    /// beats at `bpm` = `error × 60000 / bpm` (the sample rate cancels out of
    /// the samples→ms conversion), the mockup's "locked · ±1.8 ms".
    public static func beatPhaseErrorMillis(error: Double, bpm: Double) -> Double {
        guard bpm > 0 else { return 0 }
        return error * 60_000 / bpm
    }

    /// The current signed phase error between the two decks in milliseconds
    /// at the master tempo — the twin mixer column's centre readout.
    public var beatPhaseErrorMillis: Double {
        let error = Self.beatPhaseError(phaseA: telemetry.deckA.phase,
                                        phaseB: telemetry.deckB.phase)
        return Self.beatPhaseErrorMillis(error: error, bpm: telemetry.masterBPM)
    }

    // MARK: - Twin-deck geometry (§42.7a)

    /// The §42.7a twin-deck horizontal budget (spec arithmetic, verbatim):
    ///
    ///    734 = 30 │ 168 jog A │ 6 │ 54 transport │ 8 │ 202 mixer │ 8 │ 54 transport │ 6 │ 168 jog B │ 30
    ///
    /// Both deck columns (jog + transport) are 228 pt; the mixer column is
    /// 202 pt. Encoded here so the twin view consumes exactly the normative
    /// geometry and the frames are testable off-device.
    public enum TwinGeometry {
        public static let usableWidth: CGFloat = 734
        public static let deckColumnWidth: CGFloat = 228
        public static let mixerColumnWidth: CGFloat = 202
        public static let jogWidth: CGFloat = 168
        public static let transportWidth: CGFloat = 54
        public static let outerMargin: CGFloat = 30
        public static let columnGap: CGFloat = 8
        public static let jogTransportGap: CGFloat = 6
        /// The resident crossfader cap's width — the bottom-edge surface's 1:1
        /// mapping is against the cap's travel over the mixer column (§42.7a).
        public static let crossfaderCapWidth: CGFloat = 22
    }

    // MARK: - Momentary bank drawer (§42.7b, mockup `iphone/05d`)

    /// The four momentary banks on the compact surface (§42.7b). Filter is
    /// deliberately absent — it stays on the screen edge, visible and under a
    /// thumb while the drawer is open.
    public enum TwinBank: String, CaseIterable, Sendable {
        case eq = "EQ"
        case stems = "STEMS"
        case pads = "PADS"
        case cues = "CUES"
    }

    /// The §42.7b drawer state machine: `idle`, **spring-loaded** (a tab held —
    /// the drawer is raised for as long as the thumb holds, and releasing
    /// dismisses it within one frame, restoring the jog under the thumb), or
    /// **pinned** (a tap — hands-free, with a 12 s idle self-dismiss,
    /// AT-TWIN-3). The drawer covers **only** that deck's jog + transport and
    /// nothing else (FR-ENG-12, AT-TWIN-2).
    public enum DrawerState: Equatable, Sendable {
        case idle
        case spring(deck: Deck, bank: TwinBank)
        case pinned(deck: Deck, bank: TwinBank)

        public var deck: Deck? {
            switch self {
            case .idle: return nil
            case .spring(let deck, _): return deck
            case .pinned(let deck, _): return deck
            }
        }

        public var bank: TwinBank? {
            switch self {
            case .idle: return nil
            case .spring(_, let bank): return bank
            case .pinned(_, let bank): return bank
            }
        }

        public var isPinned: Bool {
            if case .pinned = self { return true }
            return false
        }
    }

    /// The drawer's current state on the compact surface. View-only: raising,
    /// pinning and dismissing a drawer changes **no** engine state — the decks
    /// keep playing and every shared control stays live (FR-ENG-12, AT-TWIN-2).
    ///
    /// (`drawerState` is a stored property on `WorkspaceModel` itself — see
    /// WorkspaceModel.swift.)

    /// The bank a deck's tab springs to and pins with (§42.7b). Defaults to
    /// `EQ`; the remembered selection survives a rotate and a dismiss.
    public func selectedBank(_ deck: Deck) -> TwinBank {
        bankByDeck[deck] ?? .eq
    }

    /// Spring the drawer open over a deck's jog + transport (§42.7b). Called
    /// on the bank tab's touch-down; the drawer stays up exactly as long as
    /// the thumb holds it.
    public func springDrawer(deck: Deck) {
        drawerIdleTask?.cancel()
        drawerState = .spring(deck: deck, bank: selectedBank(deck))
    }

    /// Release a held drawer: it dismisses **within one frame**, restoring the
    /// jog under the thumb (AT-TWIN-3). A held drawer cannot leave the surface
    /// in a mode the user has forgotten about.
    public func releaseDrawer() {
        drawerIdleTask?.cancel()
        guard drawerState.deck != nil else { return }
        drawerState = .idle
    }

    /// Pin the raised drawer for hands-free work. The pinned drawer
    /// self-dismisses after `pinnedDrawerIdle` of no touch (AT-TWIN-3).
    public func pinDrawer() {
        drawerIdleTask?.cancel()
        guard let deck = drawerState.deck else { return }
        drawerState = .pinned(deck: deck, bank: selectedBank(deck))
        armDrawerIdle()
        Haptics.confirm()
    }

    /// Dismiss the drawer (a pinned drawer's toggle-off, or the 12 s idle
    /// self-dismiss). View-only — the decks keep playing.
    public func dismissDrawer() {
        drawerIdleTask?.cancel()
        guard drawerState.deck != nil else { return }
        drawerState = .idle
    }

    /// Touch inside the pinned drawer resets its idle clock — the 12 s
    /// self-dismiss is "12 s of no touch" (§42.7b). The drawer's background
    /// reports every touch, so working the EQ knobs keeps the bank up.
    public func noteDrawerActivity() {
        guard drawerState.isPinned else { return }
        armDrawerIdle()
    }

    /// Switch the drawer's bank (the pinned drawer's seg selector). Resets the
    /// idle clock — this is touch.
    public func selectDrawerBank(_ bank: TwinBank) {
        guard let deck = drawerState.deck else { return }
        bankByDeck[deck] = bank
        switch drawerState {
        case .idle: break
        case .spring:
            drawerState = .spring(deck: deck, bank: bank)
        case .pinned:
            drawerState = .pinned(deck: deck, bank: bank)
            armDrawerIdle()
        }
    }

    private func armDrawerIdle() {
        drawerIdleTask?.cancel()
        let duration = pinnedDrawerIdle
        drawerIdleTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self.dismissDrawer()
        }
    }

    /// §42.7b's spring-loading discrimination (AT-TWIN-3): a press shorter
    /// than the tap threshold is a **tap** — it pins the bank for hands-free
    /// work; a longer hold that is released is a **peek** — it dismisses,
    /// restoring the jog under the thumb within one frame. Pure so the timing
    /// rule is testable off-device.
    public static func springReleasePins(holdDuration: TimeInterval,
                                         tapThreshold: TimeInterval = DrawerGeometry.tapThreshold) -> Bool {
        holdDuration < tapThreshold
    }

    /// §42.7b's geometry: the momentary drawer is exactly one deck column wide
    /// and spans the control band height — it may cover that deck's jog +
    /// transport, and nothing else (FR-ENG-12, AT-TWIN-2).
    public enum DrawerGeometry {
        public static let width: CGFloat = TwinGeometry.deckColumnWidth
        public static let height: CGFloat = 206
        /// A press shorter than this is a *tap* (pins the bank); a longer
        /// hold that is released is a *peek* (dismisses, restoring the jog).
        public static let tapThreshold: TimeInterval = 0.35
        /// The §42.7a landscape sensor-housing dead band the content is inset
        /// by on each edge.
        public static let deadBandInset: CGFloat = 59
        /// The §42.7b rule-2 screen-edge slider's width (the outer 24 pt).
        public static let edgeSliderWidth: CGFloat = 24
    }

    /// The drawer's x-range over a deck in the §42.7a usable-width coordinate
    /// space (0 = the left edge of the 734 pt usable width, outside the 59 pt
    /// dead band). The drawer is exactly one deck column wide over that deck's
    /// jog + transport, so it structurally cannot reach the mixer column or
    /// the opposite deck — the crossfader, both waveforms, the beat-phase
    /// meter and the opposite jog stay live and hit-testable (FR-ENG-12,
    /// AT-TWIN-2).
    public static func drawerXRange(deck: Deck) -> Range<CGFloat> {
        switch deck {
        case .a:
            let start = TwinGeometry.outerMargin
            return start..<(start + DrawerGeometry.width)
        case .b:
            let start = TwinGeometry.usableWidth - TwinGeometry.outerMargin - DrawerGeometry.width
            return start..<(start + DrawerGeometry.width)
        }
    }

    /// The mixer column's x-range in the same coordinate space. A drawer may
    /// never intersect it. (The §42.7a budget: outer margin 30 + deck column
    /// 228 + gap 8 → the mixer starts at 266.)
    public static var mixerXRange: Range<CGFloat> {
        let start = TwinGeometry.outerMargin + TwinGeometry.deckColumnWidth + TwinGeometry.columnGap
        return start..<(start + TwinGeometry.mixerColumnWidth)
    }

    /// §42.7a idiom 4: the whole bottom edge is a **1:1 relative crossfader
    /// drag surface** — a drag of `deltaX` pt moves the resident fader cap by
    /// `deltaX` pt. `residentCapTravel` is the resident cap's travel for a full
    /// −1 … +1 sweep; the mapping is linear and clamped at the ends. Pure so
    /// the 1:1 mapping is testable off-device.
    public static func relativeCrossfader(from position: Float,
                                          deltaX: CGFloat,
                                          residentCapTravel: CGFloat) -> Float {
        guard residentCapTravel > 0 else { return position }
        let unitsPerPoint = 2 / residentCapTravel
        return min(1, max(-1, position + Float(deltaX) * Float(unitsPerPoint)))
    }

}
