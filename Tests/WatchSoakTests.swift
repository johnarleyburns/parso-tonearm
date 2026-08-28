import Foundation
import XCTest
@testable import TonearmWatchCore
@testable import TonearmWatchProtocol

/// Phase 10f — the §12 fault-injection / soak harnesses that do not need the GRDB download stack.
/// The download-side scenarios (500-track desired set, 100 cancellations, relaunch at every job
/// state) live in `PhoneWatchDownloadTests` next to that pipeline's fakes.
///
/// The definition of done for each: the system **converges** (settles on one consistent answer) and
/// **memory/disk stays bounded** (nothing accumulates per event).
final class WatchSoakTests: XCTestCase {

    // MARK: - 1,000 duplicate / out-of-order events

    func test1000DuplicateAndOutOfOrderDurableEventsConvergeAndStayBounded() async {
        let capacity = 512
        let ledger = WatchAppliedMessageLedger(capacity: capacity)
        var gate = WatchRevisionGate()

        // 200 distinct logical events, each delivered ~5x, the whole stream shuffled so revisions
        // arrive out of order and messages repeat.
        let distinct = 200
        var stream: [(id: UUID, revision: Int64)] = []
        var idForRevision: [Int64: UUID] = [:]
        for r in 1...distinct { idForRevision[Int64(r)] = UUID() }
        for _ in 0..<5 {
            for r in 1...distinct { stream.append((idForRevision[Int64(r)]!, Int64(r))) }
        }
        var rng = SystemRandomNumberGenerator()
        stream.shuffle(using: &rng)
        XCTAssertEqual(stream.count, 1_000)

        var appliedRevisions: Set<Int64> = []
        var maxApplied: Int64 = 0
        for event in stream {
            let admitted = await ledger.admit(event.id)
            guard admitted == .apply else { continue }
            // Ledger says "new message" — now the revision gate decides whether it is fresh state.
            if gate.evaluate(scope: .downloadRoots, revision: event.revision) == .apply {
                XCTAssertGreaterThan(event.revision, maxApplied, "the gate must never apply a regression")
                maxApplied = event.revision
                appliedRevisions.insert(event.revision)
            }
        }

        // Convergence: the newest revision won, and it is the only authority now.
        XCTAssertEqual(gate.lastApplied(.downloadRoots), Int64(distinct))
        XCTAssertEqual(maxApplied, Int64(distinct))
        // Every applied revision was strictly increasing, so at most `distinct` were applied and
        // each distinct message was admitted exactly once.
        XCTAssertLessThanOrEqual(appliedRevisions.count, distinct)

        // Bounded: the ledger holds at most `capacity` ids no matter how many crossed it.
        let count = await ledger.count
        XCTAssertLessThanOrEqual(count, capacity)
    }

    // MARK: - rapid connect / disconnect

    func testRapidConnectDisconnectFlappingSettlesWithOneAlertPerConfirmedOutage() {
        var reducer = WatchConnectionReducer(gracePeriod: 2.0)
        var now = Date(timeIntervalSince1970: 0)
        _ = reducer.apply(.activated(reachable: true), at: now)

        var announcedDisconnects = 0
        var announcedReconnects = 0
        var pendingGraceDeadline: Date?

        func run(_ effects: [WatchConnectionReducer.Effect]) {
            for effect in effects {
                switch effect {
                case .scheduleGraceExpiry(let after): pendingGraceDeadline = now.addingTimeInterval(after)
                case .cancelGraceExpiry: pendingGraceDeadline = nil
                case .announceDisconnected: announcedDisconnects += 1
                case .announceReconnected: announcedReconnects += 1
                }
            }
        }

        // 500 flaps. Half of them stay down long enough to cross the grace period (a real outage);
        // the rest recover inside it (a blip that must not alert).
        for i in 0..<500 {
            now = now.addingTimeInterval(0.5)
            run(reducer.apply(.reachabilityChanged(false), at: now))
            let downFor: TimeInterval = i.isMultiple(of: 2) ? 3.0 : 0.5
            now = now.addingTimeInterval(downFor)
            if let deadline = pendingGraceDeadline, now >= deadline {
                run(reducer.apply(.graceElapsed, at: now))
            }
            run(reducer.apply(.reachabilityChanged(true), at: now))
            run(reducer.apply(.peerResponded, at: now))
        }

        // Converged: after a peerResponded the reducer is back to connected.
        guard case .connected = reducer.state else {
            return XCTFail("expected connected after the last recovery, got \(reducer.state)")
        }
        // Bounded alerts: one disconnect alert per confirmed outage (250 of the 500 flaps stayed
        // down past the grace period), never one per flap, and a matching reconnect for each.
        XCTAssertEqual(announcedDisconnects, 250, "one alert per confirmed outage, not per flap")
        XCTAssertEqual(announcedReconnects, announcedDisconnects)
    }

    // MARK: - six-hour local playback state simulation

    func testSixHoursOfLocalPlaybackStateStaysBoundedAndConsistent() {
        let suiteName = "watch-soak-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let queue = (0..<12).map { "track-\($0)" }
        var engine = WatchPlayerEngine(queue: queue, startIndex: 0)
        engine.cycleRepeat() // .off -> .all, so playback never runs out over six hours
        _ = engine.command(.play, urlForTrack: { URL(string: "file:///\($0).m4a") })

        // A remote-prediction anchor for the same span: 4-minute track, playing at 1x.
        let anchor = Date(timeIntervalSince1970: 0)
        let remoteSnapshot = WatchPhonePlaybackSnapshot(
            revision: 1, source: .localLibrary, isPlaying: true, rate: 1,
            currentItem: WatchTrackSummary(trackID: "track-0", title: "T", durationSeconds: 240),
            queueCount: queue.count, elapsedSeconds: 0, elapsedAnchorDate: anchor)
        let remote = WatchRemotePlaybackState(snapshot: remoteSnapshot, receivedAt: anchor)

        var savedSizes: [Int] = []
        let sixHours = 6 * 60 * 60
        for second in stride(from: 0, through: sixHours, by: 1) {
            // Every ~4 minutes the current track "ends" and the engine rolls to the next one.
            if second > 0 && second % 240 == 0 {
                _ = engine.command(.itemEnded, urlForTrack: { URL(string: "file:///\($0).m4a") })
            }
            // The 9b persistence cadence: write the position every 10 s.
            if second % 10 == 0 {
                WatchPositionStore.save(engine.snapshot, defaults: defaults)
                if let data = defaults.data(forKey: "guru.parso.tonearm.watch.playback.position") {
                    savedSizes.append(data.count)
                }
            }
            // The predicted remote clock must never run past the track duration.
            let predicted = remote.predictedElapsed(at: anchor.addingTimeInterval(TimeInterval(second)))
            XCTAssertLessThanOrEqual(predicted, 240)
            XCTAssertGreaterThanOrEqual(predicted, 0)
        }

        // Convergence / consistency: the engine is still a valid 12-track queue with an in-range
        // index and a non-negative elapsed, after 90 track rolls.
        let snap = engine.snapshot
        XCTAssertEqual(snap.trackKeys.count, 12)
        XCTAssertTrue((0..<12).contains(snap.currentIndex))
        XCTAssertGreaterThanOrEqual(snap.elapsed, 0)
        XCTAssertTrue(engine.isPlaying)

        // Bounded disk: the persisted blob never grows — it is one snapshot, overwritten in place.
        let maxSize = savedSizes.max() ?? 0
        let minSize = savedSizes.min() ?? 0
        XCTAssertGreaterThan(savedSizes.count, 2_000)
        XCTAssertLessThan(maxSize, 2_048, "the persisted position must stay small")
        XCTAssertLessThan(maxSize - minSize, 256, "and must not grow with playback time")

        // And it still round-trips.
        XCTAssertEqual(WatchPositionStore.load(defaults: defaults)?.trackKeys.count, 12)
    }
}
