import XCTest
@testable import TonearmCore

/// Pins the free/paid split so later phases can't silently gate a free feature.
/// Commit 0.5 lands the DJ capability set (`ProCapability`, Appendix T.3), so
/// the paid set is no longer empty: it is exactly the seven performing
/// capabilities. The free list is the promise in §2.4, machine-checked: any
/// capability on it is free, forever, and the build fails if anyone ever
/// re-gates one.
final class FreeTierRegistryTests: XCTestCase {

    func testProCapabilityCasesAreExactlyThePaidCapabilities() {
        let expectedPaid: Set<String> = [
            "decks", "mixer", "stems", "recording", "hardware", "preparation", "gigCrates",
        ]
        XCTAssertEqual(
            Set(ProCapability.allCases.map(\.rawValue)),
            expectedPaid,
            "ProCapability is the complete paid set (Appendix T.3)"
        )
    }

    func testExpandedFreeListIsNeverAPaidCapability() {
        let freeCapabilities = [
            // — pre-existing free conveniences —
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
            "bitPerfect",
            // — freed by M0 (§2.4, Appendix T.5) —
            "remoteLibraries",
            "remoteLibraryArchiveOrg",
            "remoteLibraryDropbox",
            "remoteLibraryGoogleDrive",
            "remoteLibraryOneDrive",
            "remoteLibraryPCloud",
            "remoteLibrarySubsonic",
            "remoteLibraryWebDAV",
            "remoteLibraryJellyfin",
            "remoteLibraryPlex",
            "remoteLibrarySMB",
            "remoteLibraryJamendo",
            "semanticSearch",
            "smartCrates",
            "autoPlaylists",
            "analysisStage1",
            "analysisStage2",
            "analysisReadout",
            "mixPlayback",
        ]
        let gated = Set(ProCapability.allCases.map(\.rawValue))
        for capability in freeCapabilities {
            XCTAssertFalse(gated.contains(capability),
                           "\(capability) is free and must not be gated")
        }
    }

    func testGatedCountIsStable() {
        XCTAssertEqual(ProCapability.allCases.count, 7)
    }
}
