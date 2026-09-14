#if !os(watchOS)
import XCTest

@testable import TonearmDiscovery

/// C04 Apple-host item (IMPLEMENT_CLAP_PLAN.md §8): the model-resource
/// resolver must return real URLs when the converted package + bundled mel
/// filterbank are present and `.unavailable` when they are not — never a
/// fabricated embedding path.
final class ModelResourceLocatorTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func touch(_ url: URL) throws {
        try Data().write(to: url)
    }

    private func makeDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func testResolvesBothWhenPresent() throws {
        let dir = try makeTempDir()
        try makeDir(dir.appendingPathComponent("CLAPAudioEncoder.mlpackage"))
        try touch(dir.appendingPathComponent("mel_filterbank_slaney_64.bin"))

        let resolved = ModelResourceLocator(searchDirectories: [dir]).resolve()

        XCTAssertEqual(
            resolved.audioEncoderURL?.lastPathComponent, "CLAPAudioEncoder.mlpackage")
        XCTAssertEqual(
            resolved.melFilterBankURL?.lastPathComponent, "mel_filterbank_slaney_64.bin")
    }

    func testUnavailableWhenAbsent() throws {
        let dir = try makeTempDir()

        let resolved = ModelResourceLocator(searchDirectories: [dir]).resolve()

        XCTAssertNil(resolved.audioEncoderURL)
        XCTAssertNil(resolved.melFilterBankURL)
    }

    func testPrefersCompiledMlmodelcOverMlpackage() throws {
        let dir = try makeTempDir()
        try makeDir(dir.appendingPathComponent("CLAPAudioEncoder.mlmodelc"))
        try makeDir(dir.appendingPathComponent("CLAPAudioEncoder.mlpackage"))
        try touch(dir.appendingPathComponent("mel_filterbank_slaney_64.bin"))

        let resolved = ModelResourceLocator(searchDirectories: [dir]).resolve()

        XCTAssertEqual(
            resolved.audioEncoderURL?.lastPathComponent, "CLAPAudioEncoder.mlmodelc")
    }

    func testFindsFilterbankInNestedCLAPSubdirectory() throws {
        let dir = try makeTempDir()
        try makeDir(dir.appendingPathComponent("CLAPAudioEncoder.mlpackage"))
        let clap = dir.appendingPathComponent("CLAP", isDirectory: true)
        try makeDir(clap)
        try touch(clap.appendingPathComponent("mel_filterbank_slaney_64.bin"))

        let resolved = ModelResourceLocator(searchDirectories: [dir]).resolve()

        XCTAssertEqual(
            resolved.melFilterBankURL?.lastPathComponent, "mel_filterbank_slaney_64.bin")
        XCTAssertTrue(resolved.melFilterBankURL?.path.contains("/CLAP/") ?? false)
    }

    // MARK: - Text encoder (session 10)

    func testResolvesTextTripletWhenPresent() throws {
        let dir = try makeTempDir()
        try makeDir(dir.appendingPathComponent("CLAPTextEncoder.mlpackage"))
        try touch(dir.appendingPathComponent("vocab.json"))
        try touch(dir.appendingPathComponent("merges.txt"))

        let resolved = ModelResourceLocator(searchDirectories: [dir]).resolve()

        XCTAssertEqual(resolved.textEncoderURL?.lastPathComponent, "CLAPTextEncoder.mlpackage")
        XCTAssertEqual(resolved.tokenizerVocabURL?.lastPathComponent, "vocab.json")
        XCTAssertEqual(resolved.tokenizerMergesURL?.lastPathComponent, "merges.txt")
    }

    func testPrefersCompiledTextMlmodelcAndFindsSidecarsInNestedCLAP() throws {
        let dir = try makeTempDir()
        try makeDir(dir.appendingPathComponent("CLAPTextEncoder.mlmodelc"))
        try makeDir(dir.appendingPathComponent("CLAPTextEncoder.mlpackage"))
        let clap = dir.appendingPathComponent("CLAP", isDirectory: true)
        try makeDir(clap)
        try touch(clap.appendingPathComponent("vocab.json"))
        try touch(clap.appendingPathComponent("merges.txt"))

        let resolved = ModelResourceLocator(searchDirectories: [dir]).resolve()

        XCTAssertEqual(resolved.textEncoderURL?.lastPathComponent, "CLAPTextEncoder.mlmodelc")
        XCTAssertTrue(resolved.tokenizerVocabURL?.path.contains("/CLAP/") ?? false)
        XCTAssertTrue(resolved.tokenizerMergesURL?.path.contains("/CLAP/") ?? false)
    }

    /// Text encoder present but a tokenizer sidecar missing: `ModelManager`
    /// must refuse with `.resourcesUnavailable` rather than fabricate.
    func testMissingTokenizerSidecarIsUnavailableToModelManager() async throws {
        let dir = try makeTempDir()
        try makeDir(dir.appendingPathComponent("CLAPTextEncoder.mlpackage"))
        try touch(dir.appendingPathComponent("vocab.json"))
        // merges.txt intentionally absent

        let resolved = ModelResourceLocator(searchDirectories: [dir]).resolve()
        XCTAssertNotNil(resolved.textEncoderURL)
        XCTAssertNil(resolved.tokenizerMergesURL)

        let manager = ModelManager(resourceProvider: { resolved })
        let available = await manager.isTextModelResourceAvailable()
        XCTAssertFalse(available)
        do {
            _ = try await manager.textEncoder(context: .foreground)
            XCTFail("expected .resourcesUnavailable with no merges.txt")
        } catch ModelManager.ModelManagerError.resourcesUnavailable {
            // expected
        }
    }

    func testTextEncoderUnavailableWhenNothingResolves() async throws {
        let dir = try makeTempDir()
        let manager = ModelManager(
            resourceProvider: { ModelResourceLocator(searchDirectories: [dir]).resolve() })
        do {
            _ = try await manager.textEncoder(context: .foreground)
            XCTFail("expected .resourcesUnavailable")
        } catch ModelManager.ModelManagerError.resourcesUnavailable {}
    }

    /// Encoder present but filterbank absent: the resolver reports the partial
    /// truth, and `ModelManager` treats it as unavailable (both are required).
    // MARK: - Bundle-based resolution (real device diagnostics, build 369)

    /// The actual root cause: a real device diagnostics export showed BOTH
    /// ODR tags reporting `beginAccessingResources` success ("finished")
    /// while `modelResourceAvailable` stayed false — the downloads
    /// completed, but a plain `FileManager.fileExists` check against a
    /// guessed path under `Bundle.main.resourceURL` could never find them,
    /// because Xcode mounts each ODR tag's content into a *hashed*,
    /// unpredictable asset-pack directory (a real CI archive log showed
    /// `guru.parso.tonearm.clap-text-956b7b876cac28a5d0622945cf9adb21.assetpack`).
    /// `Bundle.url(forResource:withExtension:)` is the only API that
    /// actually knows where that content lives — this proves the locator
    /// now uses it, and that it works, for a folder-type compiled resource
    /// name (`CLAPAudioEncoder.mlmodelc`).
    func testResolvesFolderResourceViaBundleAPI() throws {
        let dir = try makeTempDir()
        try makeDir(dir.appendingPathComponent("CLAPAudioEncoder.mlmodelc"))
        try touch(dir.appendingPathComponent("mel_filterbank_slaney_64.bin"))
        let bundle = try XCTUnwrap(Bundle(url: dir))

        // No searchDirectories at all — if this resolves, it can only be
        // because the bundle-API path found it, not the FileManager fallback.
        let resolved = ModelResourceLocator(searchDirectories: [], bundle: bundle).resolve()

        XCTAssertEqual(resolved.audioEncoderURL?.lastPathComponent, "CLAPAudioEncoder.mlmodelc")
        XCTAssertEqual(resolved.melFilterBankURL?.lastPathComponent, "mel_filterbank_slaney_64.bin")
    }

    /// A tokenizer sidecar (no meaningful "extension" beyond its real file
    /// extension, e.g. `vocab.json`) must also resolve through the bundle
    /// API, not just folder-type `.mlmodelc` resources.
    func testResolvesFileResourceWithExtensionViaBundleAPI() throws {
        let dir = try makeTempDir()
        try touch(dir.appendingPathComponent("vocab.json"))
        let bundle = try XCTUnwrap(Bundle(url: dir))

        let resolved = ModelResourceLocator(searchDirectories: [], bundle: bundle).resolve()

        XCTAssertEqual(resolved.tokenizerVocabURL?.lastPathComponent, "vocab.json")
    }

    /// Content nested under a subdirectory (mirrors `Resources/CLAP/` in
    /// some bundle layouts) must resolve via `Bundle.url(forResource:
    /// withExtension:subdirectory:)`, not just at the bundle root.
    func testResolvesNestedSubdirectoryResourceViaBundleAPI() throws {
        let dir = try makeTempDir()
        let clap = dir.appendingPathComponent("CLAP", isDirectory: true)
        try makeDir(clap)
        try touch(clap.appendingPathComponent("merges.txt"))
        let bundle = try XCTUnwrap(Bundle(url: dir))

        let resolved = ModelResourceLocator(searchDirectories: [], bundle: bundle).resolve()

        XCTAssertEqual(resolved.tokenizerMergesURL?.lastPathComponent, "merges.txt")
    }

    /// The bundle-API path is tried FIRST, but a plain filesystem
    /// `searchDirectories` fallback must still work when no bundle is
    /// supplied at all — the dev-checkout/test scenario every other test
    /// in this file already covers, now re-confirmed unchanged by this
    /// fix's `if let bundle` guard.
    func testFallsBackToFileManagerWhenNoBundleSupplied() throws {
        let dir = try makeTempDir()
        try makeDir(dir.appendingPathComponent("CLAPAudioEncoder.mlpackage"))

        let resolved = ModelResourceLocator(searchDirectories: [dir], bundle: nil).resolve()

        XCTAssertEqual(resolved.audioEncoderURL?.lastPathComponent, "CLAPAudioEncoder.mlpackage")
    }

    func testMissingFilterbankIsUnavailableToModelManager() async throws {
        let dir = try makeTempDir()
        try makeDir(dir.appendingPathComponent("CLAPAudioEncoder.mlpackage"))

        let resolved = ModelResourceLocator(searchDirectories: [dir]).resolve()
        XCTAssertNotNil(resolved.audioEncoderURL)
        XCTAssertNil(resolved.melFilterBankURL)

        let manager = ModelManager(resourceProvider: { resolved })
        let available = await manager.isModelResourceAvailable()
        // Both artefacts are required, so the cheap availability check is false.
        XCTAssertFalse(available)
        // And actually loading the encoder must refuse rather than fabricate.
        do {
            _ = try await manager.audioEncoder(context: .foreground)
            XCTFail("expected .resourcesUnavailable with no mel filterbank")
        } catch ModelManager.ModelManagerError.resourcesUnavailable {
            // expected
        }
    }
}
#endif
