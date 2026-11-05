import XCTest

@testable import TonearmCore

/// Issue #80 hermetic production-flow / render / accessibility / lease regression tests.
/// Run with `make tonearm-production-regression`; `swift test` alone is not accepted as evidence.
@MainActor
final class ProductionRegressionTests: XCTestCase {
    private func assertBaseline(_ screen: String, _ state: String, _ rendered: String,
                                config: HarnessConfiguration = .current(),
                                file: StaticString = #filePath, line: UInt = #line) {
        switch BaselineComparator.compare(screen: screen, state: state, rendered: rendered, config: config) {
        case .match, .recorded: break
        case .mismatch(let message, _, _), .missing(let message): XCTFail(message, file: file, line: line)
        }
    }

    private func flow(adapter: RecordingPlayerAdapter, drop: Bool = false) -> QueueFlow {
        QueueFlow(queue: FixtureCatalog.tracks.map(\.id), current: 1, adapter: adapter, dropAdapterCalls: drop)
    }

    // MARK: production navigation/action + adapter calls

    func testQueueActionsReachPlayerAdapter() {
        let adapter = RecordingPlayerAdapter()
        var f = flow(adapter: adapter)
        f.tapRow(2)
        f.remove(at: 0)
        f.move(from: 2, to: 0)
        XCTAssertEqual(adapter.calls, [
            "play(3)",
            "syncQueue([2, 3, 4],current:1)",
            "syncQueue([4, 2, 3],current:2)"
        ], "[queue/actions] player adapter calls differ")
    }

    func testHarnessDetectsRemovedAdapterCall() {
        let good = RecordingPlayerAdapter(), bad = RecordingPlayerAdapter()
        var g = flow(adapter: good), b = flow(adapter: bad, drop: true)
        g.tapRow(2); b.tapRow(2)
        XCTAssertEqual(good.calls, ["play(3)"])
        XCTAssertNotEqual(bad.calls, good.calls, "harness must notice a removed production adapter call")
        XCTAssertTrue(bad.calls.isEmpty)
    }

    // MARK: deterministic render / baseline

    func testQueueRenderMatchesBaseline() {
        let f = flow(adapter: RecordingPlayerAdapter())
        assertBaseline("queue", "initial", ScreenRenderer.queue(f.state, config: .current()))
    }

    func testQueueAfterRemoveRenderMatchesBaseline() {
        var f = flow(adapter: RecordingPlayerAdapter())
        f.remove(at: 0)
        assertBaseline("queue", "after-remove", ScreenRenderer.queue(f.state, config: .current()))
    }

    func testHarnessDetectsChangedBaselineAndCapturesArtifacts() throws {
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
        else { return XCTFail("changed render must not match baseline") }
        XCTAssertTrue(message.contains("[queue/initial]"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: actual.path))
        XCTAssertTrue(try String(contentsOf: diff, encoding: .utf8).contains("Alpha (changed)"))
    }

    func testRenderIsDeterministicAcrossRuns() {
        let config = HarnessConfiguration.current()
        let renders = (0..<2).map { _ -> String in
            var f = flow(adapter: RecordingPlayerAdapter())
            f.move(from: 3, to: 0)
            return ScreenRenderer.queue(f.state, config: config)
        }
        XCTAssertEqual(renders[0], renders[1])
    }

    func testLaunchConfigurationInjection() {
        let c = HarnessConfiguration.current(
            environment: ["TONEARM_HARNESS_COLORSCHEME": "dark", "TONEARM_HARNESS_BASELINEDIR": "/tmp/b"],
            arguments: ["x", "-TonearmHarnessAccessibilityCategory", "accessibility-xxxl", "-TonearmHarnessReduceMotion", "1"])
        XCTAssertEqual(c.colorScheme, "dark")
        XCTAssertEqual(c.accessibilityCategory, "accessibility-xxxl")
        XCTAssertTrue(c.reduceMotion)
        XCTAssertEqual(c.baselineDirectory.path, "/tmp/b")
    }

    // MARK: accessibility

    func testQueueAccessibilityElementsAndActions() {
        let f = flow(adapter: RecordingPlayerAdapter())
        let rendered = ScreenRenderer.queue(f.state, config: .current())
        XCTAssertTrue(rendered.contains("value=\"Now playing, 1 minute, 1 second\""), "[queue/a11y] current row value")
        XCTAssertTrue(rendered.contains("hint=\"Plays this track now\""))
        XCTAssertGreaterThanOrEqual(QueueAccessibility.minimumTargetSide, 44)
        XCTAssertEqual(QueueAccessibility.removeActionName, "Remove from queue")
    }

}
