import Testing

@testable import TonearmCore

/// Issue #80 hermetic production-flow / render / accessibility / lease regression tests.
/// Run with `make tonearm-production-regression`; `swift test` alone is not accepted as evidence.
@MainActor
@Suite struct ProductionRegressionTests {
    private func assertBaseline(_ screen: String, _ state: String, _ rendered: String,
                                config: HarnessConfiguration = .current(),
                                sourceLocation: SourceLocation = #_sourceLocation) {
        switch BaselineComparator.compare(screen: screen, state: state, rendered: rendered, config: config) {
        case .match, .recorded: break
        case .mismatch(let message, _, _), .missing(let message): Issue.record(message, sourceLocation: sourceLocation)
        }
    }

    private func flow(adapter: RecordingPlayerAdapter, drop: Bool = false) -> QueueFlow {
        QueueFlow(queue: FixtureCatalog.tracks.map(\.id), current: 1, adapter: adapter, dropAdapterCalls: drop)
    }

    // MARK: production navigation/action + adapter calls

    @Test func testQueueActionsReachPlayerAdapter() {
        let adapter = RecordingPlayerAdapter()
        var f = flow(adapter: adapter)
        f.tapRow(2)
        f.remove(at: 0)
        f.move(from: 2, to: 0)
        #expect(adapter.calls == [
            "play(3)",
            "syncQueue([2, 3, 4],current:1)",
            "syncQueue([4, 2, 3],current:2)"
        ], "[queue/actions] player adapter calls differ")
    }

    @Test func testHarnessDetectsRemovedAdapterCall() {
        let good = RecordingPlayerAdapter(), bad = RecordingPlayerAdapter()
        var g = flow(adapter: good), b = flow(adapter: bad, drop: true)
        g.tapRow(2); b.tapRow(2)
        #expect(good.calls == ["play(3)"])
        #expect(bad.calls != good.calls, "harness must notice a removed production adapter call")
        #expect(bad.calls.isEmpty)
    }

    // MARK: deterministic render / baseline

    @Test func testQueueRenderMatchesBaseline() {
        let f = flow(adapter: RecordingPlayerAdapter())
        assertBaseline("queue", "initial", ScreenRenderer.queue(f.state, config: .current()))
    }

    @Test func testQueueAfterRemoveRenderMatchesBaseline() {
        var f = flow(adapter: RecordingPlayerAdapter())
        f.remove(at: 0)
        assertBaseline("queue", "after-remove", ScreenRenderer.queue(f.state, config: .current()))
    }

    @Test func testHarnessDetectsChangedBaselineAndCapturesArtifacts() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("harness-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var config = HarnessConfiguration.current()
        config.record = false
        config.artifactDirectory = tmp
        let f = flow(adapter: RecordingPlayerAdapter())
        let rendered = ScreenRenderer.queue(f.state, config: config)
        let tampered = rendered.replacingOccurrences(of: "Alpha", with: "Alpha (changed)")
        guard case .mismatch(let message, let actual, let diff) =
            BaselineComparator.compare(screen: "queue", state: "initial", rendered: tampered, config: config)
        else {
            Issue.record("changed render must not match baseline")
            return
        }
        #expect(message.contains("[queue/initial]"))
        #expect(FileManager.default.fileExists(atPath: actual.path))
        #expect(try String(contentsOf: diff, encoding: .utf8).contains("Alpha (changed)"))
    }

    @Test func testRenderIsDeterministicAcrossRuns() {
        let config = HarnessConfiguration.current()
        let renders = (0..<2).map { _ -> String in
            var f = flow(adapter: RecordingPlayerAdapter())
            f.move(from: 3, to: 0)
            return ScreenRenderer.queue(f.state, config: config)
        }
        #expect(renders[0] == renders[1])
    }

    @Test func testLaunchConfigurationInjection() {
        let c = HarnessConfiguration.current(
            environment: ["TONEARM_HARNESS_COLORSCHEME": "dark", "TONEARM_HARNESS_BASELINEDIR": "/tmp/b"],
            arguments: ["x", "-TonearmHarnessAccessibilityCategory", "accessibility-xxxl", "-TonearmHarnessReduceMotion", "1"])
        #expect(c.colorScheme == "dark")
        #expect(c.accessibilityCategory == "accessibility-xxxl")
        #expect(c.reduceMotion)
        #expect(c.baselineDirectory.path == "/tmp/b")
    }

    // MARK: accessibility

    @Test func testQueueAccessibilityElementsAndActions() {
        let f = flow(adapter: RecordingPlayerAdapter())
        let rendered = ScreenRenderer.queue(f.state, config: .current())
        #expect(rendered.contains("value=\"Now playing, 1 minute, 1 second\""), "[queue/a11y] current row value")
        #expect(rendered.contains("hint=\"Plays this track now\""))
        #expect(QueueAccessibility.minimumTargetSide >= 44)
        #expect(QueueAccessibility.removeActionName == "Remove from queue")
    }

}
