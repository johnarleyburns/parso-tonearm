import XCTest
@testable import TonearmCore

/// Pins the free/paid split so later phases can't silently gate a free feature.
final class FreeTierRegistryTests: XCTestCase {

    func testProFeatureCasesAreExactlyThePaidCapabilities() {
        let actual = Set(ProFeature.allCases.map { $0.rawValue })
        let expected: Set<String> = [
            "remoteLibraries"
        ]
        XCTAssertEqual(actual, expected)
    }

    func testExpandedFreeListIsNeverAProFeature() {
        let freeCapabilities = [
            "flac",
            "opus",
            "alac",
            "mp3",
            "aac",
            "wav",
            "aiff",
            "gapless",
            "eq",
            "replayGain",
            "crossfade",
            "cacheSize",
            "prefetchDepth",
            "folderWatch",
            "carplay",
            "libraryBrowse",
            "queueEditing",
            "playlistEditing",
            "localImport",
            "privacy",
            "icloudSync",
            "ipadMac",
            "proAudioTools",
            "smartPlaylists",
            "tagEditor",
            "duplicateDetection",
            "parametricEQ",
            "crossfeed",
            "convolution",
            "bitPerfect"
        ]
        let gated = Set(ProFeature.allCases.map { $0.rawValue.lowercased() })
        for capability in freeCapabilities {
            XCTAssertFalse(gated.contains(capability.lowercased()),
                           "\(capability) is free and must not be gated")
        }
    }

    func testGatedCountIsStable() {
        XCTAssertEqual(ProFeature.allCases.count, 1)
    }
}
