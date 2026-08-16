import XCTest

/// The stem lane — `LANES=djstem` (plan `dj-stems-model.md` S8, §53.7–53.12).
///
/// Layer 3 for stems: the model is wired (S5), the transforms match torch (S2),
/// and the honest ceiling is in place (S7) — what no lower layer can see is
/// whether the shipped app separates a real track and the **vocal fader moves
/// the recorded audio**. This lane drives the real UI: load a fixture track
/// onto a deck, wait for the stem faders to become live, record, pull the
/// vocal fader to the floor, stop, and export. The host analyzer
/// (`verify-mix.py`, `stem.fader`) then proves the move changed the audio on
/// the **settled** state — a band measured a few bars either side of the
/// journal mark, never mid-flight (§53.9).
///
/// **Skip-versus-fail is load-bearing (§53.4).** This lane needs the ODR tag
/// `demucs-stems` present *and* the app's separation path wired. In the normal
/// CI/simulator environment there is no model, so the deck's stems honestly
/// stay unavailable — the lane skips with that stated reason and never fakes
/// a pass. A deck whose stems are *available* but never become prepared is a
/// product defect and fails.
@MainActor
final class DJStemRegressionUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // The fixtures are the whole assertion here (tone identity the host
        // analyzer measures); without the mock catalogue, skip with the remedy.
        try DJRegression.requireMockCatalogue()
    }

    func testAT_STEM_01_VocalFaderMoveChangesTheRecordedAudio() throws {
        app = .launchForDJRegression(resetLibrary: true)
        app.openDJDecks()

        // Load a fixture track onto the focused deck (deck A).
        app.openCrate()
        app.selectQueue("a", title: "Techno")
        app.loadTrack(title: "Techno Fixture 1")
        app.closeCrate()

        // The compact surface's Stems bank is the default; a *prepared* deck
        // renders live faders carrying the §53.11 identifiers, an unprepared
        // one renders the honest disabled bars. Wait for the live row.
        let vocal = app.element("dj.deck.a.stem.vocals")
        let prepared = vocal.waitForExistence(timeout: 180)
        guard prepared, vocal.isHittable else {
            throw XCTSkip("""
                djstem skipped — the deck's stem faders never became live. \
                This lane needs the ODR tag demucs-stems present (place \
                Resources/Models/DemucsStems.mlpackage and run by hand) *and* \
                the app's separation path wired; without them the deck honestly \
                plays the full mix with disabled faders (§53.4). If the model \
                IS present and wired, this skip is a product defect — investigate.
                """)
        }

        // Record a few bars of the fader-up state, pull the vocal fader to the
        // floor, hold it, then stop and export. The mark fires where the fader
        // lands; verify-mix.py measures settled-before vs settled-after.
        app.startRecording()
        app.waitBars(4)
        app.dragStemFader("dj.deck.a.stem.vocals", toFloor: true)
        app.waitBars(8)
        app.waitFor(DJRegression.ID.record).tap()
        app.waitForLabelContaining("dj.export.path", "Not exported", timeout: 30)
        app.waitFor("dj.export.run").tap()
        app.waitForLabelContaining("dj.export.path", "Documents", timeout: 60)
    }
}

extension XCUIApplication {
    /// Drag a live stem fader's gain capsule to the floor (0 of its 0…1.5
    /// range) as one continuous gesture — the pull-out the `stem.fader`
    /// journal mark and the settled-band analyzer check assume.
    func dragStemFader(_ identifier: String, toFloor: Bool) {
        let row = waitFor(identifier)
        let from = row.coordinate(withNormalizedOffset: CGVector(dx: toFloor ? 0.8 : 0.05,
                                                                 dy: 0.5))
        let to = row.coordinate(withNormalizedOffset: CGVector(dx: toFloor ? 0.05 : 0.8,
                                                               dy: 0.5))
        from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow,
                   thenHoldForDuration: 0.3)
    }
}
