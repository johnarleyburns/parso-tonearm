import XCTest
import TonearmWatchCore

/// Phase 9b — the pure route/interruption/media-reset decision table for watch-local playback (§7.2).
final class WatchAudioSessionPolicyTests: XCTestCase {

    func testRouteLostAlwaysParksPausedPersistedWithHint() {
        for wasPlaying in [true, false] {
            XCTAssertEqual(
                WatchAudioSessionPolicy.actions(for: .routeLost, wasPlaying: wasPlaying),
                [.pause, .persist, .showRouteHint]
            )
        }
    }

    func testRouteAvailableClearsTheHintAndNothingElse() {
        XCTAssertEqual(
            WatchAudioSessionPolicy.actions(for: .routeAvailable, wasPlaying: true),
            [.clearRouteHint]
        )
    }

    func testRouteAvailableNeverResumes() {
        let actions = WatchAudioSessionPolicy.actions(for: .routeAvailable, wasPlaying: true)
        XCTAssertFalse(actions.contains(.resumeIfWasPlaying))
    }

    func testInterruptionBeganPausesAndPersists() {
        XCTAssertEqual(
            WatchAudioSessionPolicy.actions(for: .interruptionBegan, wasPlaying: true),
            [.pause, .persist]
        )
    }

    func testInterruptionEndedResumesOnlyWhenSystemSaysSoAndWeWerePlaying() {
        XCTAssertEqual(
            WatchAudioSessionPolicy.actions(for: .interruptionEnded(shouldResume: true), wasPlaying: true),
            [.rebuildSession, .resumeIfWasPlaying]
        )
        XCTAssertEqual(
            WatchAudioSessionPolicy.actions(for: .interruptionEnded(shouldResume: true), wasPlaying: false),
            []
        )
        XCTAssertEqual(
            WatchAudioSessionPolicy.actions(for: .interruptionEnded(shouldResume: false), wasPlaying: true),
            []
        )
    }

    func testMediaServicesResetRebuildsAndStaysPaused() {
        let actions = WatchAudioSessionPolicy.actions(for: .mediaServicesReset, wasPlaying: true)
        XCTAssertEqual(actions, [.pause, .rebuildSession, .persist])
        XCTAssertFalse(actions.contains(.resumeIfWasPlaying))
    }

    func testBackgroundOnlyCheckpoints() {
        XCTAssertEqual(WatchAudioSessionPolicy.actions(for: .appDidBackground, wasPlaying: true), [.persist])
    }

    func testForegroundAndWristDownAreNoOps() {
        XCTAssertEqual(WatchAudioSessionPolicy.actions(for: .appWillForeground, wasPlaying: true), [])
        XCTAssertEqual(WatchAudioSessionPolicy.actions(for: .wristDown, wasPlaying: true), [])
    }

    func testNothingButInterruptionEndedEverProducesAResume() {
        let events: [WatchAudioEvent] = [
            .routeLost, .routeAvailable, .interruptionBegan, .mediaServicesReset,
            .appDidBackground, .appWillForeground, .wristDown
        ]
        for event in events {
            for wasPlaying in [true, false] {
                XCTAssertFalse(
                    WatchAudioSessionPolicy.actions(for: event, wasPlaying: wasPlaying).contains(.resumeIfWasPlaying),
                    "\(event) must never auto-resume"
                )
            }
        }
    }
}
