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
        ("starter.morning-light", ["337997", "1424003", "337069", "1180864", "642026", "1077690"]),
        ("starter.deep-focus", ["455018", "117009", "971563", "1097061", "26403", "1100130"]),
        ("starter.night-drive", ["1163782", "1828808", "1121468", "1739551", "1493402", "1560522"]),
        ("starter.acoustic-evening", ["1229422", "398193", "1418240", "1308980", "1849464", "1212932"]),
        ("starter.upbeat-energy", ["2053669", "2228244", "1901830", "2126638", "2133921", "1977152"]),
        ("starter.rainy-day", ["1891078", "1891935", "1974389", "2220789", "2169489", "1960412"])
    ]

    func testSixRevisedPacksAre36UniqueTracksAndThirtyOrderedEdges() {
        XCTAssertEqual(StarterBlendCatalog.blends.map(\.id), Self.expected.map(\.id))
        XCTAssertEqual(StarterBlendCatalog.blends.map(\.trackIDs), Self.expected.map(\.tracks))
        let all = StarterBlendCatalog.blends.flatMap(\.trackIDs)
        XCTAssertEqual(all.count, 36)
        XCTAssertEqual(Set(all).count, 36)
                XCTAssertEqual(StarterBlendRuntimeData.edges.count, 30)
        for blend in StarterBlendCatalog.blends {
            XCTAssertEqual(blend.pack, .v1)
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
        XCTAssertEqual(styles[.bassSwap], 25)
        XCTAssertEqual(styles[.doubleDrop], 3)
        XCTAssertEqual(styles[.phraseCut], 2)
    }

    func testPlanValuesAreCopiedExactly() throws {
        let first = try XCTUnwrap(StarterBlendCatalog.blends[0].edgePlans.first)
        XCTAssertEqual(first.style, .bassSwap)
        XCTAssertEqual(first.tempo, 1.027062079171714)
        XCTAssertEqual(first.incomingGain, 1.8138238773630753)
        XCTAssertEqual(first.overlapBeats, 64)
        XCTAssertEqual(first.outgoingSwapBeat, 270)
        XCTAssertEqual(first.incomingSwapBeat, 32)
        XCTAssertEqual(first.blendStartSeconds, 173.87837804159568)
        XCTAssertEqual(first.swapSeconds, 197.24420019525732)
        XCTAssertEqual(first.blendEndSeconds, 220.610022348919)
        XCTAssertEqual(first.incomingOffsetSeconds, 173.77569620595946)
        let cut = try XCTUnwrap(StarterBlendCatalog.blends[2].edgePlans.last)
        XCTAssertEqual(cut.style, .phraseCut)
        XCTAssertEqual(cut.outgoingStartSeconds, 17.481796056227534)
        XCTAssertEqual(cut.incomingStartSeconds, 0)
        let rainy = try XCTUnwrap(StarterBlendCatalog.blends[5].edgePlans.first)
        XCTAssertEqual(rainy.style, .phraseCut)
        XCTAssertEqual(rainy.schedule()?.outgoingStart, 83.738989863914227)
        XCTAssertEqual(rainy.schedule()?.incomingStart, 0.401727281007933)
        XCTAssertEqual(cut.schedule()?.outgoingStart, 17.481796056227534)
        XCTAssertEqual(cut.schedule()?.incomingStart, 0)
        XCTAssertEqual(cut.overlapBeats, 0)
        let drop = StarterBlendCatalog.blends[1].edgePlans[3]
        XCTAssertEqual(drop.style, .doubleDrop)
        XCTAssertEqual(drop.outgoingSwapBeat, 324)
        XCTAssertEqual(drop.incomingSwapBeat, 131)
    }

    func testAssetsComeFromTheImmutableReleaseNeverJamendo() throws {
        let pack = StarterBlendCatalog.pack
        XCTAssertEqual(pack.releaseTag, "starter-blends-aac-v1")
        XCTAssertEqual(pack.assetURL(trackID: "337997")?.absoluteString,
                       "https://github.com/johnarleyburns/parso-tonearm/releases/download/starter-blends-aac-v1/337997.m4a")
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
            XCTAssertEqual(blend.document.pack, .v1)
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
        XCTAssertEqual(request.pack, .v1)
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
            ids.dropLast().map { CatalogPlaybackMetadata(trackID: $0, title: "T", artist: "A", genre: "g", artworkURL: nil) }
        }))
    }
}
