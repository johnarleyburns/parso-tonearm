import XCTest
@testable import TonearmCore

/// Pins the free/paid split so later phases can't silently gate a free feature.
/// Commit 0.4 retires the last paid case (`remoteLibraries`, FR-LIB-7): nothing
/// is paid yet, so the paid set is empty — the honest intermediate state until
/// the DJ capability lands with `EntitlementStore` (Appendix T.3). The free
/// list is the promise in §2.4, machine-checked: any capability on it is free,
/// forever, and the build fails if anyone ever re-gates one.
final class FreeTierRegistryTests: XCTestCase {

    func testProFeatureCasesAreExactlyThePaidCapabilities() {
        XCTAssertTrue(
            ProFeature.allCases.isEmpty,
            "Commit 0.4 retires remoteLibraries; nothing is paid yet (Appendix T.3)"
        )
    }

    func testExpandedFreeListIsNeverAProFeature() {
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
            "semanticSearch",
            "smartCrates",
            "autoPlaylists",
            "analysisStage1",
            "analysisStage2",
            "analysisReadout",
            "mixPlayback",
        ]
        let gated = Set(ProFeature.allCases.map { String(describing: $0) })
        for capability in freeCapabilities {
            XCTAssertFalse(gated.contains(capability),
                           "\(capability) is free and must not be gated")
        }
    }

    func testGatedCountIsStable() {
        XCTAssertEqual(ProFeature.allCases.count, 0)
    }
}
