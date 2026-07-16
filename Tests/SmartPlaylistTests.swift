import XCTest

@testable import TonearmCore

final class SmartPlaylistTests: XCTestCase {
    func testEvaluatorAndSQLCompilerAgreeForEveryFieldAndOperator() async throws {
        let fixture = try await SmartPlaylistFixture.seed()
        let rows = try await fixture.store.allTrackRows()

        for field in SmartPlaylistField.allCases {
            for op in SmartPlaylistOperator.allCases {
                let playlist = SmartPlaylist(
                    root: SmartPlaylistRuleGroup(predicates: [
                        .rule(rule(field: field, op: op)),
                    ]),
                    sort: SmartPlaylist.Sort(field: .title, direction: .ascending))

                try await assertEvaluatorAndCompilerAgree(
                    playlist,
                    rows: rows,
                    store: fixture.store,
                    label: "\(field.rawValue).\(op.rawValue)")
            }
        }
    }

    func testNestedGroupsRequireAnyWithinAll() async throws {
        let fixture = try await SmartPlaylistFixture.seed()
        let rows = try await fixture.store.allTrackRows()
        let playlist = SmartPlaylist(
            root: SmartPlaylistRuleGroup(conjunction: .all, predicates: [
                .group(SmartPlaylistRuleGroup(conjunction: .any, predicates: [
                    .rule(SmartPlaylistRule(field: .title, op: .contains, value: .text("sinner"))),
                    .rule(SmartPlaylistRule(field: .album, op: .contains, value: .text("substrata"))),
                ])),
                .group(SmartPlaylistRuleGroup(conjunction: .any, predicates: [
                    .rule(SmartPlaylistRule(field: .codec, op: .equals, value: .text("flac"))),
                    .rule(SmartPlaylistRule(field: .codec, op: .equals, value: .text("mp3"))),
                ])),
            ]),
            sort: SmartPlaylist.Sort(field: .title, direction: .ascending))

        let ids = try await assertEvaluatorAndCompilerAgree(playlist, rows: rows, store: fixture.store)

        XCTAssertEqual(ids, [fixture.ids.kobresia, fixture.ids.sinnerman])
    }

    func testEmptyRuleSetMatchesWholeLibrary() async throws {
        let fixture = try await SmartPlaylistFixture.seed()
        let rows = try await fixture.store.allTrackRows()
        let playlist = SmartPlaylist(
            root: SmartPlaylistRuleGroup(),
            sort: SmartPlaylist.Sort(field: .title, direction: .ascending))

        let ids = try await assertEvaluatorAndCompilerAgree(playlist, rows: rows, store: fixture.store)

        XCTAssertEqual(ids, [
            fixture.ids.acroyear,
            fixture.ids.guestCut,
            fixture.ids.kobresia,
            fixture.ids.sinnerman,
            fixture.ids.untitled,
        ])
    }

    func testContradictoryRulesReturnNoRows() async throws {
        let fixture = try await SmartPlaylistFixture.seed()
        let rows = try await fixture.store.allTrackRows()
        let playlist = SmartPlaylist(
            root: SmartPlaylistRuleGroup(conjunction: .all, predicates: [
                .rule(SmartPlaylistRule(field: .title, op: .equals, value: .text("Sinnerman"))),
                .rule(SmartPlaylistRule(field: .title, op: .equals, value: .text("Kobresia"))),
            ]))

        let ids = try await assertEvaluatorAndCompilerAgree(playlist, rows: rows, store: fixture.store)

        XCTAssertEqual(ids, [])
    }

    func testLimitAndSortInteractAfterFiltering() async throws {
        let fixture = try await SmartPlaylistFixture.seed()
        let rows = try await fixture.store.allTrackRows()
        let playlist = SmartPlaylist(
            root: SmartPlaylistRuleGroup(),
            sort: SmartPlaylist.Sort(field: .year, direction: .descending),
            limit: 2)

        let ids = try await assertEvaluatorAndCompilerAgree(playlist, rows: rows, store: fixture.store)

        XCTAssertEqual(ids, [fixture.ids.guestCut, fixture.ids.acroyear])
    }

    func testNilFieldValuesUseExplicitEmptySemantics() async throws {
        let fixture = try await SmartPlaylistFixture.seed()
        let rows = try await fixture.store.allTrackRows()
        let cases: [(String, SmartPlaylist, [Int64])] = [
            (
                "missing composer",
                SmartPlaylist(root: SmartPlaylistRuleGroup(predicates: [
                    .rule(SmartPlaylistRule(field: .composer, op: .isEmpty)),
                ]), sort: SmartPlaylist.Sort(field: .title, direction: .ascending)),
                [fixture.ids.guestCut, fixture.ids.kobresia, fixture.ids.untitled]
            ),
            (
                "missing asset location",
                SmartPlaylist(root: SmartPlaylistRuleGroup(predicates: [
                    .rule(SmartPlaylistRule(field: .assetLocation, op: .isEmpty)),
                ]), sort: SmartPlaylist.Sort(field: .title, direction: .ascending)),
                [fixture.ids.untitled]
            ),
            (
                "missing year",
                SmartPlaylist(root: SmartPlaylistRuleGroup(predicates: [
                    .rule(SmartPlaylistRule(field: .year, op: .isEmpty)),
                ]), sort: SmartPlaylist.Sort(field: .title, direction: .ascending)),
                [fixture.ids.untitled]
            ),
            (
                "missing artist",
                SmartPlaylist(root: SmartPlaylistRuleGroup(predicates: [
                    .rule(SmartPlaylistRule(field: .artist, op: .isEmpty)),
                ]), sort: SmartPlaylist.Sort(field: .title, direction: .ascending)),
                [fixture.ids.untitled]
            ),
            (
                "nil fields do not contain absent text",
                SmartPlaylist(root: SmartPlaylistRuleGroup(predicates: [
                    .rule(SmartPlaylistRule(field: .composer, op: .notContains, value: .text("nina"))),
                ]), sort: SmartPlaylist.Sort(field: .title, direction: .ascending)),
                [fixture.ids.acroyear, fixture.ids.guestCut, fixture.ids.kobresia, fixture.ids.untitled]
            ),
        ]

        for (label, playlist, expected) in cases {
            let ids = try await assertEvaluatorAndCompilerAgree(
                playlist,
                rows: rows,
                store: fixture.store,
                label: label)
            XCTAssertEqual(ids, expected, label)
        }
    }

    func testEvaluatorHandlesTenThousandTracksWithinInteractiveBudget() {
        let rows = (0..<10_000).map(performanceRow)
        let playlist = SmartPlaylist(
            root: SmartPlaylistRuleGroup(conjunction: .all, predicates: [
                .rule(SmartPlaylistRule(field: .genre, op: .equals, value: .text("ambient"))),
                .rule(SmartPlaylistRule(field: .year, op: .greaterThanOrEqual, value: .number(2000))),
                .rule(SmartPlaylistRule(field: .durationSeconds, op: .lessThan, value: .number(600))),
            ]),
            sort: SmartPlaylist.Sort(field: .title, direction: .ascending),
            limit: 50)

        let startedAt = Date()
        let result = playlist.evaluate(rows: rows)
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(result.count, 50)
        XCTAssertEqual(result.first?.track.title, "Track 00010")
        XCTAssertLessThan(elapsed, 2.0)
    }

    @discardableResult
    private func assertEvaluatorAndCompilerAgree(_ playlist: SmartPlaylist,
                                                 rows: [TrackRow],
                                                 store: LibraryStore,
                                                 label: String = "") async throws -> [Int64] {
        let evaluated = playlist.evaluate(rows: rows).map(\.id)
        let compiled = try await store.smartPlaylistRows(playlist).map(\.id)
        XCTAssertEqual(evaluated, compiled, label)
        return evaluated
    }

    private func performanceRow(index: Int) -> TrackRow {
        let track = Track(
            id: Int64(index + 1),
            albumId: Int64(index + 1),
            sourceId: 1,
            title: String(format: "Track %05d", index),
            trackNo: index + 1,
            discNo: 1,
            durationSec: Double(180 + (index % 480)),
            codec: index.isMultiple(of: 3) ? "FLAC" : "MP3",
            sampleRate: 44_100,
            bitDepthOrBitrate: nil,
            sortKey: String(format: "%05d", index),
            genre: index.isMultiple(of: 2) ? "Ambient" : "Rock")
        let album = Album(
            id: Int64(index + 1),
            sourceId: 1,
            title: "Album \(index / 10)",
            artist: "Artist \(index % 50)",
            year: 1990 + (index % 40),
            artworkId: nil)
        let source = Source(
            id: 1,
            kind: .local,
            iaIdentifier: nil,
            originalURL: nil,
            title: "Performance Fixture",
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastResolvedAt: nil,
            followUpdates: false,
            licenseText: nil,
            memberCapHit: false)
        return TrackRow(track: track, album: album, source: source, asset: nil)
    }

    private func rule(field: SmartPlaylistField, op: SmartPlaylistOperator) -> SmartPlaylistRule {
        let value = valueForRule(field: field, op: op)
        let upper = op == .between ? upperValueForBetween(field: field) : nil
        return SmartPlaylistRule(field: field, op: op, value: value, upperValue: upper)
    }

    private func valueForRule(field: SmartPlaylistField, op: SmartPlaylistOperator) -> SmartPlaylistValue? {
        switch op {
        case .isEmpty, .isNotEmpty:
            return nil
        case .notContains, .notEquals:
            switch field.kind {
            case .text: return .text("definitely absent")
            case .number: return .number(999_999)
            }
        case .contains:
            return textProbe(for: field, fallback: "19")
        case .beginsWith:
            return textProbe(for: field, fallback: "1")
        case .endsWith:
            return textProbe(for: field, fallback: "0")
        case .equals:
            return exactProbe(for: field)
        case .greaterThan:
            return numericProbe(for: field, fallback: 1)
        case .greaterThanOrEqual:
            return numericProbe(for: field, fallback: 1)
        case .lessThan:
            return numericUpperProbe(for: field, fallback: 9_999_999_999)
        case .lessThanOrEqual:
            return numericUpperProbe(for: field, fallback: 9_999_999_999)
        case .between:
            return numericProbe(for: field, fallback: 1)
        }
    }

    private func upperValueForBetween(field: SmartPlaylistField) -> SmartPlaylistValue {
        numericUpperProbe(for: field, fallback: 9_999_999_999)
    }

    private func textProbe(for field: SmartPlaylistField, fallback: String) -> SmartPlaylistValue {
        switch field {
        case .title: return .text("sinner")
        case .artist: return .text("nina")
        case .album: return .text("pastel")
        case .genre: return .text("jazz")
        case .composer: return .text("nina")
        case .codec: return .text("flac")
        case .sourceTitle: return .text("vault")
        case .sourceKind: return .text("local")
        case .assetKind: return .text("localref")
        case .assetLocation: return .text("hidden")
        case .year: return .text("196")
        case .durationSeconds: return .text("62")
        case .trackNumber: return .text("1")
        case .discNumber: return .text("1")
        case .sampleRate: return .text("441")
        case .sizeBytes: return .text("102")
        case .replayGain: return .text("6")
        case .dateAdded: return .text(fallback)
        }
    }

    private func exactProbe(for field: SmartPlaylistField) -> SmartPlaylistValue {
        switch field {
        case .title: return .text("Sinnerman")
        case .artist: return .text("Nina Simone")
        case .album: return .text("Pastel Blues")
        case .genre: return .text("Jazz")
        case .composer: return .text("Nina Simone")
        case .codec: return .text("FLAC")
        case .sourceTitle: return .text("Local Vault")
        case .sourceKind: return .text(SourceKind.local.rawValue)
        case .assetKind: return .text(AssetKind.localRef.rawValue)
        case .assetLocation: return .text("/Music/Hidden Filename.flac")
        case .year: return .number(1965)
        case .durationSeconds: return .number(620)
        case .trackNumber: return .number(1)
        case .discNumber: return .number(1)
        case .sampleRate: return .number(44_100)
        case .sizeBytes: return .number(1_024)
        case .replayGain: return .number(-6.5)
        case .dateAdded: return .number(1_700_000_000)
        }
    }

    private func numericProbe(for field: SmartPlaylistField, fallback: Double) -> SmartPlaylistValue {
        switch field {
        case .year: return .number(1960)
        case .durationSeconds: return .number(300)
        case .trackNumber: return .number(0)
        case .discNumber: return .number(0)
        case .sampleRate: return .number(40_000)
        case .sizeBytes: return .number(1_000)
        case .replayGain: return .number(-7)
        case .dateAdded: return .number(1_699_999_999)
        default: return .number(fallback)
        }
    }

    private func numericUpperProbe(for field: SmartPlaylistField, fallback: Double) -> SmartPlaylistValue {
        switch field {
        case .year: return .number(2_001)
        case .durationSeconds: return .number(700)
        case .trackNumber: return .number(4)
        case .discNumber: return .number(3)
        case .sampleRate: return .number(100_000)
        case .sizeBytes: return .number(10_000)
        case .replayGain: return .number(0)
        case .dateAdded: return .number(1_700_000_100)
        default: return .number(fallback)
        }
    }
}

private struct SmartPlaylistFixture {
    struct IDs {
        var sinnerman: Int64
        var kobresia: Int64
        var untitled: Int64
        var guestCut: Int64
        var acroyear: Int64
    }

    var store: LibraryStore
    var ids: IDs

    static func seed() async throws -> SmartPlaylistFixture {
        let store = try LibraryStore(inMemory: true)
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        let local = try await store.insertSource(source(
            kind: .local,
            title: "Local Vault",
            date: baseDate))
        let subsonic = try await store.insertSource(source(
            kind: .subsonic,
            title: "Basement Server",
            date: baseDate.addingTimeInterval(10)))
        let blank = try await store.insertSource(source(
            kind: .local,
            title: "Blank Import",
            date: baseDate.addingTimeInterval(20)))
        let compilation = try await store.insertSource(source(
            kind: .iaItem,
            title: "Compilation Source",
            date: baseDate.addingTimeInterval(30)))
        let hiRes = try await store.insertSource(source(
            kind: .local,
            title: "Hi-Res Shelf",
            date: baseDate.addingTimeInterval(40)))

        let nina = try await store.insertArtist(artist("Nina Simone"))
        let biosphere = try await store.insertArtist(artist("Biosphere"))
        let autechre = try await store.insertArtist(artist("Autechre"))

        let pastel = try await store.insertAlbum(Album(
            id: nil,
            sourceId: try XCTUnwrap(local.id),
            title: "Pastel Blues",
            artist: "Nina Simone",
            artistId: nina.id,
            albumArtist: "Nina Simone",
            genre: "Soul",
            year: 1965,
            artworkId: nil))
        let substrata = try await store.insertAlbum(Album(
            id: nil,
            sourceId: try XCTUnwrap(subsonic.id),
            title: "Substrata",
            artist: "Biosphere",
            artistId: biosphere.id,
            albumArtist: "Biosphere",
            genre: "Ambient",
            year: 1997,
            artworkId: nil))
        let mixtape = try await store.insertAlbum(Album(
            id: nil,
            sourceId: try XCTUnwrap(compilation.id),
            title: "The Mixtape",
            artist: "Various Artists",
            artistId: nil,
            albumArtist: "Various Artists",
            genre: nil,
            year: 2000,
            artworkId: nil))
        let lp5 = try await store.insertAlbum(Album(
            id: nil,
            sourceId: try XCTUnwrap(hiRes.id),
            title: "LP5",
            artist: "Autechre",
            artistId: autechre.id,
            albumArtist: "Autechre",
            genre: "Electronic",
            year: 1998,
            artworkId: nil))

        let sinnerman = try await store.insertTrack(Track(
            id: nil,
            albumId: pastel.id,
            sourceId: try XCTUnwrap(local.id),
            title: "Sinnerman",
            trackNo: 1,
            discNo: 1,
            durationSec: 620,
            codec: "FLAC",
            sampleRate: 44_100,
            bitDepthOrBitrate: "16-bit",
            sortKey: "0001",
            genre: "Jazz",
            composer: "Nina Simone",
            artistId: nina.id,
            rgTrackGain: -6.5))
        let kobresia = try await store.insertTrack(Track(
            id: nil,
            albumId: substrata.id,
            sourceId: try XCTUnwrap(subsonic.id),
            title: "Kobresia",
            trackNo: 2,
            discNo: 1,
            durationSec: 428,
            codec: "MP3",
            sampleRate: 48_000,
            bitDepthOrBitrate: "320",
            sortKey: "0002",
            genre: nil,
            composer: nil,
            artistId: biosphere.id,
            rgTrackGain: -8.0))
        let untitled = try await store.insertTrack(Track(
            id: nil,
            albumId: nil,
            sourceId: try XCTUnwrap(blank.id),
            title: "Untitled",
            trackNo: nil,
            discNo: nil,
            durationSec: nil,
            codec: nil,
            sampleRate: nil,
            bitDepthOrBitrate: nil,
            sortKey: "9999",
            genre: nil,
            composer: nil,
            artistId: nil))
        let guestCut = try await store.insertTrack(Track(
            id: nil,
            albumId: mixtape.id,
            sourceId: try XCTUnwrap(compilation.id),
            title: "Guest Cut",
            trackNo: 4,
            discNo: 1,
            durationSec: 222,
            codec: "AAC",
            sampleRate: 44_100,
            bitDepthOrBitrate: "256",
            sortKey: "0004",
            genre: "Pop",
            composer: nil,
            artistId: nil))
        let acroyear = try await store.insertTrack(Track(
            id: nil,
            albumId: lp5.id,
            sourceId: try XCTUnwrap(hiRes.id),
            title: "Acroyear2",
            trackNo: 3,
            discNo: 2,
            durationSec: 401,
            codec: "ALAC",
            sampleRate: 96_000,
            bitDepthOrBitrate: "24-bit",
            sortKey: "0003",
            genre: "Electronic",
            composer: "Autechre",
            artistId: autechre.id,
            rgTrackGain: -3.25))

        let sinnermanID = try XCTUnwrap(sinnerman.id)
        let kobresiaID = try XCTUnwrap(kobresia.id)
        let guestCutID = try XCTUnwrap(guestCut.id)
        let acroyearID = try XCTUnwrap(acroyear.id)
        _ = try await store.insertAsset(Asset(
            id: nil,
            trackId: sinnermanID,
            kind: .localRef,
            bookmark: nil,
            relPath: "/Music/Hidden Filename.flac",
            remoteURL: nil,
            altRemoteURL: nil,
            sizeBytes: 1_024,
            unsupportedReason: nil))
        _ = try await store.insertAsset(Asset(
            id: nil,
            trackId: kobresiaID,
            kind: .remote,
            bookmark: nil,
            relPath: nil,
            remoteURL: "https://example.test/kobresia.mp3",
            altRemoteURL: nil,
            sizeBytes: 2_048,
            unsupportedReason: nil))
        _ = try await store.insertAsset(Asset(
            id: nil,
            trackId: guestCutID,
            kind: .remote,
            bookmark: nil,
            relPath: nil,
            remoteURL: nil,
            altRemoteURL: "https://example.test/guest-cut.m4a",
            sizeBytes: 512,
            unsupportedReason: nil))
        _ = try await store.insertAsset(Asset(
            id: nil,
            trackId: acroyearID,
            kind: .managedCopy,
            bookmark: nil,
            relPath: "Managed/Acroyear2.m4a",
            remoteURL: nil,
            altRemoteURL: nil,
            sizeBytes: 4_096,
            unsupportedReason: nil))

        return SmartPlaylistFixture(
            store: store,
            ids: IDs(
                sinnerman: sinnermanID,
                kobresia: kobresiaID,
                untitled: try XCTUnwrap(untitled.id),
                guestCut: guestCutID,
                acroyear: acroyearID))
    }

    private static func source(kind: SourceKind, title: String, date: Date) -> Source {
        Source(
            id: nil,
            kind: kind,
            iaIdentifier: nil,
            originalURL: nil,
            title: title,
            addedAt: date,
            lastResolvedAt: nil,
            followUpdates: false,
            licenseText: nil,
            memberCapHit: false)
    }

    private static func artist(_ name: String) -> Artist {
        Artist(id: nil, name: name, sortName: name, syncID: UUID().uuidString)
    }
}
