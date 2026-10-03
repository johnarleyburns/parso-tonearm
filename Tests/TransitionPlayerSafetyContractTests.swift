import XCTest

/// Source contract: the AVPlayer calls that raise an Objective-C exception (an app abort) when
/// the player isn't ready may only be made through `TransitionPlayerControl`, which checks the
/// precondition and catches what slips through. TestFlight 520 and 521 crashed mid-mix on direct
/// calls; this fails before such a call reaches a build.
final class TransitionPlayerSafetyContractTests: XCTestCase {
    private static let allowed = "Sources/Audio/TransitionPlayerControl.swift"
    private static let raisingCalls = [".preroll(atRate:", "atHostTime:", ".setRate("]

    func testRaisingAVPlayerCallsOnlyGoThroughTransitionPlayerControl() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            guard relative != Self.allowed else { continue }
            let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            for (number, line) in lines.enumerated() {
                let code = line.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
                if Self.raisingCalls.contains(where: { code.contains($0) }) {
                    offenders.append("\(relative):\(number + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertEqual(offenders, [], "Call these through TransitionPlayerControl:\n" + offenders.joined(separator: "\n"))
    }
}
