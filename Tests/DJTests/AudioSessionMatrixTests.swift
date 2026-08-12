import XCTest
@testable import TonearmDJ

/// Commit 4.2 — the audio-session decision matrix (plan §5, spec §34A.3–34A.4,
/// FR-SESS-1/2/3/4).
///
/// Every row of §34A.3's route-change table and §34A.4's interruption table maps
/// to exactly one `SessionPolicy.Response`, decided by a pure function over plain
/// value types — so AT-SESS-*'s *decisions* are testable on the macOS host with
/// no device (plan §2.4, §2.11). The physical route events and the
/// `AVAudioSession` shell are user-owned on a device.
final class AudioSessionMatrixTests: XCTestCase {

    // MARK: - §34A.3 route changes

    func testOldDeviceUnavailablePausesBothDecksImmediately() {
        let response = SessionPolicy.response(for: .init(
            reason: .oldDeviceUnavailable,
            sampleRateChanged: false,
            isPerforming: true,
            isBluetooth: false))
        XCTAssertEqual(response, .pauseBothDecks,
                       "headphones/interface unplugged must pause both decks — never blast the speaker")
    }

    func testOldDeviceUnavailablePausesEvenWhileListening() {
        let response = SessionPolicy.response(for: .init(
            reason: .oldDeviceUnavailable,
            sampleRateChanged: false,
            isPerforming: false,
            isBluetooth: false))
        XCTAssertEqual(response, .pauseBothDecks)
    }

    func testNewDeviceAvailableReReadsAndRenegotiates() {
        let response = SessionPolicy.response(for: .init(
            reason: .newDeviceAvailable,
            sampleRateChanged: false,
            isPerforming: true,
            isBluetooth: false))
        XCTAssertEqual(response, .reReadAndRenegotiate,
                       "interface attached must re-read Granted and re-negotiate the buffer")
    }

    func testNewDeviceAvailableToBluetoothWhilePerformingRaisesWarning() {
        let response = SessionPolicy.response(for: .init(
            reason: .newDeviceAvailable,
            sampleRateChanged: false,
            isPerforming: true,
            isBluetooth: true))
        XCTAssertEqual(response, .warnBluetoothWhilePerforming,
                       "FR-SESS-4: Bluetooth while performing warns with the measured round trip, never silently degrades")
    }

    func testNewDeviceAvailableToBluetoothWhileListeningIsBenign() {
        let response = SessionPolicy.response(for: .init(
            reason: .newDeviceAvailable,
            sampleRateChanged: false,
            isPerforming: false,
            isBluetooth: true))
        XCTAssertEqual(response, .reReadAndRenegotiate,
                       "no warning for a listening session over Bluetooth — FR-SESS-4 is about performing")
    }

    func testCategoryAndOverrideReReadAndReassert() {
        for reason in [SessionPolicy.RouteChangeReason.categoryChange, .override] {
            let response = SessionPolicy.response(for: .init(
                reason: reason,
                sampleRateChanged: false,
                isPerforming: false,
                isBluetooth: false))
            XCTAssertEqual(response, .reReadAndReassert,
                           "another party changed the category — re-read Granted and re-assert preferences")
        }
    }

    func testRouteConfigurationChangeIsReadOnly() {
        let response = SessionPolicy.response(for: .init(
            reason: .routeConfigurationChange,
            sampleRateChanged: false,
            isPerforming: false,
            isBluetooth: false))
        XCTAssertEqual(response, .reReadOnly, "route configuration change is common and usually benign — re-read only")
    }

    func testUnknownReasonIsReadOnly() {
        let response = SessionPolicy.response(for: .init(
            reason: .unknown,
            sampleRateChanged: false,
            isPerforming: false,
            isBluetooth: false))
        XCTAssertEqual(response, .reReadOnly)
    }

    func testSampleRateChangeForcesRebuildOverEveryReason() {
        // The sample-rate row wins over every reason row (§34A.3): node formats
        // are fixed at connect time, so the graph must be rebuilt.
        let reasons: [SessionPolicy.RouteChangeReason] = [
            .oldDeviceUnavailable, .newDeviceAvailable, .categoryChange,
            .override, .routeConfigurationChange, .unknown,
        ]
        for reason in reasons {
            let response = SessionPolicy.response(for: .init(
                reason: reason,
                sampleRateChanged: true,
                isPerforming: true,
                isBluetooth: false))
            XCTAssertEqual(response, .rebuildGraph, "sample-rate change under \(reason) must rebuild the graph")
        }
    }

    // MARK: - §34A.4 interruptions

    func testBeganFlushesSegmentAndCapturesPlayheads() {
        let response = SessionPolicy.response(for: .init(
            phase: .began, shouldResume: false, formatChanged: false))
        XCTAssertEqual(response, .flushSegmentAndCapturePlayheads,
                       "engine is paused by the system; flush the recording segment and capture playheads (NFR-REL-2)")
    }

    func testEndedWithShouldResumeRestoresPausedAndNeverAutoPlays() {
        let response = SessionPolicy.response(for: .init(
            phase: .ended, shouldResume: true, formatChanged: false))
        XCTAssertEqual(response, .resume(rebuildGraph: false),
                       "decks must restore paused at their captured playheads — audio resuming by itself is worse than silence")
    }

    func testEndedWithShouldResumeAndFormatChangeRebuildsGraph() {
        let response = SessionPolicy.response(for: .init(
            phase: .ended, shouldResume: true, formatChanged: true))
        XCTAssertEqual(response, .resume(rebuildGraph: true),
                       "a rate/channel change after interruption must rebuild the graph before restoring transports")
    }

    func testEndedWithoutShouldResumeRemainsPausedOfferingResume() {
        let response = SessionPolicy.response(for: .init(
            phase: .ended, shouldResume: false, formatChanged: false))
        XCTAssertEqual(response, .remainPausedOfferResume,
                       "without shouldResume the session stays paused; the UI offers an explicit Resume")
    }

    func testNoInterruptionResponseEverAutoPlays() {
        // The §34A.4 invariant: never auto-play after an interruption. Enumerate
        // every phase/shouldResume/formatChanged combination and assert none of
        // the responses is a play instruction. `.resume` restores *paused*
        // transports (its doc contract) — the only decks state it can carry.
        let began = SessionPolicy.response(for: .init(phase: .began, shouldResume: false, formatChanged: false))
        let endedResume = SessionPolicy.response(for: .init(phase: .ended, shouldResume: true, formatChanged: false))
        let endedResumeRebuild = SessionPolicy.response(for: .init(phase: .ended, shouldResume: true, formatChanged: true))
        let endedNoResume = SessionPolicy.response(for: .init(phase: .ended, shouldResume: false, formatChanged: false))

        let all = [began, endedResume, endedResumeRebuild, endedNoResume]
        for response in all {
            switch response {
            case .resume, .remainPausedOfferResume, .flushSegmentAndCapturePlayheads:
                break
            default:
                XCTFail("unexpected interruption response \(response)")
            }
        }
    }

    // MARK: - mediaServicesWereReset

    func testMediaServicesResetRebuildsEverything() {
        XCTAssertEqual(SessionPolicy.response(forMediaServicesReset: ()), .rebuildGraph,
                       "an unhandled reset leaves the app silent until relaunch mid-set — must rebuild")
    }

    // MARK: - Modes (FR-SESS-1)

    func testModesRequestTheExpectedBuffer() {
        XCTAssertFalse(SessionPolicy.Mode.listening.requestsPreferredBuffer,
                       "listening keeps the system default buffer — long battery life")
        XCTAssertTrue(SessionPolicy.Mode.performing.requestsPreferredBuffer)
        XCTAssertTrue(SessionPolicy.Mode.performingWithTalkover.requestsPreferredBuffer)

        XCTAssertNil(SessionPolicy.Mode.listening.preferredIOBufferDuration)
        XCTAssertEqual(SessionPolicy.Mode.performing.preferredIOBufferDuration,
                       128.0 / 48_000.0, "performing requests 128 frames @ 48 kHz (§34.1)")
        XCTAssertEqual(SessionPolicy.Mode.performingWithTalkover.preferredIOBufferDuration,
                       128.0 / 48_000.0)
    }

    // MARK: - Granted round trip (FR-SESS-2, AT-SESS-5)

    func testRoundTripMillisIsComputedFromGrantedValues() {
        // 128 frames @ 48 kHz = 2.67 ms buffer; a typical 10 ms output latency.
        let granted = SessionPolicy.Granted(
            ioBufferDuration: 128.0 / 48_000.0,
            sampleRate: 48_000,
            outputLatency: 0.010,
            inputLatency: 0.005,
            outputChannels: 2,
            routeName: "Built-In Speakers",
            isBluetooth: false)
        let expected = (128.0 / 48_000.0 * 2 + 0.010) * 1000
        XCTAssertEqual(granted.roundTripMillis, expected, accuracy: 1e-9)
    }

    func testRoundTripMillisUsesGrantedNotRequestedBuffer() {
        // The app asked for 128 frames but the system granted 21 ms on this
        // route — the UI must show the granted figure (FR-SESS-2, §34.2).
        let granted = SessionPolicy.Granted(
            ioBufferDuration: 0.021,
            sampleRate: 48_000,
            outputLatency: 0.012,
            inputLatency: 0.008,
            outputChannels: 2,
            routeName: "USB-C Interface",
            isBluetooth: false)
        XCTAssertEqual(granted.roundTripMillis, (0.021 * 2 + 0.012) * 1000, accuracy: 1e-9)
    }

    func testRoundTripMillisReflectsBluetoothLatency() {
        let bluetooth = SessionPolicy.Granted(
            ioBufferDuration: 0.021,
            sampleRate: 48_000,
            outputLatency: 0.180,
            inputLatency: 0.150,
            outputChannels: 2,
            routeName: "Speaker (Bluetooth)",
            isBluetooth: true)
        XCTAssertEqual(bluetooth.roundTripMillis, (0.021 * 2 + 0.180) * 1000, accuracy: 1e-9)
        XCTAssertTrue(bluetooth.isBluetooth)
    }

    // MARK: - Coordinator stub on the host

    func testCoordinatorIsUnavailableOnThisPlatform() async throws {
        // `swift test` runs on macOS, which has no AVAudioSession: the
        // coordinator is a minimal stub, and entering throws — the session
        // cannot be configured off iOS (plan §2.3).
        let coordinator = AudioSessionCoordinator()
        do {
            _ = try await coordinator.enter(.performing)
            XCTFail("enter must throw on a platform without AVAudioSession")
        } catch AudioSessionCoordinator.SessionError.unavailableOnThisPlatform {
            // expected
        }
    }
}
