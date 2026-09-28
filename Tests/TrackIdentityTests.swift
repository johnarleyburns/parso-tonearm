import XCTest
@testable import TonearmCore

final class TrackIdentityTests: XCTestCase {
    func testStrongIdentityIsStableAndDifferentFromMetadataIdentity() {
        let track = Track(id: 42, albumId: 9, sourceId: 1, title: "Night Drive",
                          trackNo: nil, discNo: nil, durationSec: 240,
                          codec: "mp3", sampleRate: nil, bitDepthOrBitrate: nil,
                          sortKey: "night drive", artistId: 7)
        let asset = Asset(id: 3, trackId: 42, kind: .remote, bookmark: nil,
                          relPath: nil, remoteURL: "https://archive.org/download/set/night-drive.mp3", altRemoteURL: nil,
                          sizeBytes: nil, unsupportedReason: nil)
        let source = Source(id: 1, kind: .iaItem, iaIdentifier: "set", originalURL: nil,
                            title: "Library", addedAt: Date(), lastResolvedAt: nil,
                            followUpdates: false, licenseText: nil, memberCapHit: false)
        let strong = TrackIdentity.keys(track: track, asset: asset, source: source)
        let metadata = TrackIdentity.keys(track: track, asset: nil, source: nil)
        XCTAssertEqual(strong.count, 2)
        XCTAssertEqual(metadata.count, 1)
        XCTAssertNotEqual(strong.first?.value, metadata.first?.value)
        XCTAssertEqual(strong.first?.strength, .source)
    }

    func testCompatibilityUnicodeNormalizesToTheSameMetadataIdentity() {
        let composed = Track(id: 1, albumId: 0, sourceId: 0, title: "ﬁancée",
                             trackNo: nil, discNo: nil, durationSec: 120, codec: "mp3",
                             sampleRate: nil, bitDepthOrBitrate: nil, sortKey: "fiancee", artistId: nil)
        let compatibility = Track(id: 2, albumId: 0, sourceId: 0, title: "fiancee",
                                  trackNo: nil, discNo: nil, durationSec: 120, codec: "mp3",
                                  sampleRate: nil, bitDepthOrBitrate: nil, sortKey: "fiancee", artistId: nil)
        XCTAssertEqual(TrackIdentity.keys(track: composed, asset: nil, source: nil),
                       TrackIdentity.keys(track: compatibility, asset: nil, source: nil))
    }
}
