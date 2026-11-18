#if !os(watchOS)
import Testing

@testable import TonearmDiscovery

/// C04 Apple-host item (IMPLEMENT_CLAP_PLAN.md §8): the model-resource
/// resolver must return real URLs when the converted package + bundled mel
/// filterbank are present and `.unavailable` when they are not — never a
/// fabricated embedding path.
@Suite struct ModelResourceLocatorTests {
    // NOTE(swift-testing-migration): the original XCTest helper registered
    // `addTeardownBlock { try? FileManager.default.removeItem(at: dir) }` here, which XCTest
    // runs after the whole test method finishes, no matter which function requested it. Swift
    // Testing has no per-test teardown-block registry, and a `defer` placed inside this helper
    // would fire when this helper function returns (deleting the directory before the caller
    // ever uses it) — not an equivalent translation. Each call site below now does
    // `let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }`
    // immediately after calling this helper, which reproduces the original "clean up after this
    // test" behavior at the correct (test-function) scope.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func touch(_ url: URL) throws {
        try Data().write(to: url)
    }

    private func makeDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Issue #201: both compiled CLAP packages resolve from a main-bundle-style
    /// fixture (compiled `.mlmodelc` preferred over raw `.mlpackage`), with no
    /// On-Demand Resource request involved.
    @Test func testResolvesBothCompiledCLAPPackagesFromBundleStyleFixture() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["CLAPAudioEncoder", "CLAPTextEncoder"] {
            try makeDir(dir.appendingPathComponent("\(name).mlmodelc"))
            try makeDir(dir.appendingPathComponent("\(name).mlpackage"))
        }
        let bundle = try #require(Bundle(url: dir))
        let resolved = ModelResourceLocator(searchDirectories: [dir], bundle: bundle).resolve()
        #expect(resolved.audioEncoderURL?.lastPathComponent == "CLAPAudioEncoder.mlmodelc")
        #expect(resolved.textEncoderURL?.lastPathComponent == "CLAPTextEncoder.mlmodelc")
    }

    /// Issue #201: a missing package is honest unavailability, not an acquisition.
    @Test func testMissingCLAPPackagesResolveUnavailable() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try #require(Bundle(url: dir))
        let resolved = ModelResourceLocator(searchDirectories: [dir], bundle: bundle).resolve()
        #expect(resolved.audioEncoderURL == nil)
        #expect(resolved.textEncoderURL == nil)
    }

    @Test func testResolvesBothWhenPresent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeDir(dir.appendingPathComponent("CLAPAudioEncoder.mlpackage"))
        try touch(dir.appendingPathComponent("mel_filterbank_slaney_64.bin"))

        let resolved = ModelResourceLocator(searchDirectories: [dir]).resolve()

        #expect(
            resolved.audioEncoderURL?.lastPathComponent == "CLAPAudioEncoder.mlpackage")
        #expect(
            resolved.melFilterBankURL?.lastPathComponent == "mel_filterbank_slaney_64.bin")
    }

    @Test func testUnavailableWhenAbsent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let resolved = ModelResourceLocator(searchDirectories: [dir]).resolve()

        #expect(resolved.audioEncoderURL == nil)
        #expect(resolved.melFilterBankURL == nil)
    }

    @Test func testPrefersCompiledMlmodelcOverMlpackage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeDir(dir.appendingPathComponent("CLAPAudioEncoder.mlmodelc"))
        try makeDir(dir.appendingPathComponent("CLAPAudioEncoder.mlpackage"))
        try touch(dir.appendingPathComponent("mel_filterbank_slaney_64.bin"))

        let resolved = ModelResourceLocator(searchDirectories: [dir]).resolve()

        #expect(
            resolved.audioEncoderURL?.lastPathComponent == "CLAPAudioEncoder.mlmodelc")
    }

    @Test func testFindsFilterbankInNestedCLAPSubdirectory() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeDir(dir.appendingPathComponent("CLAPAudioEncoder.mlpackage"))
        let clap = dir.appendingPathComponent("CLAP", isDirectory: true)
        try makeDir(clap)
        try touch(clap.appendingPathComponent("mel_filterbank_slaney_64.bin"))

        let resolved = ModelResourceLocator(searchDirectories: [dir]).resolve()

        #expect(
            resolved.melFilterBankURL?.lastPathComponent == "mel_filterbank_slaney_64.bin")
        #expect(resolved.melFilterBankURL?.path.contains("/CLAP/") ?? false)
    }

    // MARK: - Text encoder (session 10)

    @Test func testResolvesTextTripletWhenPresent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeDir(dir.appendingPathComponent("CLAPTextEncoder.mlpackage"))
        try touch(dir.appendingPathComponent("vocab.json"))
        try touch(dir.appendingPathComponent("merges.txt"))

        let resolved = ModelResourceLocator(searchDirectories: [dir]).resolve()

        #expect(resolved.textEncoderURL?.lastPathComponent == "CLAPTextEncoder.mlpackage")
        #expect(resolved.tokenizerVocabURL?.lastPathComponent == "vocab.json")
        #expect(resolved.tokenizerMergesURL?.lastPathComponent == "merges.txt")
    }

    @Test func testPrefersCompiledTextMlmodelcAndFindsSidecarsInNestedCLAP() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeDir(dir.appendingPathComponent("CLAPTextEncoder.mlmodelc"))
        try makeDir(dir.appendingPathComponent("CLAPTextEncoder.mlpackage"))
        let clap = dir.appendingPathComponent("CLAP", isDirectory: true)
        try makeDir(clap)
        try touch(clap.appendingPathComponent("vocab.json"))
        try touch(clap.appendingPathComponent("merges.txt"))

        let resolved = ModelResourceLocator(searchDirectories: [dir]).resolve()

        #expect(resolved.textEncoderURL?.lastPathComponent == "CLAPTextEncoder.mlmodelc")
        #expect(resolved.tokenizerVocabURL?.path.contains("/CLAP/") ?? false)
        #expect(resolved.tokenizerMergesURL?.path.contains("/CLAP/") ?? false)
    }

    /// Text encoder present but a tokenizer sidecar missing: `ModelManager`
    /// must refuse with `.resourcesUnavailable` rather than fabricate.
    @Test func testMissingTokenizerSidecarIsUnavailableToModelManager() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeDir(dir.appendingPathComponent("CLAPTextEncoder.mlpackage"))
        try touch(dir.appendingPathComponent("vocab.json"))
        // merges.txt intentionally absent

        let resolved = ModelResourceLocator(searchDirectories: [dir]).resolve()
        #expect(resolved.textEncoderURL != nil)
        #expect(resolved.tokenizerMergesURL == nil)

        let manager = ModelManager(resourceProvider: { resolved })
        let available = await manager.isTextModelResourceAvailable()
        #expect(!available)
        do {
            _ = try await manager.textEncoder(context: .foreground)
            Issue.record("expected .resourcesUnavailable with no merges.txt")
        } catch ModelManager.ModelManagerError.resourcesUnavailable {
            // expected
        }
    }

    @Test func testTextEncoderUnavailableWhenNothingResolves() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = ModelManager(
            resourceProvider: { ModelResourceLocator(searchDirectories: [dir]).resolve() })
        do {
            _ = try await manager.textEncoder(context: .foreground)
            Issue.record("expected .resourcesUnavailable")
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
    @Test func testResolvesFolderResourceViaBundleAPI() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeDir(dir.appendingPathComponent("CLAPAudioEncoder.mlmodelc"))
        try touch(dir.appendingPathComponent("mel_filterbank_slaney_64.bin"))
        let bundle = try #require(Bundle(url: dir))

        // No searchDirectories at all — if this resolves, it can only be
        // because the bundle-API path found it, not the FileManager fallback.
        let resolved = ModelResourceLocator(searchDirectories: [], bundle: bundle).resolve()

        #expect(resolved.audioEncoderURL?.lastPathComponent == "CLAPAudioEncoder.mlmodelc")
        #expect(resolved.melFilterBankURL?.lastPathComponent == "mel_filterbank_slaney_64.bin")
    }

    /// A tokenizer sidecar (no meaningful "extension" beyond its real file
    /// extension, e.g. `vocab.json`) must also resolve through the bundle
    /// API, not just folder-type `.mlmodelc` resources.
    @Test func testResolvesFileResourceWithExtensionViaBundleAPI() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try touch(dir.appendingPathComponent("vocab.json"))
        let bundle = try #require(Bundle(url: dir))

        let resolved = ModelResourceLocator(searchDirectories: [], bundle: bundle).resolve()

        #expect(resolved.tokenizerVocabURL?.lastPathComponent == "vocab.json")
    }

    /// Content nested under a subdirectory (mirrors `Resources/CLAP/` in
    /// some bundle layouts) must resolve via `Bundle.url(forResource:
    /// withExtension:subdirectory:)`, not just at the bundle root.
    @Test func testResolvesNestedSubdirectoryResourceViaBundleAPI() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clap = dir.appendingPathComponent("CLAP", isDirectory: true)
        try makeDir(clap)
        try touch(clap.appendingPathComponent("merges.txt"))
        let bundle = try #require(Bundle(url: dir))

        let resolved = ModelResourceLocator(searchDirectories: [], bundle: bundle).resolve()

        #expect(resolved.tokenizerMergesURL?.lastPathComponent == "merges.txt")
    }

    /// The bundle-API path is tried FIRST, but a plain filesystem
    /// `searchDirectories` fallback must still work when no bundle is
    /// supplied at all — the dev-checkout/test scenario every other test
    /// in this file already covers, now re-confirmed unchanged by this
    /// fix's `if let bundle` guard.
    @Test func testFallsBackToFileManagerWhenNoBundleSupplied() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeDir(dir.appendingPathComponent("CLAPAudioEncoder.mlpackage"))

        let resolved = ModelResourceLocator(searchDirectories: [dir], bundle: nil).resolve()

        #expect(resolved.audioEncoderURL?.lastPathComponent == "CLAPAudioEncoder.mlpackage")
    }

    @Test func testMissingFilterbankIsUnavailableToModelManager() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeDir(dir.appendingPathComponent("CLAPAudioEncoder.mlpackage"))

        let resolved = ModelResourceLocator(searchDirectories: [dir]).resolve()
        #expect(resolved.audioEncoderURL != nil)
        #expect(resolved.melFilterBankURL == nil)

        let manager = ModelManager(resourceProvider: { resolved })
        let available = await manager.isModelResourceAvailable()
        // Both artefacts are required, so the cheap availability check is false.
        #expect(!available)
        // And actually loading the encoder must refuse rather than fabricate.
        do {
            _ = try await manager.audioEncoder(context: .foreground)
            Issue.record("expected .resourcesUnavailable with no mel filterbank")
        } catch ModelManager.ModelManagerError.resourcesUnavailable {
            // expected
        }
    }
}
#endif
