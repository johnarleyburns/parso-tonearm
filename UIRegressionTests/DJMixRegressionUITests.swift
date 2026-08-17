import XCTest

/// The deterministic DJ live-mix lane — `LANES=djmix` (spec §53.7–53.12).
///
/// **This lane gates M5** (§48.6 exit step 5), because it means the same thing on
/// every run. It uses fixture media with per-deck **tone identity** (deck A
/// 55/611/5300 Hz, deck B 87/1290/8900 Hz) and a mock catalogue, so band energy in
/// the recording is *attributable to a specific deck*. That is what turns "did the
/// bass swap?" into a question with a crisp answer; real music has broadband low end
/// on both decks and cannot support the assertion (§53.8, §54.6).
///
/// The four test methods are **one journey sharing the app's container**: the first
/// launches with `-resetLibrary`, and the rest deliberately do not, so the genre
/// crates, the playlists and the recorded mix persist across them. The tests run in
/// alphabetical order (`AT_MIX_01` → `AT_MIX_08`).
///
/// `AT-MIX-3..7` are performed **inside one continuous recording**, not as five
/// separate sessions. That is what "a live mix" means, and it is the only way a
/// transition's tail can be observed running into the next one.
///
/// The acoustic assertions are **not made here.** This lane performs the mix and
/// leaves behind the export plus `mix-journal.json`; `scripts/ui-regression/verify-mix.py`
/// proves the §53.9 signatures on the host, and the runner preserves the audio so a
/// human can listen to it and judge whether the thresholds are tuned right.
///
/// Timing is *musical*, not wall-clock: every gesture is scheduled on a `dj.master.bar`
/// boundary so a transition lands on the grid the way a DJ would play it — and every
/// gap is counted **from the bar the previous gesture finished on**, never from the
/// start of the set, because a gesture consumes bars and an absolute grid quietly
/// spends the next gap paying for the last one.
@MainActor
final class DJMixRegressionUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // The fixtures are the whole assertion here: without the mock catalogue
        // this lane would browse real music, whose broadband low end no tone
        // signature survives. Skip with the remedy instead (§53.4).
        try DJRegression.requireMockCatalogue()
    }

    // MARK: - AT-MIX-1 · genre picker → two crates

    /// AT-MIX-1 · Genre picker → genre library → two different playlists.
    ///
    /// The whole point of FR-LIB-9 is that a *genre* is the unit of subscription and
    /// that it works with **no account**, so this lane never signs in. It adds two
    /// genres through the real picker (Techno + House), browses each one's
    /// most-interesting track list, pulls each into the DJ library as a crate, and
    /// proves both crates exist as selectable deck queues holding their own tracks.
    func testAT_MIX_01_GenrePickerBuildsTwoCrates() throws {
        app = .launchForDJRegression(resetLibrary: true)

        // Libraries tab → Add → Add Remote Library → the Jamendo connector.
        app.buttons["Libraries"].firstMatch.tap()
        app.buttons["Add"].firstMatch.tap()
        app.waitFor("Add Remote Library").tap()
        selectConnector("jamendoGenre")

        // Genre picker: Electronic → Techno + House → add both libraries.
        app.waitFor("genre.expand.electronic").tap()
        app.waitFor("genre.electronic/techno").tap()
        app.waitFor("genre.electronic/house").tap()
        app.waitFor("genre.add").tap()

        // The sheet flow returns to the Libraries list; both sources landed.
        app.waitForNonExistence("genre.add", 30)
        app.waitFor("Close Add Remote Library", 30).tap()
        app.waitFor("Source Techno", 60)
        app.waitFor("Source House", 60)

        // Send each genre's most-interesting tracks to the DJ library.
        for genre in ["Techno", "House"] {
            app.waitFor("Source \(genre)").tap()
            // The browse shows the genre's ordered track list (mock popularity order).
            XCTAssertTrue(app.waitFor("remote.node.\(genre.lowercased())-1", 60).exists)
            app.waitFor("genre.sendToDJ").tap()
            app.waitForLabelContaining("genre.sendToDJ", "Saved", timeout: 300)
            app.waitFor("source.back").tap()
        }

        // Both crates are selectable deck queues holding their own tracks — and
        // holding *different* tracks, which is what makes AT-MIX-2's two decks a
        // real pair of playlists rather than one library seen twice.
        app.openDJDecks()
        app.openCrate()
        app.assertQueues("a", [
            "Techno": ["Techno Fixture 1", "Techno Fixture 6"],
            "House": ["House Fixture 1", "House Fixture 6"],
        ])
        app.closeCrate()
    }

    // MARK: - AT-MIX-2 · both decks draw from different crates

    /// AT-MIX-2 · Both decks draw from **different** playlists at once (FR-ENG-13),
    /// and both playheads actually advance.
    ///
    /// "Both advance" is the corroboration allowed by §53.8 — it catches a dead
    /// render pump immediately and by its right name, instead of surfacing later as
    /// an unexplained signature mismatch. Each deck also reports its own loaded
    /// track, so the two decks demonstrably hold different material.
    func testAT_MIX_02_TwoDecksFromIndependentCrates() throws {
        app = .launchForDJRegression(resetLibrary: false)
        app.openDJDecks()

        // Deck A from the Techno crate.
        app.openCrate()
        app.selectQueue("a", title: "Techno")
        app.loadTrack(title: "Techno Fixture 1")
        app.closeCrate()
        XCTAssertTrue(app.playDeck("a"))
        app.waitForLabelContaining("dj.deck.a.loaded", "Techno Fixture 1", timeout: 30)

        // Deck B from the House crate — a different playlist at the same time.
        app.focusDeck("b")
        app.openCrate()
        app.selectQueue("b", title: "House")
        app.loadTrack(title: "House Fixture 2")
        app.closeCrate()
        XCTAssertTrue(app.playDeck("b"))
        app.waitForLabelContaining("dj.deck.b.loaded", "House Fixture 2", timeout: 30)

        // The master clock advances with both decks running.
        _ = app.waitForBar(2)
    }

    // MARK: - AT-MIX-3..7 · the five transitions, one continuous recording

    /// AT-MIX-3..7 · The full scripted set — record, perform all five of DJ Blakey's
    /// beginner transitions on the phrase boundaries, stop.
    ///
    /// One test rather than five, because they share a recording. Splitting them
    /// would lose the thing that makes this a *mix* rather than five clips, and the
    /// Echo Out tail specifically has to be observed ringing into what follows.
    ///
    /// The app writes each recognised gesture into `mix-journal.json` with its
    /// recording-relative sample; the host analyzer then proves each acoustic
    /// signature is where the journal says it is (§53.9). Gesture recognition lives
    /// in `WorkspaceModel` (§35.2/§35.3/§35A/§35.4), not in this test.
    func testAT_MIX_03_07_FiveTransitionsInOneRecording() throws {
        app = .launchForDJRegression(resetLibrary: false)
        app.openDJDecks()

        // Load both decks without starting the clock yet, so the prep below runs
        // against an idle master clock and the recording starts on a known bar.
        app.openCrate()
        app.selectQueue("a", title: "Techno")
        app.loadTrack(title: "Techno Fixture 1")
        app.closeCrate()
        app.focusDeck("b")
        app.openCrate()
        app.selectQueue("b", title: "House")
        app.loadTrack(title: "House Fixture 2")
        app.closeCrate()

        // Prep (not part of the recording): deck B's low is killed so the bass
        // swap has a low band to hand over. Every mixer move below goes through
        // the verified helpers — they read the control's published position back
        // and fail where the gesture missed, rather than leaving the failure to
        // surface as a signature the analyzer cannot find.
        app.focusDeck("b")
        app.openBank("EQ", expects: "dj.deck.b.eq.low")
        app.killEQBand("dj.deck.b.eq.low")

        // Start the clock: both decks play, then record.
        app.focusDeck("a")
        XCTAssertTrue(app.playDeck("a"))
        app.focusDeck("b")
        XCTAssertTrue(app.playDeck("b"))
        app.focusDeck("a")
        _ = app.waitForBar(4)
        app.startRecording()
        // Both decks started here, so by the time `holdMix` runs they have
        // consumed roughly the whole recording's worth of their tracks. It has
        // to be told, or its rotation clock starts from zero at the hold and
        // schedules the first track change for after the fixtures have run out —
        // which is how every recording ended in twenty seconds of silence.
        let decksStartedAt = Date()

        // **Every gap below is relative** — `waitBars(n)` from wherever the
        // last gesture finished, never a bar number counted from the start of
        // the set (`waitBars`, and §14 of the plan). A gesture takes bars to
        // perform; an absolute grid silently subtracts that from the gap that
        // was meant to follow it, and the transitions end up on top of each
        // other.
        //
        // Eight clear bars around every mark is what the analyzer's windows
        // assume: it reads the settled state 4–6 bars past a mark whose gesture
        // is still moving at the mark itself (§53.10, `verify-mix.py`). A
        // transition performed too soon after the last one is not a tighter
        // test, it is an unreadable one.

        // 1 — Bass Swap: kill deck A's low (deck B's is already killed) on the
        // phrase boundary, then restore deck B's low — the low end changes
        // hands while both mids play through, which is what makes it a swap and
        // not a cut (§53.9 row 1). The mark is the kill; the swap is complete
        // when B's low is back, a bar or two later.
        app.waitBars(4)
        app.openBank("EQ", expects: "dj.deck.a.eq.low")
        app.killEQBand("dj.deck.a.eq.low")
        app.focusDeck("b")
        app.openBank("EQ", expects: "dj.deck.b.eq.low")
        app.restoreEQBand("dj.deck.b.eq.low")
        app.focusDeck("a")

        // Hand deck A's low back, clear of the swap's measurement window. A
        // filter sweep has nothing to prove on a band the EQ already killed —
        // the low cannot fall twice — and a DJ who swapped the bass over would
        // bring it back before reaching for anything else.
        app.waitBars(8)
        app.openBank("EQ", expects: "dj.deck.a.eq.low")
        app.restoreEQBand("dj.deck.a.eq.low")

        // 2 — Filter Transition: sweep deck A's filter to full high-pass, hold
        // it closed for a phrase, then release to centre (the §35.3 hard
        // bypass, which is its own mark).
        app.waitBars(6)
        app.openBank("Filter", expects: "dj.deck.a.filter")
        // Swept over roughly two bars, the way the transition is actually
        // performed — and the span the analyzer watches the centroid climb.
        // Up to a ~250 Hz corner, not full right: the sweep has to take deck A's
        // low out while its mid and top still pass, which is what "high-pass the
        // outgoing deck" means and what §53.9 row 2 measures. Full right is a
        // 6 kHz corner and takes the whole track with it.
        app.sweepSlider("dj.deck.a.filter", to: 0.45, stages: 5, settle: 0.1)
        // Held closed for a phrase: the analyzer reads the closed state once
        // the sweep has settled, and the hold is what gives it something
        // settled to read.
        app.waitBars(8)
        app.sweepSlider("dj.deck.a.filter", to: 0)

        // 3 — Echo Out: echo on deck A, cut its channel fader and let the §35A
        // tail ring on past the cut. The tail is the assertion — a pre-fader
        // echo would die with the fader and leave nothing at all — so the
        // channel stays down well past the window the tail is measured in.
        app.waitBars(6)
        app.waitFor(DJRegression.ID.echo).tap()
        app.openBank("Fader", expects: "dj.deck.a.fader")
        app.sweepSlider("dj.deck.a.fader", to: 0, range: 0...1)
        app.waitBars(6)
        app.sweepSlider("dj.deck.a.fader", to: 1, range: 0...1)
        app.waitFor(DJRegression.ID.echo).tap()

        // 4 — Fader Cut: deck B's channel fader to the floor, no echo, sharp.
        app.waitBars(6)
        app.focusDeck("b")
        app.openBank("Fader", expects: "dj.deck.b.fader")
        app.sweepSlider("dj.deck.b.fader", to: 0, range: 0...1, velocity: .fast)
        app.waitBars(4)
        app.sweepSlider("dj.deck.b.fader", to: 1, range: 0...1)
        app.focusDeck("a")

        // 5 — Blend: park on deck A's side, then sweep to centre and hold it —
        // both decks audible together for eight bars, phase-locked.
        app.waitBars(4)
        app.sweepCrossfader(to: -1)
        app.waitBars(2)
        app.sweepCrossfader(to: 0)
        _ = app.holdMix(forBars: 10,
                        decksPlayingFor: Date().timeIntervalSince(decksStartedAt))

        // Stop and finalize; the finish sheet appears for AT-MIX-8.
        app.waitFor(DJRegression.ID.record).tap()
        app.waitForLabelContaining("dj.export.path", "Not exported", timeout: 30)
    }

    // MARK: - AT-MIX-8 · the artifact

    /// AT-MIX-8 · Record → finalize → **review listen** → export.
    ///
    /// FR-REC-6 requires the finished mix to be playable in place the moment it
    /// finalises — no export step, no re-encode, no hunting in Mixes — so this lane
    /// opens the recorded mix's review screen and asserts the transport works
    /// *before* it goes near the file. FR-REC-7 requires the screen to name the
    /// format it actually produces (M4A/AAC) and never to promise MP3. Then it
    /// triggers the harness export and reads the container path off `dj.export.path`.
    func testAT_MIX_08_ReviewListenAndExport() throws {
        app = .launchForDJRegression(resetLibrary: false)

        // Recorded Mixes → the mix the previous lane recorded.
        app.buttons["DJ"].firstMatch.tap()
        app.waitFor("dj.mixes").tap()
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'dj.mix.'"))
            .firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30), "no recorded mix to review")
        card.tap()

        // Review listen (FR-REC-6): play in place, then pause.
        let play = app.buttons.matching(NSPredicate(format: "label == %@", "Play review listen"))
            .firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 30), "review transport missing")
        play.tap()
        let pause = app.buttons.matching(NSPredicate(format: "label == %@", "Pause review listen"))
            .firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 15), "review listen did not start")
        pause.tap()

        // FR-REC-7: the format is named honestly — M4A · AAC, never MP3.
        XCTAssertTrue(app.staticTexts["M4A · AAC 256 kbps"].waitForExistence(timeout: 15),
                      "the finish screen must name the real format")
        let allText = app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: "\n")
        XCTAssertFalse(allText.localizedCaseInsensitiveContains("MP3"),
                       "the finish screen must never promise MP3")

        // Export under -uiRegression (hook 5.12): the share action writes the
        // container export and publishes the path.
        app.waitFor("dj.export.run").tap()
        app.waitForLabelContaining("dj.export.path", "Documents", timeout: 60)
    }

    // MARK: - Helpers

    /// Pick a remote-library connector pill, scrolling the horizontal picker until
    /// it is reachable (the genre connector is last in the catalogue). The swipe is
    /// performed across the screen at the picker's vertical position, since a drag
    /// confined to one pill's frame is too short to register as a scroll.
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
}
