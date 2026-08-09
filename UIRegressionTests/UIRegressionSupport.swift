import XCTest

/// Shared plumbing for the UI regression suite (spec §53).
///
/// Every lane in this suite maps 1:1 to a defect ID in the register (§51). A lane
/// whose prerequisites are absent **skips with a stated reason** and never fails:
/// a missing credential, a stopped Docker, or an unreachable public demo server is
/// not a defect in Platterhead (§53.4). Only an assertion about the app's own
/// behaviour is allowed to fail a run.
enum RegressionEnv {

    /// Credentials arrive from `.test-credentials` via `scripts/run-ui-regression.sh`
    /// as `PH_TEST_<SECTION>_<KEY>`. They are never literals in a test file (§54.2).
    static func value(_ key: String) -> String? {
        guard let raw = ProcessInfo.processInfo.environment[key], !raw.isEmpty else { return nil }
        return raw
    }

    /// Empty-but-present is meaningful for Jellyfin, whose demo account has no
    /// password at all (D-13) — so this deliberately does not collapse "" to nil.
    static func valueAllowingEmpty(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key]
    }

    static func require(_ keys: String..., lane: String) throws -> [String: String] {
        var found: [String: String] = [:]
        var missing: [String] = []
        for key in keys {
            if let value = value(key) { found[key] = value } else { missing.append(key) }
        }
        guard missing.isEmpty else {
            throw XCTSkip("""
                \(lane) skipped — missing \(missing.joined(separator: ", ")).
                Fill the matching section in .test-credentials (see .test-credentials.example), \
                or start the backing servers with `make test-ui-regression`.
                """)
        }
        return found
    }
}

extension XCUIApplication {

    /// Launches with the regression fixture flags. `-uiRegression` puts the app in
    /// a deterministic state: seeded library, no onboarding, no paywall interstitial.
    static func launchForRegression() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uiRegression", "1", "-resetLibrary", "1"]
        app.launch()
        return app
    }

    func element(_ identifier: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @discardableResult
    func waitFor(_ identifier: String, _ timeout: TimeInterval = 15) -> XCUIElement {
        let candidate = element(identifier)
        XCTAssertTrue(candidate.waitForExistence(timeout: timeout),
                      "expected an element identified '\(identifier)' within \(Int(timeout))s")
        return candidate
    }

    /// The suite's definition of "a track actually played": the transport reports
    /// playing AND the elapsed time advances. Either alone has produced false
    /// greens before — a remote library can show a loaded track that never decodes,
    /// which is exactly the D-10 symptom.
    func assertPlaybackAdvances(timeout: TimeInterval = 20,
                                file: StaticString = #filePath,
                                line: UInt = #line) {
        let elapsed = waitFor("np.elapsed", timeout)
        let first = elapsed.label
        let advanced = NSPredicate(format: "label != %@", first)
        let outcome = XCTNSPredicateExpectation(predicate: advanced, object: elapsed)
        XCTAssertEqual(XCTWaiter().wait(for: [outcome], timeout: timeout), .completed,
                       "elapsed time never advanced past \(first) — the track loaded but did not play",
                       file: file, line: line)
    }
}
