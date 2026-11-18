import Testing
import TonearmWatchCore

/// Phase 9b — the pure route/interruption/media-reset decision table for watch-local playback (§7.2).
@Suite struct WatchAudioSessionPolicyTests {

    @Test func testRouteLostAlwaysParksPausedPersistedWithHint() {
        for wasPlaying in [true, false] {
            #expect(
                WatchAudioSessionPolicy.actions(for: .routeLost, wasPlaying: wasPlaying) ==
                [.pause, .persist, .showRouteHint]
            )
        }
    }

    @Test func testRouteAvailableClearsTheHintAndNothingElse() {
        #expect(
            WatchAudioSessionPolicy.actions(for: .routeAvailable, wasPlaying: true) ==
            [.clearRouteHint]
        )
    }

    @Test func testRouteAvailableNeverResumes() {
        let actions = WatchAudioSessionPolicy.actions(for: .routeAvailable, wasPlaying: true)
        #expect(!actions.contains(.resumeIfWasPlaying))
    }

    @Test func testInterruptionBeganPausesAndPersists() {
        #expect(
            WatchAudioSessionPolicy.actions(for: .interruptionBegan, wasPlaying: true) ==
            [.pause, .persist]
        )
    }

    @Test func testInterruptionEndedResumesOnlyWhenSystemSaysSoAndWeWerePlaying() {
        #expect(
            WatchAudioSessionPolicy.actions(for: .interruptionEnded(shouldResume: true), wasPlaying: true) ==
            [.rebuildSession, .resumeIfWasPlaying]
        )
        #expect(
            WatchAudioSessionPolicy.actions(for: .interruptionEnded(shouldResume: true), wasPlaying: false) ==
            []
        )
        #expect(
            WatchAudioSessionPolicy.actions(for: .interruptionEnded(shouldResume: false), wasPlaying: true) ==
            []
        )
    }

    @Test func testMediaServicesResetRebuildsAndStaysPaused() {
        let actions = WatchAudioSessionPolicy.actions(for: .mediaServicesReset, wasPlaying: true)
        #expect(actions == [.pause, .rebuildSession, .persist])
        #expect(!actions.contains(.resumeIfWasPlaying))
    }

    @Test func testBackgroundOnlyCheckpoints() {
        #expect(WatchAudioSessionPolicy.actions(for: .appDidBackground, wasPlaying: true) == [.persist])
    }

    @Test func testForegroundAndWristDownAreNoOps() {
        #expect(WatchAudioSessionPolicy.actions(for: .appWillForeground, wasPlaying: true) == [])
        #expect(WatchAudioSessionPolicy.actions(for: .wristDown, wasPlaying: true) == [])
    }

    @Test func testNothingButInterruptionEndedEverProducesAResume() {
        let events: [WatchAudioEvent] = [
            .routeLost, .routeAvailable, .interruptionBegan, .mediaServicesReset,
            .appDidBackground, .appWillForeground, .wristDown
        ]
        for event in events {
            for wasPlaying in [true, false] {
                #expect(
                    !WatchAudioSessionPolicy.actions(for: event, wasPlaying: wasPlaying).contains(.resumeIfWasPlaying),
                    "\(event) must never auto-resume"
                )
            }
        }
    }
}
