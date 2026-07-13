import XCTest

@testable import Tonearm

final class CrossfadeCurveTests: XCTestCase {
    func testEqualPowerMaintainsConstantPower() {
        for position in stride(from: 90.0, through: 100.0, by: 1.0) {
            let gains = CrossfadeCurve.gains(position: position,
                                             duration: 100,
                                             fadeSeconds: 10,
                                             curve: .equalPower)
            XCTAssertEqual(gains.outgoing * gains.outgoing + gains.incoming * gains.incoming,
                           1,
                           accuracy: 0.000_001)
        }
    }

    func testEndpointsAreExact() {
        let start = CrossfadeCurve.gains(position: 90,
                                         duration: 100,
                                         fadeSeconds: 10,
                                         curve: .equalPower)
        XCTAssertTrue(start.active)
        XCTAssertEqual(start.outgoing, 1)
        XCTAssertEqual(start.incoming, 0)

        let end = CrossfadeCurve.gains(position: 100,
                                       duration: 100,
                                       fadeSeconds: 10,
                                       curve: .equalPower)
        XCTAssertTrue(end.active)
        XCTAssertEqual(end.outgoing, 0)
        XCTAssertEqual(end.incoming, 1)
    }

    func testLinearCurveMidpoint() {
        let gains = CrossfadeCurve.gains(position: 95,
                                         duration: 100,
                                         fadeSeconds: 10,
                                         curve: .linear)

        XCTAssertTrue(gains.active)
        XCTAssertEqual(gains.outgoing, 0.5)
        XCTAssertEqual(gains.incoming, 0.5)
    }

    func testFadeLongerThanTrackUsesWholeTrack() {
        let start = CrossfadeCurve.gains(position: 0,
                                         duration: 4,
                                         fadeSeconds: 10,
                                         curve: .linear)
        let middle = CrossfadeCurve.gains(position: 2,
                                          duration: 4,
                                          fadeSeconds: 10,
                                          curve: .linear)
        let end = CrossfadeCurve.gains(position: 4,
                                       duration: 4,
                                       fadeSeconds: 10,
                                       curve: .linear)

        XCTAssertEqual(start, .init(outgoing: 1, incoming: 0, active: true))
        XCTAssertEqual(middle, .init(outgoing: 0.5, incoming: 0.5, active: true))
        XCTAssertEqual(end, .init(outgoing: 0, incoming: 1, active: true))
    }

    func testZeroLengthFadeIsInactive() {
        XCTAssertEqual(CrossfadeCurve.gains(position: 0,
                                            duration: 100,
                                            fadeSeconds: 0,
                                            curve: .equalPower),
                       .init(outgoing: 1, incoming: 0, active: false))
        XCTAssertEqual(CrossfadeCurve.gains(position: 100,
                                            duration: 100,
                                            fadeSeconds: 0,
                                            curve: .equalPower),
                       .init(outgoing: 1, incoming: 0, active: false))
    }

    func testGaplessAlbumDetectionSuppressesAdjacentAlbumTracks() {
        let current = CrossfadeCurve.AlbumContinuity(albumID: 7,
                                                     sourceID: 1,
                                                     albumTitle: "Live",
                                                     albumArtist: "Artist",
                                                     discNumber: 1,
                                                     trackNumber: 3)
        let next = CrossfadeCurve.AlbumContinuity(albumID: 7,
                                                  sourceID: 1,
                                                  albumTitle: "Live",
                                                  albumArtist: "Artist",
                                                  discNumber: 1,
                                                  trackNumber: 4)

        XCTAssertTrue(CrossfadeCurve.suppressesForGaplessAlbum(current: current, next: next))
    }

    func testGaplessAlbumDetectionSuppressesDiscBoundary() {
        let current = CrossfadeCurve.AlbumContinuity(albumID: 7,
                                                     sourceID: 1,
                                                     albumTitle: "Live",
                                                     albumArtist: "Artist",
                                                     discNumber: 1,
                                                     trackNumber: 12)
        let next = CrossfadeCurve.AlbumContinuity(albumID: 7,
                                                  sourceID: 1,
                                                  albumTitle: "Live",
                                                  albumArtist: "Artist",
                                                  discNumber: 2,
                                                  trackNumber: 1)

        XCTAssertTrue(CrossfadeCurve.suppressesForGaplessAlbum(current: current, next: next))
    }

    func testGaplessAlbumDetectionUsesFallbackIdentity() {
        let current = CrossfadeCurve.AlbumContinuity(albumID: nil,
                                                     sourceID: 1,
                                                     albumTitle: "Beyonce Live",
                                                     albumArtist: "Beyoncé",
                                                     discNumber: nil,
                                                     trackNumber: nil)
        let next = CrossfadeCurve.AlbumContinuity(albumID: nil,
                                                  sourceID: 1,
                                                  albumTitle: "beyonce live",
                                                  albumArtist: "beyonce",
                                                  discNumber: nil,
                                                  trackNumber: nil)

        XCTAssertTrue(CrossfadeCurve.suppressesForGaplessAlbum(current: current, next: next))
    }

    func testGaplessAlbumDetectionDoesNotSuppressDifferentOrNonAdjacentAlbums() {
        let current = CrossfadeCurve.AlbumContinuity(albumID: 7,
                                                     sourceID: 1,
                                                     albumTitle: "Live",
                                                     albumArtist: "Artist",
                                                     discNumber: 1,
                                                     trackNumber: 3)
        let differentAlbum = CrossfadeCurve.AlbumContinuity(albumID: 8,
                                                            sourceID: 1,
                                                            albumTitle: "Other",
                                                            albumArtist: "Artist",
                                                            discNumber: 1,
                                                            trackNumber: 4)
        let nonAdjacent = CrossfadeCurve.AlbumContinuity(albumID: 7,
                                                         sourceID: 1,
                                                         albumTitle: "Live",
                                                         albumArtist: "Artist",
                                                         discNumber: 1,
                                                         trackNumber: 5)

        XCTAssertFalse(CrossfadeCurve.suppressesForGaplessAlbum(current: current, next: differentAlbum))
        XCTAssertFalse(CrossfadeCurve.suppressesForGaplessAlbum(current: current, next: nonAdjacent))
    }
}
