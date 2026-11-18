#if !os(watchOS) && canImport(CoreML)
import Foundation
import Testing

@testable import TonearmDiscovery

@Suite struct CompiledModelCacheTests {
    @Test func testMlmodelcPassesThroughUnchanged() throws {
        let url = URL(fileURLWithPath: "/tmp/SomeModel.mlmodelc")
        #expect(try CompiledModelCache.loadableURL(for: url) == url)
    }

    @Test func testNonModelURLPassesThroughUnchanged() throws {
        let url = URL(fileURLWithPath: "/tmp/mel_filterbank_slaney_64.bin")
        #expect(try CompiledModelCache.loadableURL(for: url) == url)
    }

    /// An `.mlpackage` that isn't a real, valid Core ML package fails to compile — the error must
    /// surface as `CacheError.compileFailed`, never a crash and never a silently-returned bogus URL.
    @Test func testAnInvalidPackageSurfacesACompileFailure() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompiledModelCacheTests-\(UUID().uuidString)")
            .appendingPathComponent("NotAModel.mlpackage")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not a real model".utf8).write(to: dir.appendingPathComponent("junk.txt"))
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

        do {
            _ = try CompiledModelCache.loadableURL(for: dir)
            Issue.record("expected loadableURL(for:) to throw")
        } catch {
            guard case CompiledModelCache.CacheError.compileFailed = error else {
                return Issue.record("expected .compileFailed, got \(error)")
            }
        }
    }

    /// Real-resource gated (C04/C08, mirrors `ModelManagerRealLoadSmokeTests`): compiling the real
    /// converted `CLAPAudioEncoder` package twice must return the same cached `.mlmodelc` both
    /// times, proving the second call reuses the cache instead of recompiling a ~130 MB package.
    @Test func testRealPackageCompilesOnceAndIsReusedOrSkips() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let packageURL = repoRoot.appendingPathComponent("Resources/Models/CLAPAudioEncoder.mlpackage")
        if !(FileManager.default.fileExists(atPath: packageURL.path)) {
            try Test.cancel("converted CLAP audio package not on this host — run `make models`")
        }

        let first = try CompiledModelCache.loadableURL(for: packageURL)
        #expect(first.pathExtension == "mlmodelc")
        #expect(FileManager.default.fileExists(atPath: first.path))

        let second = try CompiledModelCache.loadableURL(for: packageURL)
        #expect(first == second, "a second resolve must reuse the cached compile, not produce a new one")
    }
}
#endif
