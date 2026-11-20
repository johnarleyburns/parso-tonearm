import Testing

@testable import TonearmCore

@Suite struct CrossfadeCurveTests {
    @Test func testEqualPowerMaintainsConstantPower() {
        for position in stride(from: 90.0, through: 100.0, by: 1.0) {
            let gains = CrossfadeCurve.gains(position: position,
                                             duration: 100,
                                             fadeSeconds: 10,
                                             curve: .equalPower)
            #expect(abs(gains.outgoing * gains.outgoing + gains.incoming * gains.incoming - 1) <= 0.000_001)
        }
    }

    @Test func testEndpointsAreExact() {
        let start = CrossfadeCurve.gains(position: 90,
                                         duration: 100,
                                         fadeSeconds: 10,
                                         curve: .equalPower)
        #expect(start.active)
        #expect(start.outgoing == 1)
        #expect(start.incoming == 0)

        let end = CrossfadeCurve.gains(position: 100,
                                       duration: 100,
                                       fadeSeconds: 10,
                                       curve: .equalPower)
        #expect(end.active)
        #expect(end.outgoing == 0)
        #expect(end.incoming == 1)
    }

    @Test func testLinearCurveMidpoint() {
        let gains = CrossfadeCurve.gains(position: 95,
                                         duration: 100,
                                         fadeSeconds: 10,
                                         curve: .linear)

        #expect(gains.active)
        #expect(gains.outgoing == 0.5)
        #expect(gains.incoming == 0.5)
    }

    @Test func testFadeLongerThanTrackUsesWholeTrack() {
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

        #expect(start == .init(outgoing: 1, incoming: 0, active: true))
        #expect(middle == .init(outgoing: 0.5, incoming: 0.5, active: true))
        #expect(end == .init(outgoing: 0, incoming: 1, active: true))
    }

    @Test func testZeroLengthFadeIsInactive() {
        #expect(CrossfadeCurve.gains(position: 0,
                                            duration: 100,
                                            fadeSeconds: 0,
                                            curve: .equalPower)
                       == .init(outgoing: 1, incoming: 0, active: false))
        #expect(CrossfadeCurve.gains(position: 100,
                                            duration: 100,
                                            fadeSeconds: 0,
                                            curve: .equalPower)
                       == .init(outgoing: 1, incoming: 0, active: false))
    }

    @Test func testGaplessAlbumDetectionSuppressesAdjacentAlbumTracks() {
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

        #expect(CrossfadeCurve.suppressesForGaplessAlbum(current: current, next: next))
    }

    @Test func testGaplessAlbumDetectionSuppressesDiscBoundary() {
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

        #expect(CrossfadeCurve.suppressesForGaplessAlbum(current: current, next: next))
    }

    @Test func testGaplessAlbumDetectionUsesFallbackIdentity() {
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

        #expect(CrossfadeCurve.suppressesForGaplessAlbum(current: current, next: next))
    }

    @Test func testGaplessAlbumDetectionIgnoresUnnumberedCollectionBuckets() {
        // Mood Starter genre albums: one album id, no album artist, no track numbers.
        let current = CrossfadeCurve.AlbumContinuity(albumID: 7, sourceID: 1, albumTitle: "Folk",
                                                     albumArtist: nil, discNumber: nil, trackNumber: nil)
        let next = CrossfadeCurve.AlbumContinuity(albumID: 7, sourceID: 1, albumTitle: "Folk",
                                                  albumArtist: nil, discNumber: nil, trackNumber: nil)

        #expect(!CrossfadeCurve.suppressesForGaplessAlbum(current: current, next: next))
    }

    @Test func testGaplessAlbumDetectionDoesNotSuppressDifferentOrNonAdjacentAlbums() {
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

        #expect(!CrossfadeCurve.suppressesForGaplessAlbum(current: current, next: differentAlbum))
        #expect(!CrossfadeCurve.suppressesForGaplessAlbum(current: current, next: nonAdjacent))
    }
}
