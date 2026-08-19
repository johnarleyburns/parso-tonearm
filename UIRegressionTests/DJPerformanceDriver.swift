import XCTest

/// Shared plumbing for the DJ live-mix lanes (spec §53.7–53.12).
///
/// These lanes are a **third layer** above the test suites that run in CI, and each
/// layer below is blind to what it catches:
///
/// - layer 1, `swift test`: the DSP is correct (`AT-TRANS-*` against the offline
///   render, sample-exact);
/// - layer 2, `swift test`: the controls exist, are ≥ 44 pt and un-occluded;
/// - layer 3, **here**: the *wiring* — a real gesture on a real control reaches the
///   command ring, the engine, the record tap, the encoder and the export.
///
/// Layer 3 exists because of §49.3a. The M4 engine was correct, tested, and entirely
/// unreachable — no file outside `Sources/DJ/` referenced any performance surface —
/// and every layer-1 and layer-2 test was green while the feature did not exist in
/// the shipped binary. These lanes are that invariant made into a standing guard.
///
/// **`XCUITest` cannot hear.** A lane asserting that a deck row reads *Playing* is
/// the D-10 false green exactly (§53.5). So these lanes assert against the
/// **recording the app itself produces**: they drive the UI, the app records its
/// master bus, and `scripts/ui-regression/verify-mix.py` proves the transitions are
/// acoustically present in the exported file — on the host, by code that is not
/// Platterhead (§53.8).
///
/// Timing here is deliberately *musical*, not wall-clock: gestures are scheduled on
/// bar boundaries read from `dj.master.bar`, because a transition performed off the
/// grid is not the transition under test.
enum DJRegression {

    /// Accessibility identifiers, per the §53.11 convention. These are part of each
    /// control's contract — VoiceOver needs them too — and they land in commit 5.4
    /// with the controls, not here (plan decision 27).
    enum ID {
        static func play(_ deck: String) -> String { "dj.deck.\(deck).play" }
        static func cue(_ deck: String) -> String { "dj.deck.\(deck).cue" }
        static func filter(_ deck: String) -> String { "dj.deck.\(deck).filter" }
        static func fader(_ deck: String) -> String { "dj.deck.\(deck).fader" }
        static func eq(_ deck: String, _ band: String) -> String { "dj.deck.\(deck).eq.\(band)" }

        static let crossfader = "dj.mixer.crossfader"
        static let echo = "dj.fx.echo"
        static let bar = "dj.master.bar"
        static let record = "dj.transport.record"
        static let exportPath = "dj.export.path"
        /// Present only while the performance surface is Pro-gated (§40.4).
        static let paywallLock = "dj.paywall.lock"
    }

    /// Length of the scripted mix. Default 6 minutes — long enough to perform all
    /// five transitions with phrases between them, short enough to run often.
    /// `MIX_MINUTES=20` is the pre-release soak. Twenty real-time simulator minutes
    /// as the *default* is a flake generator, and a flaky suite gets switched off.
    static var mixMinutes: Double {
        guard let raw = ProcessInfo.processInfo.environment["MIX_MINUTES"],
              let value = Double(raw), value > 0 else { return 6 }
        return value
    }

    /// The tracks a long mix rotates through, alternating decks and drawing each
    /// from that deck's own crate (FR-ENG-13 — the two decks never share a
    /// playlist). Deck A's fixtures carry the 55/611/5300 Hz tone set and deck
    /// B's the 87/1290/8900 Hz one, so every rotation keeps the deck identities
    /// the analyzer measures.
    static let rotation: [(deck: String, crate: String, title: String)] = [
        (deck: "a", crate: "Techno", title: "Techno Fixture 3"),
        (deck: "b", crate: "House", title: "House Fixture 4"),
        (deck: "a", crate: "Techno", title: "Techno Fixture 5"),
        (deck: "b", crate: "House", title: "House Fixture 6"),
        (deck: "a", crate: "Techno", title: "Techno Fixture 2"),
        (deck: "b", crate: "House", title: "House Fixture 3"),
        (deck: "a", crate: "Techno", title: "Techno Fixture 4"),
        (deck: "b", crate: "House", title: "House Fixture 5"),
    ]

    /// The mock catalogue's base URL, injected by the runner for the `djmix` lane.
    /// Absent for `djlive`, which hits the real API.
    ///
    /// The runner forwards it as `TEST_RUNNER_PH_TEST_JAMENDO_MOCK_URL`; a UI test
    /// does not inherit the invoking shell's environment, and reading it directly
    /// is how this silently pointed at live Jamendo. The fallback is the fixed
    /// loopback port the compose service publishes — a local address, not a
    /// credential, so naming it here breaks no rule (§54.2).
    static var mockCatalogueURL: String {
        RegressionEnv.value("PH_TEST_JAMENDO_MOCK_URL") ?? "http://127.0.0.1:18092/v3.0"
    }

    /// Does `url` answer 200? Probed synchronously, from a test that has not
    /// started yet.
    ///
    /// The completion runs on a `URLSession` queue, so the answer crosses a
    /// concurrency domain and cannot be a captured `var` — Swift 6 refuses
    /// that, correctly. It travels in a locked box instead: the `@unchecked`
    /// is the lock, not a waiver.
    static func isReachable(_ url: URL, timeout: TimeInterval = 10) -> Bool {
        final class Answer: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            var reachable: Bool {
                lock.lock(); defer { lock.unlock() }
                return value
            }
            func store(_ newValue: Bool) {
                lock.lock(); value = newValue; lock.unlock()
            }
        }
        let answer = Answer()
        let done = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            answer.store((response as? HTTPURLResponse)?.statusCode == 200)
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + timeout + 5) != .success { task.cancel() }
        return answer.reachable
    }

    /// The deterministic lane's precondition: the mock catalogue answers. It must
    /// **skip with the remedy** rather than fall through to the live API — an
    /// unstarted Docker is not a Platterhead defect (§53.4), and a lane that
    /// quietly swapped its fixtures for real music would assert nothing the tone
    /// signatures depend on.
    static func requireMockCatalogue() throws {
        guard let url = URL(string: mockCatalogueURL),
              var health = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw XCTSkip("djmix skipped — '\(mockCatalogueURL)' is not a URL.")
        }
        health.path = "/health"
        health.query = nil
        guard isReachable(health.url!) else {
            throw XCTSkip("""
                djmix skipped — the mock catalogue at \(mockCatalogueURL) did not answer. \
                Start it with `make test-ui-regression LANES=djmix` (it needs Docker), or \
                `docker compose -f docker-compose.ui-regression.yml up -d jamendo-mock`.
                """)
        }
    }
}

extension XCUIApplication {

    /// Launch configured for a DJ lane: Pro unlocked, deterministic library, and —
    /// for the deterministic lane — the mock catalogue standing in for Jamendo.
    ///
    /// `-uiRegression` is what makes the share action write the export to a known
    /// container path instead of presenting `UIActivityViewController`, which is
    /// unautomatable (§53.11). The runner then pulls it with
    /// `xcrun simctl get_app_container`.
    ///
    /// `resetLibrary` wipes the app's library state at launch — the *first* lane
    /// of a journey passes `true`, and the rest pass `false`, because the genre
    /// crates and recordings built by lane one must still be on disk for lane
    /// eight. `clientID` carries the live lane's Jamendo credential; the
    /// deterministic lane's mock accepts the placeholder.
    static func launchForDJRegression(mockCatalogue: String? = DJRegression.mockCatalogueURL,
                                      resetLibrary: Bool = true,
                                      clientID: String? = RegressionEnv.value("PH_TEST_JAMENDO_CLIENT_ID"),
                                      extraArguments: [String] = [])
        -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-uiRegression", "1",
            "UI_TESTING", "UI_TESTING_ENABLE_PRO"
        ]
        app.launchArguments += extraArguments
        if resetLibrary {
            app.launchArguments += ["-resetLibrary", "1"]
        }
        if let mockCatalogue {
            app.launchArguments += ["-jamendoBaseURL", mockCatalogue]
        }
        if let clientID, !clientID.isEmpty {
            app.launchArguments += ["-jamendoClientID", clientID]
        }
        app.launch()
        return app
    }

    /// `bar:beat` from `dj.master.bar`, or nil if the readout is absent/unparseable.
    var masterBarBeat: (bar: Int, beat: Int)? {
        let element = self.element(DJRegression.ID.bar)
        guard element.exists else { return nil }
        let parts = element.label.split(separator: ":")
        guard parts.count == 2, let bar = Int(parts[0]), let beat = Int(parts[1]) else { return nil }
        return (bar, beat)
    }

    /// Block until the master clock reaches the start of `bar`.
    ///
    /// This is the corroborating use of engine telemetry allowed by §53.8: it drives
    /// *timing*, and is never the evidence that audio happened. If the bar counter
    /// never advances, the engine is not running — which is a product failure worth
    /// reporting as itself rather than as a mysterious signature mismatch later.
    @discardableResult
    func waitForBar(_ bar: Int, timeout: TimeInterval = 120,
                    file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var lastSeen: Int?
        while Date() < deadline {
            if let current = masterBarBeat {
                lastSeen = current.bar
                if current.bar >= bar { return true }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("""
            master clock never reached bar \(bar) within \(Int(timeout))s \
            (last seen: \(lastSeen.map(String.init) ?? "no readout")). \
            If the readout never advanced at all, the render pump is not running — \
            see spec §53.11 and commit 5.4a.
            """, file: file, line: line)
        return false
    }

    /// Wait `bars` bars from **where the clock is now**.
    ///
    /// **Musical spacing has to be scheduled relatively, or it silently
    /// collapses.** A script written against absolute bar numbers assumes its
    /// gestures are instantaneous, and they are not: a bank chip, a focus swap
    /// and a verified knob drag together consume bars. Each gesture therefore
    /// eats into the gap that was meant to follow it, and once the clock has
    /// passed the next absolute mark the wait returns immediately — the
    /// transitions bunch up, each one landing inside the previous one's
    /// measurement window. The run that exposed this intended sixteen seconds
    /// between two transitions and produced six.
    ///
    /// That is not a threshold problem and cannot be fixed in the analyzer: two
    /// transitions performed on top of each other are genuinely unreadable, and
    /// a DJ does not play that way either. So every gap in the script is
    /// "`n` bars from wherever the last gesture left me".
    @discardableResult
    func waitBars(_ bars: Int, timeout: TimeInterval = 180,
                  file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let deadline = Date().addingTimeInterval(30)
        var start: Int?
        while Date() < deadline, start == nil {
            start = masterBarBeat?.bar
            if start == nil { Thread.sleep(forTimeInterval: 0.1) }
        }
        guard let start else {
            XCTFail("no master bar readout to schedule \(bars) bars from — the clock is not "
                    + "running (see §53.11 and commit 5.4a)", file: file, line: line)
            return false
        }
        return waitForBar(start + bars, timeout: timeout, file: file, line: line)
    }

    /// Wait for the next downbeat, so a cut lands on beat 1 like a DJ's would.
    func waitForNextDownbeat(timeout: TimeInterval = 30) {
        guard let start = masterBarBeat else { return }
        _ = waitForBar(start.bar + 1, timeout: timeout)
    }

    // MARK: - Deck & crate driving

    /// Open the DJ feature and land on the performance surface.
    ///
    /// The wait is on the record chip, not on `dj.master.bar`: the bar readout
    /// is honest about there being no master clock yet, so it does not exist
    /// until a deck is loaded and carries a tempo. Waiting on it here would
    /// deadlock before the first track could ever be loaded.
    func openDJDecks(timeout: TimeInterval = 60) {
        let tab = buttons["DJ"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: timeout), "DJ tab missing")
        tab.tap()
        waitFor("dj.decks").tap()
        // The workspace builds the realtime engine on appear (§34A.2, 5.4a), so
        // wait for a control that is present the moment the surface is ready.
        waitFor(DJRegression.ID.record, timeout)
        // A gated surface renders dimmed and `allowsHitTesting(false)` (§40.4):
        // every later gesture would land on nothing. Say so here instead.
        XCTAssertFalse(element(DJRegression.ID.paywallLock).exists,
                       "the decks are Pro-gated — the run's entitlement was not granted, "
                       + "so the surface is inert (launch with UI_TESTING_ENABLE_PRO)")
    }

    /// On the compact surface the non-focused deck is a strip labelled
    /// "Deck A"/"Deck B"; tapping it swaps focus (SoloDeckView §42.1).
    func focusDeck(_ deck: String, timeout: TimeInterval = 15) {
        let strip = staticTexts["Deck \(deck.uppercased())"].firstMatch
        if strip.exists {
            strip.tap()
        } else {
            _ = waitFor(DJRegression.ID.bar, timeout)
        }
    }

    /// Raise and dismiss the focused deck's crate sheet.
    func openCrate() { waitFor("dj.crate").tap() }
    func closeCrate() { waitFor("dj.crate.close").tap() }

    func addVisibleRemoteTracks(toNewPlaylist title: String) {
        waitFor("source.addToPlaylist").tap()
        // The stepper is always there; the slider only renders when the scope
        // holds more than one track, and a one-track scope is already at its max.
        waitFor("remoteAdd.count")
        let slider = element("remoteAdd.slider")
        if slider.waitForExistence(timeout: 5) {
            slider.adjust(toNormalizedSliderPosition: 1)
        }
        waitFor("remoteAdd.playlist").tap()
        buttons["Create a new playlist…"].tap()
        let name = waitFor("remoteAdd.name")
        name.tap(); name.typeText(title)
        waitFor("remoteAdd.confirm").tap()
        waitForLabelContaining("remoteAdd.result", "added", timeout: 300)
        buttons["Close"].tap()
    }

    func importCrate(_ playlist: String, into deck: String) {
        let code = deck.lowercased()
        waitFor("dj.crate.import.\(code)").tap()
        waitFor("dj.crate.picker.expand.\(playlist)").tap()
        waitFor("dj.crate.picker.row.\(playlist)").tap()
        waitFor("dj.crate.picker.confirm").tap()
    }

    /// Pick a queue source in the crate sheet's picker (FR-ENG-13).
    ///
    /// The picker is a system `Menu`, and a presented menu does not survive
    /// arbitrary waiting while the surface behind it re-renders at telemetry
    /// cadence. So this opens and selects as one movement and re-opens if the
    /// menu went away, rather than opening once and then waiting on an item —
    /// that pattern reads as "the crate is missing" when the menu simply closed.
    func selectQueue(_ deck: String, title: String, attempts: Int = 4,
                     file: StaticString = #filePath, line: UInt = #line) {
        for attempt in 0..<attempts {
            waitFor("dj.deck.\(deck).queue").tap()
            let option = element("dj.queue.\(title)")
            if option.waitForExistence(timeout: 3) {
                option.tap()
                return
            }
            if attempt < attempts - 1 { Thread.sleep(forTimeInterval: 0.5) }
        }
        XCTFail("queue '\(title)' never appeared in deck \(deck)'s picker over "
                + "\(attempts) attempts — the crate was not built, or the picker "
                + "will not stay open", file: file, line: line)
    }

    /// Assert a set of crates is selectable on one deck, each holding the rows
    /// it should. Selection is the assertion: an option that can be chosen and
    /// yields its own tracks is what "a crate is a deck queue" means, and it
    /// survives the menu closing between checks.
    func assertQueues(_ deck: String, _ expected: [String: [String]],
                      file: StaticString = #filePath, line: UInt = #line) {
        for (title, rows) in expected.sorted(by: { $0.key < $1.key }) {
            selectQueue(deck, title: title, file: file, line: line)
            for row in rows {
                XCTAssertTrue(queueRowExists(row),
                              "crate '\(title)' is missing '\(row)'", file: file, line: line)
            }
        }
    }

    /// Whether a queue row is present, scrolling the crate list if it is not.
    /// The rows are a `LazyVStack`: one further down the crate has no element
    /// until it is scrolled near, so "not found" without scrolling would read as
    /// a missing track when the crate is complete.
    ///
    /// **The sweep goes both ways**, for the reason `loadTrack` already does
    /// (alpha phase 2): swiping up only is unbounded in one direction, so it
    /// runs off the end of the list and stays there. That matters here because
    /// `assertQueues` calls this repeatedly across crates — it scrolls down to
    /// find "Techno Fixture 6", then selects the House crate and looks for
    /// "House Fixture 1", which is *above* wherever the list was left. A row
    /// that exists and is simply out of view then reads as a missing track, and
    /// the failure names the crate rather than the scroll — which is what
    /// AT-MIX-01 does when it fails and why run 3's cause could not be read off
    /// the message.
    @discardableResult
    func queueRowExists(_ title: String, scrolls: Int = 4) -> Bool {
        let row = element("dj.queue.row.\(title)")
        if row.waitForExistence(timeout: 5) { return true }
        let list = scrollViews.firstMatch
        for _ in 0..<scrolls {
            list.swipeUp()
            if row.waitForExistence(timeout: 2) { return true }
        }
        for _ in 0..<(scrolls * 2) {
            list.swipeDown()
            if row.waitForExistence(timeout: 2) { return true }
        }
        return false
    }

    /// Tap a queue row to load it to the focused deck (FR-LIB-8).
    ///
    /// **Waits for hittability, not existence.** Asserting existence and then
    /// tapping is what produced `dj.queue.row.<title>` *"not hittable"* on two of
    /// three hand runs: `queueRowExists` scrolls only until the row *exists*, and
    /// a `LazyVStack` row can exist while its hit point is still occluded by the
    /// sheet's edge. There is a **second, entirely different route to the same
    /// message** — `rowView` is `.disabled(!isReady)` (`SoloDeckView`,
    /// `WorkspaceView`), and a disabled button never becomes hittable no matter
    /// how far the list is scrolled. That one is the FR-LIB-8 deck-readiness gate
    /// still caching the track, and it resolves by *waiting*, not by scrolling.
    ///
    /// So: poll for enabled-and-hittable, scroll only while the row is missing or
    /// unreachable, and on timeout say **which** of the two it was. The old
    /// message named neither, which is why the run-1 failure could not be acted
    /// on without re-running the lane by hand.
    func loadTrack(title: String, timeout: TimeInterval = 15, scrolls: Int = 4,
                   file: StaticString = #filePath, line: UInt = #line) {
        let row = element("dj.queue.row.\(title)")
        let deadline = Date().addingTimeInterval(timeout)
        var upward = scrolls
        var downward = 2

        while Date() < deadline {
            if row.exists, row.isEnabled, row.isHittable {
                row.tap()
                return
            }

            // Present but disabled: the readiness gate has not passed it yet.
            // Caching finishes on its own, so poll — scrolling a disabled row
            // around the sheet cannot make it tappable and only burns the budget.
            if row.exists, !row.isEnabled {
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }

            // Missing, or present and unreachable: a scroll problem. Walk down
            // the crate first, then back up — a bounded sweep, because a row can
            // sit under either edge and an unbounded swipe in one direction runs
            // off the end of the list and stays there.
            let list = scrollViews.firstMatch
            if list.exists, upward > 0 {
                list.swipeUp()
                upward -= 1
            } else if list.exists, downward > 0 {
                list.swipeDown()
                downward -= 1
            } else {
                Thread.sleep(forTimeInterval: 0.5)
            }
        }

        XCTFail("queue row '\(title)' never became tappable within \(Int(timeout))s — "
                + queueRowDiagnosis(title), file: file, line: line)
    }

    /// Why a queue row could not be tapped, in the app's own words.
    ///
    /// Read only on failure. The three outcomes need three different fixes and
    /// `not hittable` distinguishes none of them: a missing row is a crate that
    /// was never built, a disabled row is FR-LIB-8 still caching, and an enabled
    /// unreachable row is the scroll/occlusion case the sweep above failed to
    /// solve. The row's own label carries `WorkspaceModel.unavailableReason`, so
    /// the disabled case can report the reason the user would have read.
    private func queueRowDiagnosis(_ title: String) -> String {
        let row = element("dj.queue.row.\(title)")
        guard row.exists else {
            return "the row does not exist. Either the crate does not hold this "
                 + "track, or the list never scrolled far enough to materialise it"
        }
        guard row.isEnabled else {
            let words = row.label.isEmpty ? "<no label>" : "\"\(row.label)\""
            return "the row exists but is DISABLED — the FR-LIB-8 deck-readiness "
                 + "gate has not passed it (`.disabled(!isReady)`), so it can never "
                 + "be hittable. This is a caching/analysis wait, not a scroll "
                 + "problem. The row's own words: \(words)"
        }
        return "the row exists and is enabled but never became hittable — it is "
             + "occluded or outside the window at frame \(row.frame)"
    }

    /// Wait until an element's label contains a substring (state transitions
    /// published through accessibility values).
    @discardableResult
    func waitForLabelContaining(_ identifier: String, _ substring: String,
                                timeout: TimeInterval = 120,
                                file: StaticString = #filePath,
                                line: UInt = #line) -> XCUIElement {
        let element = element(identifier)
        let predicate = NSPredicate(format: "label CONTAINS %@", substring)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let outcome = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(outcome, .completed,
                       "element '\(identifier)' never showed '\(substring)' within \(Int(timeout))s",
                       file: file, line: line)
        return element
    }

    // MARK: - Gestures (mixer)

    /// A performance control's published position (§53.11), or nil when the
    /// control is absent or exposes no value.
    func controlValue(_ identifier: String) -> Float? {
        let control = element(identifier)
        guard control.exists, let text = control.value as? String else { return nil }
        return Float(text)
    }

    /// Tap a compact bank chip ("EQ", "Filter", "Fader", …) by its label, and
    /// confirm the bank it raises actually carries `expects`.
    ///
    /// The banks share one slot on the compact surface and the selection is per
    /// deck, so "open EQ" after a focus swap can leave the previous deck's bank
    /// showing. Checking here means a missing knob is reported as the wrong bank
    /// rather than as a transition that mysteriously did not happen.
    func openBank(_ name: String, expects identifier: String? = nil,
                  file: StaticString = #filePath, line: UInt = #line) {
        let chip = buttons[name].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "bank chip '\(name)' missing",
                      file: file, line: line)
        chip.tap()
        if let identifier {
            XCTAssertTrue(element(identifier).waitForExistence(timeout: 10),
                          "the '\(name)' bank did not raise '\(identifier)'",
                          file: file, line: line)
        }
    }

    /// Drag a knob to a target position and **prove it landed there**.
    ///
    /// The EQ knobs are relative: `translation.height / 60` off the value at
    /// touch-down (§35.2), so this reads the published value, drags the
    /// difference, and repeats. The assertion is the point — a synthesised drag
    /// on a control that is present but covered does nothing at all, and
    /// without this the run continues happily and produces a recording with a
    /// transition missing from it.
    @discardableResult
    func setKnob(_ identifier: String, to target: Float, tolerance: Float = 0.06,
                 attempts: Int = 5, settle: TimeInterval = 0.25,
                 file: StaticString = #filePath, line: UInt = #line) -> Float? {
        let knob = waitFor(identifier)
        for _ in 0..<attempts {
            guard let current = controlValue(identifier) else { break }
            if abs(current - target) <= tolerance { return current }
            // Positive dy drags down, toward kill.
            let dy = CGFloat((current - target) * 60)
            let centre = knob.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            centre.press(forDuration: 0.01,
                         thenDragTo: centre.withOffset(CGVector(dx: 0, dy: dy)))
            Thread.sleep(forTimeInterval: settle)
        }
        let reached = controlValue(identifier)
        XCTAssertNotNil(reached, "control '\(identifier)' publishes no value", file: file, line: line)
        if let reached {
            XCTAssertLessThanOrEqual(abs(reached - target), tolerance,
                                     "'\(identifier)' never reached \(target) — it sits at "
                                     + "\(reached). The control is present but the gesture is not "
                                     + "reaching it (covered, or on a bank that is not showing).",
                                     file: file, line: line)
        }
        return reached
    }

    /// Kill an EQ band — all the way down, which is what a bass swap hands over.
    func killEQBand(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        setKnob(identifier, to: -1, file: file, line: line)
    }

    /// Restore an EQ band to unity.
    func restoreEQBand(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        setKnob(identifier, to: 0, file: file, line: line)
    }

    /// Sweep an absolute vertical control (the sweep filter −1…1, a channel
    /// fader 0…1) to `target` as **one continuous drag**, then assert where it
    /// landed.
    ///
    /// One drag, not a series of taps: the engine's smoothing is what keeps a
    /// fader move from zippering — lane 4 asserts that zipper's absence — and
    /// the app reads a transition from the whole movement, so a control walked
    /// down in separate touches is not a fader cut, it is eight small moves.
    /// The verification is the other half: a synthesised gesture on a control
    /// that is covered does nothing at all, silently.
    @discardableResult
    func sweepSlider(_ identifier: String, to target: Float,
                     range: ClosedRange<Float> = -1...1,
                     stages: Int = 1,
                     tolerance: Float = 0.06, attempts: Int = 3,
                     velocity: XCUIGestureVelocity = .slow,
                     settle: TimeInterval = 0.3,
                     file: StaticString = #filePath, line: UInt = #line) -> Float? {
        let control = waitFor(identifier)
        func offset(_ value: Float) -> CGVector {
            let unit = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            return CGVector(dx: 0.5, dy: max(0.004, min(0.996, 1.0 - CGFloat(unit))))
        }
        // `stages` spreads the move over that many drags, for a control a DJ
        // works over bars rather than in one flick — a filter transition swept
        // in a tenth of a second is a jump cut, and nothing measuring the sweep
        // as a movement can see it.
        if stages > 1 {
            let from = controlValue(identifier) ?? range.lowerBound
            for stage in 1..<stages {
                let value = from + (target - from) * Float(stage) / Float(stages)
                control.coordinate(withNormalizedOffset: offset(controlValue(identifier) ?? from))
                    .press(forDuration: 0.05,
                           thenDragTo: control.coordinate(withNormalizedOffset: offset(value)),
                           withVelocity: velocity,
                           thenHoldForDuration: 0.1)
                Thread.sleep(forTimeInterval: settle)
            }
        }
        for _ in 0..<attempts {
            let current = controlValue(identifier) ?? range.lowerBound
            if abs(current - target) <= tolerance { break }
            control.coordinate(withNormalizedOffset: offset(current))
                .press(forDuration: 0.05,
                       thenDragTo: control.coordinate(withNormalizedOffset: offset(target)),
                       withVelocity: velocity,
                       thenHoldForDuration: 0.1)
            Thread.sleep(forTimeInterval: settle)
        }
        let reached = controlValue(identifier)
        XCTAssertNotNil(reached, "control '\(identifier)' publishes no value", file: file, line: line)
        if let reached {
            XCTAssertLessThanOrEqual(abs(reached - target), tolerance,
                                     "'\(identifier)' never reached \(target) — it sits at "
                                     + "\(reached). The control is present but the gesture is "
                                     + "not reaching it (covered, or on a bank not showing).",
                                     file: file, line: line)
        }
        return reached
    }

    /// Sweep the master crossfader to a position in −1…1 (−1 = deck A alone,
    /// +1 = deck B alone) as one continuous drag, and assert it arrived.
    @discardableResult
    func sweepCrossfader(to target: Float, tolerance: Float = 0.08, attempts: Int = 3,
                         velocity: XCUIGestureVelocity = .slow,
                         settle: TimeInterval = 0.3,
                         file: StaticString = #filePath, line: UInt = #line) -> Float? {
        let strip = waitFor(DJRegression.ID.crossfader)
        func offset(_ value: Float) -> CGVector {
            CGVector(dx: max(0.004, min(0.996, CGFloat((value + 1) / 2))), dy: 0.5)
        }
        for _ in 0..<attempts {
            let current = controlValue(DJRegression.ID.crossfader) ?? 0
            if abs(current - target) <= tolerance { break }
            strip.coordinate(withNormalizedOffset: offset(current))
                .press(forDuration: 0.05,
                       thenDragTo: strip.coordinate(withNormalizedOffset: offset(target)),
                       withVelocity: velocity,
                       thenHoldForDuration: 0.1)
            Thread.sleep(forTimeInterval: settle)
        }
        let reached = controlValue(DJRegression.ID.crossfader)
        XCTAssertNotNil(reached, "the crossfader publishes no value", file: file, line: line)
        if let reached {
            XCTAssertLessThanOrEqual(abs(reached - target), tolerance,
                                     "the crossfader never reached \(target) — it sits at "
                                     + "\(reached).", file: file, line: line)
        }
        return reached
    }

    /// The recording's own elapsed time, read off the record chip ("Stop · 3:12").
    /// nil when not recording.
    var recordingElapsedSeconds: Double? {
        let chip = element(DJRegression.ID.record)
        guard chip.exists else { return nil }
        let parts = chip.label.split(separator: "·").last?
            .trimmingCharacters(in: .whitespaces).split(separator: ":") ?? []
        guard parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) else {
            return nil
        }
        return minutes * 60 + seconds
    }

    /// Tap the record chip and **prove the recording started** — the chip flips
    /// from "REC" to a running "Stop · M:SS" and the timer moves.
    ///
    /// Everything the analyzer later measures depends on this one tap having
    /// taken. A lane that assumed it did would perform five perfect transitions
    /// into nothing and only discover it at finalize, twenty minutes later, as
    /// "no recorded mix to review" — a failure that names the wrong step.
    func startRecording(timeout: TimeInterval = 15,
                        file: StaticString = #filePath, line: UInt = #line) {
        waitFor(DJRegression.ID.record).tap()
        let deadline = Date().addingTimeInterval(timeout)
        var first: Double?
        while Date() < deadline {
            if let now = recordingElapsedSeconds {
                if let first, now > first { return }
                if first == nil { first = now }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("the record chip never showed a running timer within \(Int(timeout))s — it reads "
                + "'\(element(DJRegression.ID.record).label)'. The recording did not start, so "
                + "there is nothing for the rest of this lane to record into.",
                file: file, line: line)
    }

    /// Hold the mix running to the end of the script: at least `bars` more
    /// bars, and at least `MIX_MINUTES` **of recording**, with the decks
    /// playing. Relative, like every other gap in the script (`waitBars`).
    ///
    /// The five transitions take about two minutes; the rest of the length is a
    /// **soak**, and a soak that plays silence proves nothing about memory,
    /// thermals, or a recording that has to survive twenty minutes. So this
    /// loads the next track from a deck's own crate before its current one runs
    /// out and plays it — which is what a DJ does, and it keeps both decks
    /// producing audio for the whole recording.
    ///
    /// **Recording time and wall time are not the same quantity, and mixing
    /// them was a bug that misdiagnosed three runs in a row.** `MIX_MINUTES` is
    /// a length of recording; the loop used to convert it straight into a
    /// wall-clock deadline, which is only correct if the graph renders in real
    /// time. It does not always: an unoptimised build renders as fast as the
    /// CPU allows, and the run that exposed this produced 200s of mix in 600s
    /// of wall clock — whereupon the assertion blamed decks that had never run
    /// dry. So: **the target is recording seconds**, the wall clock is only a
    /// cap that stops a wedged run from hanging forever, and a shortfall
    /// reports the observed render rate so the next failure describes itself.
    ///
    /// Rotation is likewise on recording time — track length is a property of
    /// the material, not of the host. The stall guard stays on the wall clock,
    /// because a stalled recording cannot advance its own rotation timer.
    /// `decksPlayingFor` is how much of the loaded tracks has **already been
    /// consumed** when the hold begins. It exists because rotation used to start
    /// its clock at the moment `holdMix` was entered, as though the decks had
    /// just been loaded — and in the lane that matters they had been playing for
    /// four minutes of a five-and-a-half-minute fixture. The first rotation was
    /// therefore scheduled for six seconds *after* both decks ran dry, and every
    /// recording ended with twenty seconds of digital silence. Reactive fixes
    /// cannot close that: rotating a deck takes ten to twenty seconds of UI work,
    /// so a hole noticed at the end is a hole that is already in the file. The
    /// caller knows this number; passing it makes the first rotation land while
    /// there is still material to mix out of.
    @discardableResult
    func holdMix(forBars bars: Int,
                 rotation: [(deck: String, crate: String, title: String)] = DJRegression.rotation,
                 trackSeconds: Double = 120,
                 decksPlayingFor: TimeInterval = 0,
                 stallSeconds: Double = 8,
                 engineDeadSeconds: Double = 20,
                 wallCapFactor: Double = 5,
                 file: StaticString = #filePath, line: UInt = #line) -> Bool {
        _ = waitBars(bars, file: file, line: line)
        let target = DJRegression.mixMinutes * 60
        let started = Date()
        let alreadyRecorded = recordingElapsedSeconds ?? 0
        let wallCap = started.addingTimeInterval(max(60, (target - alreadyRecorded) * wallCapFactor))
        var next = 0
        // Per deck, because the decks run out independently: one shared timer
        // refreshes one deck and leaves the other to die on schedule.
        var lastRotationFor: [String: Double] = ["a": alreadyRecorded - decksPlayingFor,
                                                 "b": alreadyRecorded - decksPlayingFor]
        var lastElapsed = alreadyRecorded
        var lastAdvance = Date()
        var lastBar = masterBarBeat
        var lastBarAdvance = Date()

        func rotateNext(preferring deck: String? = nil) {
            guard !rotation.isEmpty else { return }
            // Wraps: a twenty-minute soak outlasts the list, and a deck with
            // nothing left to load is a deck that stops — which is the state
            // this loop exists to prevent. Replaying a track later in a long
            // set is what a DJ does anyway.
            //
            // `preferring` is for the silence case below: the deck that went
            // quiet is the one that needs a track, and taking the list's next
            // entry regardless would load the *other* deck and leave the silent
            // one silent. The list alternates decks, so this steps at most once.
            if let wanted = deck {
                for offset in 0..<rotation.count where rotation[(next + offset) % rotation.count].deck == wanted {
                    next += offset
                    break
                }
            }
            let step = rotation[next % rotation.count]
            next += 1
            lastRotationFor[step.deck] = recordingElapsedSeconds ?? lastElapsed
            focusDeck(step.deck)
            openCrate()
            selectQueue(step.deck, title: step.crate)
            loadTrack(title: step.title)
            closeCrate()
            ensurePlaying(step.deck)
        }

        while lastElapsed < target, Date() < wallCap {
            let elapsed = recordingElapsedSeconds ?? lastElapsed
            if elapsed > lastElapsed {
                lastElapsed = elapsed
                lastAdvance = Date()
            }
            if let bar = masterBarBeat,
               lastBar == nil || bar != lastBar! {
                lastBar = bar
                lastBarAdvance = Date()
            }

            // **A frozen master clock is not a dry deck, and no rotation can
            // fix it.** The clock advances once per render callback, so it
            // stops only when the graph stops being pulled at all — and a deck
            // that is not being rendered cannot be started by tapping play.
            // The previous loop could not tell the two apart, read a dead
            // engine as "load another track", and spent fourteen minutes
            // hammering the crate sheet before failing on an unrelated tap.
            // Distinguish them here and say which one it is.
            if Date().timeIntervalSince(lastBarAdvance) >= engineDeadSeconds {
                XCTFail("""
                    the master clock has been frozen at bar \
                    \(lastBar.map { "\($0.bar):\($0.beat)" } ?? "no readout") for \
                    \(Int(engineDeadSeconds))s with \(Int(lastElapsed))s recorded. The clock \
                    advances once per render callback, so this is not a deck that ran out of \
                    material — the audio graph has stopped being rendered and no gesture can \
                    restart it. On a laptop the usual cause is the host sleeping mid-run \
                    (Core Audio stops IO, and the simulator's transport ends with it); the \
                    runner takes a caffeinate assertion, which a clamshell close on battery \
                    still defeats. Check the app's Core Audio log around the freeze for \
                    "ending the transport, stopping the io thread".
                    """, file: file, line: line)
                return false
            }

            // **Rotation is per deck, and it has to be ahead of the music.**
            //
            // A deck whose track has been playing for `trackSeconds` gets the
            // next one, counted from when *that deck* was last loaded — which
            // `decksPlayingFor` seeds, because the decks have usually been
            // playing since long before the hold began. One shared timer started
            // at the hold refreshes one deck and lets the other run dry on
            // schedule, which is exactly what happened: every djmix recording
            // ended with twenty seconds of digital silence.
            //
            // The silence check below is the safety net, not the mechanism. It
            // cannot be the mechanism: a rotation costs ten to twenty seconds of
            // UI work, so a hole noticed after the fact is already in the file.
            // It is still worth having — a deck that stops early for a reason
            // nobody predicted gets a track rather than a silent tail.
            let silent = deckIsPlaying("a") == false && deckIsPlaying("b") == false
            let stalled = Date().timeIntervalSince(lastAdvance) >= stallSeconds
            let dueDeck = ["a", "b"].first { deck in
                lastElapsed - (lastRotationFor[deck] ?? alreadyRecorded) >= trackSeconds
            }
            if silent {
                // Whichever deck is quiet gets the track. If both are, this
                // brings in one now and the next pass brings in the other.
                rotateNext(preferring: deckIsPlaying("a") == false ? "a" : "b")
            } else if let dueDeck {
                rotateNext(preferring: dueDeck)
            } else if stalled {
                rotateNext()
                lastAdvance = Date()
            }
            Thread.sleep(forTimeInterval: 2)
        }

        // The recording has to have actually captured the soak. Report the
        // render rate with the shortfall: the clock-freeze case has already
        // failed above, so what is left here is a graph that kept rendering but
        // could not keep up — an unoptimised build, thermals, or a loaded host.
        let recorded = recordingElapsedSeconds ?? 0
        let wall = Date().timeIntervalSince(started)
        let rate = wall > 0 ? (recorded - alreadyRecorded) / wall : 0
        XCTAssertGreaterThan(recorded, target * 0.8,
                             "the recording reached only \(Int(recorded))s of the \(Int(target))s "
                             + "asked for, in \(Int(wall))s of wall clock "
                             + String(format: "(render rate %.2f×). ", rate)
                             + "The master clock kept running throughout — the graph is rendering, "
                             + "just slower than real time, so the hold hit its wall cap. Check the "
                             + "build configuration first (Release is required; Debug renders at "
                             + "about a third of real time), then host load.",
                             file: file, line: line)
        return true
    }

    /// Whether a deck is playing, read off its own transport button.
    ///
    /// The button is a toggle that titles itself with the action it offers, so
    /// the label is the *inverse* of the state: "PAUSE" is shown by a deck that
    /// is playing (`SoloDeckView`/`TwinDeckView`, `telemetryDeck.playing ?
    /// "PAUSE" : "PLAY"`). nil when the button is not on screen. This is the
    /// one per-deck signal in the tree — the master clock is shared, so it says
    /// only that *something* is playing.
    func deckIsPlaying(_ deck: String) -> Bool? {
        let play = element(DJRegression.ID.play(deck))
        guard play.exists else { return nil }
        switch play.label.uppercased() {
        case "PAUSE": return true
        case "PLAY": return false
        default: return nil
        }
    }

    /// Start a deck if it is not already playing, and prove *that deck* started.
    ///
    /// PLAY is a toggle, so a blind tap on a deck that never stopped **pauses
    /// it** — and a rotation that pauses the deck it just loaded is how a soak
    /// ends up recording silence. The previous version tapped unconditionally
    /// and then watched the master clock, which is the wrong instrument twice
    /// over: the clock is shared, so the *other* deck's audio satisfied the
    /// check while this one sat paused, and the pause went unnoticed for the
    /// rest of the run. So: read this deck's own button, tap only when it says
    /// PLAY, and confirm it flipped to PAUSE.
    ///
    /// The clock is still the fallback for a surface that does not title its
    /// transport, but it is no longer the primary — and it is never a licence
    /// to tap a control whose state was already right.
    func ensurePlaying(_ deck: String, attempts: Int = 3, settle: TimeInterval = 5,
                       file: StaticString = #filePath, line: UInt = #line) {
        let play = element(DJRegression.ID.play(deck))
        guard play.exists else { return }
        for _ in 0..<attempts {
            switch deckIsPlaying(deck) {
            case .some(true):
                return
            case .some(false):
                play.tap()
                let deadline = Date().addingTimeInterval(settle)
                while Date() < deadline {
                    if deckIsPlaying(deck) == true { return }
                    Thread.sleep(forTimeInterval: 0.3)
                }
            case nil:
                // No titled transport on this surface: fall back to the clock,
                // which at least distinguishes "something is rendering" from a
                // dead graph.
                let before = masterBarBeat
                play.tap()
                let deadline = Date().addingTimeInterval(settle)
                while Date() < deadline {
                    if let now = masterBarBeat, before == nil || now != before! { return }
                    Thread.sleep(forTimeInterval: 0.3)
                }
            }
        }
        XCTFail("deck \(deck.uppercased()) would not start: its transport still reads "
                + "'\(play.label)' after \(attempts) attempts. A deck that will not play "
                + "records silence, and every band measurement downstream is then a "
                + "measurement of nothing.", file: file, line: line)
    }

    /// Press play on a deck and wait until the master clock has advanced —
    /// the honest "this deck decoded and is rendering" signal (§53.8). The
    /// decode can lag the tap, so play is re-pressed if the clock is still idle.
    @discardableResult
    func playDeck(_ deck: String, waitForClock: Bool = true, timeout: TimeInterval = 60) -> Bool {
        let play = waitFor(DJRegression.ID.play(deck))
        play.tap()
        guard waitForClock else { return true }
        let start = Date()
        var retries = 0
        while Date().timeIntervalSince(start) < timeout {
            if masterBarBeat?.bar ?? 0 >= 1 { return true }
            if retries < 3, Date().timeIntervalSince(start) > Double(retries + 1) * 8 {
                play.tap()
                retries += 1
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("deck \(deck) never started the master clock within \(Int(timeout))s — "
                + "the track did not decode/load (FR-LIB-8).")
        return false
    }
}
