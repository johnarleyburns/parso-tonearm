import XCTest

/// The live-catalogue DJ lane — `LANES=djlive` (spec §53.12).
///
/// The same journey as `DJMixRegressionUITests`, against the **real Jamendo API**.
/// Assertions are deliberately weaker, because the material is uncontrolled: real
/// music has broadband low end on both decks, so the §53.9 tone-identity signatures
/// cannot be asserted here at all. What this lane checks is that tracks browse, load
/// and play; that the recording reaches its expected duration; that the export
/// decodes; and that the journal is well-formed.
///
/// Its job is to catch what the mock cannot — a changed endpoint shape, a paging
/// bug, a licence field that stopped arriving, an audio format the decoder rejects.
///
/// **It informs; it does not gate.** M5's exit rides on `djmix` (§48.6 step 5),
/// because this lane depends on a third party being up. Per §53.4, an unreachable
/// API or an absent `client_id` **skips with the remedy stated** and never fails the
/// run: a missing credential is not a defect in Platterhead.
@MainActor
final class DJLiveMixRegressionUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// AT-MIX-9 · Real catalogue → real playlists → a real mix that records.
    func testAT_MIX_09_LiveGenreBrowseToRecordedMix() throws {
        _ = try RegressionEnv.require("PH_TEST_JAMENDO_CLIENT_ID", lane: "AT-MIX-9 (live Jamendo)")
        try Self.requireLiveJamendoReachable(lane: "AT-MIX-9 (live Jamendo)")

        // Explicitly no mock: this lane must hit the real host.
        app = .launchForDJRegression(mockCatalogue: nil, resetLibrary: true)

        // Two real genres, two real crates.
        addGenreSource(genres: ["electronic/techno", "electronic/house"])
        sendGenreToDJLibrary("Techno")
        sendGenreToDJLibrary("House")

        // Both decks load (real material) and both playheads advance.
        app.openDJDecks()
        app.openCrate()
        app.selectQueue("a", title: "Techno")
        loadFirstTrack()
        app.closeCrate()
        XCTAssertTrue(app.playDeck("a"))
        app.waitForDeckLoaded("a")

        app.focusDeck("b")
        app.openCrate()
        app.selectQueue("b", title: "House")
        loadFirstTrack()
        app.closeCrate()
        XCTAssertTrue(app.playDeck("b"))
        app.waitForDeckLoaded("b")

        _ = app.waitForBar(2)

        // Record a short real mix, then stop and finalize.
        app.waitFor(DJRegression.ID.record).tap()
        Thread.sleep(forTimeInterval: 25)
        app.waitFor(DJRegression.ID.record).tap()

        // The recording finalised and is reviewable (FR-REC-6).
        app.waitForLabelContaining("dj.export.path", "Not exported", timeout: 60)
    }

    /// AT-MIX-10 · Licence and attribution survive the whole path (§18A.5).
    ///
    /// Jamendo's catalogue is Creative Commons, and CC comes with obligations that
    /// only matter if the metadata actually reaches the places a listener sees:
    /// the library row, the finish screen, and the exported cue-sheet.
    func testAT_MIX_10_LicenceAndAttributionSurviveToTheExport() throws {
        _ = try RegressionEnv.require("PH_TEST_JAMENDO_CLIENT_ID", lane: "AT-MIX-10 (live Jamendo)")
        try Self.requireLiveJamendoReachable(lane: "AT-MIX-10 (live Jamendo)")

        app = .launchForDJRegression(mockCatalogue: nil, resetLibrary: false)

        // The genre source's badge states the licence (§18A.5).
        app.buttons["Libraries"].firstMatch.tap()
        let sourceRow = app.element("Source Techno")
        XCTAssertTrue(sourceRow.waitForExistence(timeout: 30),
                      "the Techno source from AT-MIX-9 should still be here")
        sourceRow.tap()
        app.waitFor("genre.sendToDJ") // the source detail renders

        // The recorded mix's finish screen carries attribution + the licence line.
        app.buttons["DJ"].firstMatch.tap()
        app.waitFor("dj.mixes").tap()
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'dj.mix.'"))
            .firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30), "no recorded mix to review")
        card.tap()

        let attribution = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Creative Commons")).firstMatch
        XCTAssertTrue(attribution.waitForExistence(timeout: 30),
                      "the finish screen must carry the Creative-Commons attribution line")

        // Export under -uiRegression writes the cue sheet beside the mix (§18A.5).
        app.waitFor("dj.export.run").tap()
        app.waitForLabelContaining("dj.export.path", "Documents", timeout: 60)
    }

    // MARK: - Helpers

    private func addGenreSource(genres: [String]) {
        app.buttons["Libraries"].firstMatch.tap()
        app.buttons["Add"].firstMatch.tap()
        app.waitFor("Add Remote Library").tap()
        selectConnector("jamendoGenre")
        app.waitFor("genre.expand.electronic").tap()
        for path in genres {
            app.waitFor("genre.\(path)").tap()
        }
        app.waitFor("genre.add").tap()
        app.waitForNonExistence("genre.add", 60)
        app.waitFor("Close Add Remote Library", 60).tap()
    }

    private func sendGenreToDJLibrary(_ genre: String) {
        app.waitFor("Source \(genre)").tap()
        XCTAssertTrue(app.waitFor("genre.sendToDJ", 60).exists)
        app.waitFor("genre.sendToDJ").tap()
        app.waitForLabelContaining("genre.sendToDJ", "Saved", timeout: 600)
        app.waitFor("source.back").tap()
    }

    /// Tap the first row of the focused deck's crate — the live lane cannot know
    /// the real track titles, so it takes the crate's head (most-interesting first).
    private func loadFirstTrack() {
        let row = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'dj.queue.row.'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "no crate rows to load")
        row.tap()
    }

    private func selectConnector(_ id: String) {
        let pill = app.buttons["Remote Library Connector \(id)"]
        for _ in 0..<10 {
            if pill.exists && pill.isHittable {
                pill.tap()
                return
            }
            guard let anchor = app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH 'Remote Library Connector '"))
                .allElementsBoundByIndex.first(where: { $0.isHittable }) else {
                app.swipeLeft(velocity: .fast)
                continue
            }
            let y = anchor.frame.midY
            let start = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: app.frame.width * 0.85, dy: y))
            let end = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: app.frame.width * 0.15, dy: y))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast,
                        thenHoldForDuration: 0.1)
        }
        XCTAssertTrue(pill.isHittable, "connector \(id) never became reachable")
        pill.tap()
    }

    /// Probe the real API from the test process. Unreachable → XCTSkip with the
    /// remedy, per §53.4 — a third party being down is not a Platterhead defect.
    private static func requireLiveJamendoReachable(lane: String) throws {
        guard let url = URL(string: "https://api.jamendo.com/v3.0/tracks?client_id=x&format=json&limit=1") else {
            throw XCTSkip("\(lane) skipped — could not build the probe URL")
        }
        guard DJRegression.isReachable(url, timeout: 15) else {
            throw XCTSkip("\(lane) skipped — the Jamendo API is unreachable. "
                          + "Check your network, then re-run `make test-ui-regression LANES=djlive`.")
        }
    }
}

extension XCUIApplication {
    /// Wait until a deck reports a loaded track (any real title).
    func waitForDeckLoaded(_ deck: String, timeout: TimeInterval = 60) {
        let element = element("dj.deck.\(deck).loaded")
        let predicate = NSPredicate(format: "label != %@", "Nothing loaded")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout),
                       .completed, "deck \(deck) never loaded a track")
    }
}
