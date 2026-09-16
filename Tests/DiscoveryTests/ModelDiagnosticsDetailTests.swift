#if !os(watchOS)
import XCTest

@testable import TonearmDiscovery

/// The "Models" section on the Sound Index screen (user's explicit request
/// during an interactive debug session: "show each model, the percentage
/// downloaded, MB downloaded, if it's complete or not, any errors, also
/// show active downloading"). This tests the pure `ModelDiagnosticsDetail`
/// value type — the live `NSBundleResourceRequest`/`ModelResourceLocator`
/// wiring lives in `Sources/App/DiscoveryModelResources.swift` (Xcode-only,
/// not reachable here).
final class ModelDiagnosticsDetailTests: XCTestCase {
    private typealias Tag = ModelDiagnosticsDetail.DownloadTag

    func testStateReflectsFinishedFirst() {
        let finished = Tag(tag: "clap-audio", completedBytes: 1, totalBytes: 1, isFinished: true)
        XCTAssertEqual(finished.state, .finished)
    }

    func testStateIsInProgressWhenTotalKnownButNotFinished() {
        let inProgress = Tag(tag: "clap-text", completedBytes: 0, totalBytes: 1, isFinished: false)
        XCTAssertEqual(inProgress.state, .inProgress)
    }

    func testStateIsNotStartedWhenNoTotalYet() {
        let notStarted = Tag(tag: "clap-text", completedBytes: 0, totalBytes: 0, isFinished: false)
        XCTAssertEqual(notStarted.state, .notStarted)
    }

    /// The exact real-device case that motivated this whole section: a
    /// literal `totalUnitCount == 1` is not a trustworthy byte count, even
    /// though the fraction math is technically valid.
    func testBytesAreNotTrustworthyWhenTotalRoundsToZeroMB() {
        let placeholderUnits = Tag(tag: "clap-audio", completedBytes: 1, totalBytes: 1, isFinished: true)
        XCTAssertFalse(placeholderUnits.bytesAreTrustworthy)
        XCTAssertEqual(placeholderUnits.fractionComplete, 1.0,
            "the math is still correct — bytesAreTrustworthy is what must gate display, not the fraction")
    }

    func testBytesAreTrustworthyWhenTotalIsSeveralMB() {
        let real = Tag(tag: "clap-audio", completedBytes: 42 * 1_048_576, totalBytes: 123 * 1_048_576, isFinished: false)
        XCTAssertTrue(real.bytesAreTrustworthy)
    }

    /// The exact real-device scenario this section is built to make
    /// visible at a glance: downloads all "finished" while artifacts still
    /// fail to resolve (the root cause fixed by the Bundle-API change) —
    /// this must be representable and distinguishable from the healthy case.
    func testDetailRepresentsDownloadsFinishedButArtifactsUnresolved() {
        let detail = ModelDiagnosticsDetail(
            downloadTags: [
                Tag(tag: "clap-audio", completedBytes: 1, totalBytes: 1, isFinished: true),
                Tag(tag: "clap-text", completedBytes: 1, totalBytes: 1, isFinished: true),
            ],
            artifacts: [
                ModelDiagnosticsDetail.Artifact(name: "Audio encoder", isResolved: false),
                ModelDiagnosticsDetail.Artifact(name: "Text encoder", isResolved: false),
            ])
        XCTAssertTrue(detail.downloadTags.allSatisfy { $0.state == .finished })
        XCTAssertTrue(detail.artifacts.allSatisfy { !$0.isResolved })
    }

    func testDetailRepresentsTheHealthyFullyResolvedCase() {
        let detail = ModelDiagnosticsDetail(
            downloadTags: [
                Tag(tag: "clap-audio", completedBytes: 1, totalBytes: 1, isFinished: true),
                Tag(tag: "clap-text", completedBytes: 1, totalBytes: 1, isFinished: true),
            ],
            artifacts: [
                ModelDiagnosticsDetail.Artifact(
                    name: "Audio encoder", isResolved: true, resolvedName: "CLAPAudioEncoder.mlmodelc"),
                ModelDiagnosticsDetail.Artifact(
                    name: "Text encoder", isResolved: true, resolvedName: "CLAPTextEncoder.mlmodelc"),
            ])
        XCTAssertTrue(detail.artifacts.allSatisfy(\.isResolved))
        XCTAssertEqual(detail.artifacts.first?.resolvedName, "CLAPAudioEncoder.mlmodelc")
    }
}
#endif
