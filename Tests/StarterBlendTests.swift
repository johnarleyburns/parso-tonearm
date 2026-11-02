import XCTest
@testable import TonearmCore

@MainActor
private final class StartLog {
    var requests: [StarterPlayRequest] = []
}

/// The six revised Starter packs: exact ids, order and the 30 supplied edge plans.
@MainActor
final class StarterBlendTests: XCTestCase {
    static let expected: [(id: String, tracks: [String])] = [
        ("starter.morning-light", ["1174818", "2232438", "1428775", "2020849", "26742", "1832242"]),
        ("starter.deep-focus", ["98135", "785424", "1458069", "1629934", "501673", "1406396"]),
        ("starter.night-drive", ["946", "20237", "7475", "1555047", "1353514", "296235"]),
        ("starter.acoustic-evening", ["1204663", "1585553", "1246367", "337997", "1204670", "1337398"]),
        ("starter.upbeat-energy", ["81744", "951", "2016794", "222565", "1059819", "375191"]),
        ("starter.rainy-day", ["29872", "957463", "1589557", "1393688", "878019", "398173"])
    ]

    func testSixRevisedPacksAre36UniqueTracksAndThirtyOrderedEdges() {
        XCTAssertEqual(StarterBlendCatalog.blends.map(\.id), Self.expected.map(\.id))
        XCTAssertEqual(StarterBlendCatalog.blends.map(\.trackIDs), Self.expected.map(\.tracks))
        let all = StarterBlendCatalog.blends.flatMap(\.trackIDs)
        XCTAssertEqual(all.count, 36)
        XCTAssertEqual(Set(all).count, 36)
                XCTAssertEqual(StarterBlendRuntimeData.edges.count, 30)
        for blend in StarterBlendCatalog.blends {
            XCTAssertEqual(blend.pack, .v2)
            XCTAssertEqual(blend.edgePlans.count, 5, blend.id)
            XCTAssertEqual(blend.edgePlans.map(\.edge), [1, 2, 3, 4, 5])
            for (i, plan) in blend.edgePlans.enumerated() {
                XCTAssertEqual(plan.blendID, blend.id)
                XCTAssertEqual(plan.outgoingTrackID, blend.trackIDs[i])
                XCTAssertEqual(plan.incomingTrackID, blend.trackIDs[i + 1])
            }
        }
    }

    func testEveryPlanResolvesAgainstItsTracksAndFitsInside() throws {
        let facts = StarterTestFacts.byID
        var styles: [BlendEdgePlan.Style: Int] = [:]
        for plan in StarterBlendRuntimeData.edges {
            styles[plan.style, default: 0] += 1
            let out = try XCTUnwrap(facts[plan.outgoingTrackID]), inc = try XCTUnwrap(facts[plan.incomingTrackID])
            XCTAssertTrue(out.isBlendReady && inc.isBlendReady)
            let s = try XCTUnwrap(plan.schedule(), "\(plan.blendID) edge \(plan.edge)")
            XCTAssertLessThan(s.outgoingStart, out.durationSeconds)
            XCTAssertLessThanOrEqual(s.outgoingStart + s.overlapSeconds, out.durationSeconds + 0.01)
            XCTAssertLessThan(s.incomingStart, inc.durationSeconds)
            XCTAssertGreaterThan(s.incomingTempo, 0.9); XCTAssertLessThan(s.incomingTempo, 1.1)
        }
        // Real drop/bass-exit structure (StarterBlendEdgePlanner, ParsoAudioAnalysis.DropDetector):
        // most edges land a real doubleDrop or phraseCut; CatalogEdgePlanner's plain bassSwap is
        // the fallback for the few pairs where neither track's structure gave a usable point.
        XCTAssertEqual(styles[.doubleDrop], 17)
        XCTAssertEqual(styles[.phraseCut], 11)
        XCTAssertEqual(styles[.bassSwap], 2)
    }

    func testPlanValuesAreCopiedExactly() throws {
        // v2 edges come from StarterBlendEdgePlanner (real DropDetector structure against each
        // track's full audio, DropAwareEdgePlanner, CatalogEdgePlanner bassSwap fallback) — not
        // hand-tuned, but no longer bassSwap-only either.
        let first = try XCTUnwrap(StarterBlendCatalog.blends[0].edgePlans.first)
        XCTAssertEqual(first.style, .doubleDrop)
        XCTAssertEqual(first.tempo, 0.9855223417262398)
        XCTAssertEqual(first.incomingGain, 0.6698350299104915)
        XCTAssertEqual(first.overlapBeats, 64)
        XCTAssertEqual(first.outgoingSwapBeat, 256)
        XCTAssertEqual(first.incomingSwapBeat, 32)
        XCTAssertEqual(first.blendStartSeconds, 155.4375375368543)
        XCTAssertEqual(first.swapSeconds, 177.5958671558418)
        XCTAssertEqual(first.blendEndSeconds, 199.7541967748293)
        XCTAssertEqual(first.incomingOffsetSeconds, 145.79956740986142)
        let last = try XCTUnwrap(StarterBlendCatalog.blends[5].edgePlans.last)
        XCTAssertEqual(last.style, .doubleDrop)
        XCTAssertEqual(last.outgoingTrackID, "878019")
        XCTAssertEqual(last.incomingTrackID, "398173")
    }

    func testAssetsComeFromTheImmutableReleaseNeverJamendo() throws {
        let pack = StarterBlendCatalog.pack
        XCTAssertEqual(pack.releaseTag, "starter-blends-aac-v2")
        XCTAssertEqual(pack.assetURL(trackID: "1174818")?.absoluteString,
                       "https://github.com/johnarleyburns/parso-tonearm/releases/download/starter-blends-aac-v2/1174818.m4a")
        for blend in StarterBlendCatalog.blends {
            for row in try StarterBlendPlayback.catalogRows(for: blend) {
                let url = URL(string: row.asset?.remoteURL ?? "")
                XCTAssertNotNil(url)
                XCTAssertTrue(pack.owns(url!), "\(url!)")
                XCTAssertFalse(url!.host?.contains("jamendo") ?? true)
                XCTAssertEqual(row.asset?.transientRemoteSupportsByteRanges, true)
            }
        }
    }

    func testDocumentIsDeterministicAndCarriesPackAndPlans() {
        for blend in StarterBlendCatalog.blends {
            XCTAssertEqual(blend.document, blend.document)
            XCTAssertEqual(blend.document.origin, .starter)
            XCTAssertEqual(blend.document.pack, .v2)
            XCTAssertEqual(blend.document.occurrences.count, 6)
            XCTAssertEqual(blend.document.edges.compactMap(\.plan), blend.edgePlans)
            XCTAssertEqual(blend.document.edges.map(\.requestedStyle), blend.edgePlans.map { $0.style.rawValue })
        }
    }

    func testPlayBuildsOneRequestCarryingEveryEdgePlan() async throws {
        let blend = StarterBlendCatalog.blends[0]
        let log = StartLog()
        let playback = StarterBlendPlayback(start: { log.requests.append($0) })
        await playback.play(blend)
        let request = try XCTUnwrap(log.requests.first)
        XCTAssertEqual(log.requests.count, 1)
        XCTAssertEqual(request.occurrenceIDs, blend.document.occurrences.map(\.id))
        XCTAssertEqual(request.trackIDs, blend.trackIDs)
        XCTAssertEqual(request.edgePlans, blend.edgePlans)
        XCTAssertEqual(request.rows.count, 6)
        XCTAssertEqual(request.pack, .v2)
        XCTAssertTrue(request.isBlended)
        XCTAssertEqual(playback.state(for: blend), .buffering)
    }

    func testRepeatedTapWhileInFlightStartsOnce() async {
        let blend = StarterBlendCatalog.blends[0]
        let log = StartLog()
        let playback = StarterBlendPlayback(start: { log.requests.append($0) })
        async let a: Void = playback.play(blend)
        async let b: Void = playback.play(blend)
        _ = await (a, b)
        XCTAssertEqual(log.requests.count, 1)
    }

    func testPlayerStatusDrivesTruthfulCardStates() async {
        let blend = StarterBlendCatalog.blends[0]
        let playback = StarterBlendPlayback(start: { _ in })
        playback.apply(.buffering(blendID: blend.id))
        XCTAssertEqual(playback.state(for: blend), .buffering)
        playback.apply(.blending(blendID: blend.id))
        XCTAssertEqual(playback.state(for: blend), .blending)
        playback.apply(.sequential(blendID: blend.id, reason: "Track 3: offline", retryable: true))
        XCTAssertEqual(playback.state(for: blend), .unavailable(reason: "Track 3: offline", retryable: true))
        playback.apply(.sequential(blendID: blend.id, reason: "Track 3: not found", retryable: false))
        XCTAssertEqual(playback.state(for: blend), .unavailable(reason: "Track 3: not found", retryable: false))
        XCTAssertEqual(playback.state(for: StarterBlendCatalog.blends[1]), .idle)
    }

    func testEveryPlanIsSelfContainedAndDefinitionsCarryNoTrackFacts() throws {
        for plan in StarterBlendRuntimeData.edges {
            XCTAssertNotNil(plan.schedule(), "\(plan.blendID) edge \(plan.edge)")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for file in ["Sources/Domain/Mix/StarterBlendRuntimeData.swift", "Sources/Domain/Mix/StarterBlendCatalog.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for banned in ["StarterTrackFacts", "trackFacts", "subgenre", "camelot", "beatPeriod", "bpm", "genres"] {
                XCTAssertFalse(text.contains(banned), "\(file) must not contain \(banned)")
            }
        }
    }
}


final class StarterBlendCatalogMetadataTests: XCTestCase {
    func testStarterRowsUseCatalogSongAndArtistMetadataNotSyntheticCardSlots() throws {
        let blend = try XCTUnwrap(StarterBlendCatalog.blend(id: "starter.upbeat-energy"))
        let rows = try StarterBlendPlayback.catalogRows(for: blend)
        XCTAssertEqual(rows.count, 6)
        let adapter = try StarterCatalogAdapter.bundled()
        for (row, id) in zip(rows, blend.trackIDs) {
            XCTAssertNotEqual(row.track.title, "\(blend.title) \(row.track.trackNo ?? 0)")
            XCTAssertFalse(row.track.title.isEmpty)
            XCTAssertFalse((row.artist?.name ?? "").isEmpty)
            XCTAssertEqual(row.album?.title, blend.title)
            XCTAssertEqual(row.track.genre, try XCTUnwrap(adapter.resolve(trackIDs: [id]).first).genre)
        }
    }

    func testStarterRowConstructionRefusesMissingCatalogMetadataRatherThanUsingSyntheticNames() throws {
        let blend = try XCTUnwrap(StarterBlendCatalog.blend(id: "starter.upbeat-energy"))
        XCTAssertThrowsError(try StarterBlendPlayback.catalogRows(for: blend, resolver: { _ in
            throw StarterCatalogError.invalid(id: "jamendo-x", reason: "title")
        }))
        XCTAssertThrowsError(try StarterBlendPlayback.catalogRows(for: blend, resolver: { ids in
            ids.dropLast().map { CatalogPlaybackMetadata(trackID: $0, title: "T", artist: "A", genre: "g", artworkURL: nil, durationSeconds: 60) }
        }))
        for bad in [0.0, -1, .nan, .infinity] {
            XCTAssertThrowsError(try StarterBlendPlayback.catalogRows(for: blend, resolver: { ids in
                ids.map { CatalogPlaybackMetadata(trackID: $0, title: "T", artist: "A", genre: "g", artworkURL: nil, durationSeconds: bad) }
            }), "duration \(bad) must fail")
        }
    }

    func testPrecomputedRowsCarryValidatedCatalogDuration() throws {
        for blend in StarterBlendCatalog.blends {
            let rows = try StarterBlendPlayback.catalogRows(for: blend)
            let entries = try StarterCatalogAdapter.bundled().resolve(trackIDs: blend.trackIDs)
            XCTAssertEqual(rows.count, entries.count)
            for (row, entry) in zip(rows, entries) {
                XCTAssertEqual(try XCTUnwrap(row.track.durationSec), entry.durationSeconds, accuracy: 0.000_001)
                XCTAssertGreaterThan(try XCTUnwrap(row.track.durationSec), 0)
            }
        }
    }
}
