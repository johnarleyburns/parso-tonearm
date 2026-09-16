#if !os(watchOS) && canImport(CoreML)
import XCTest

@testable import TonearmDiscovery

final class CompiledModelCacheTests: XCTestCase {
    func testMlmodelcPassesThroughUnchanged() throws {
        let url = URL(fileURLWithPath: "/tmp/SomeModel.mlmodelc")
        XCTAssertEqual(try CompiledModelCache.loadableURL(for: url), url)
    }

    func testNonModelURLPassesThroughUnchanged() throws {
        let url = URL(fileURLWithPath: "/tmp/mel_filterbank_slaney_64.bin")
        XCTAssertEqual(try CompiledModelCache.loadableURL(for: url), url)
    }

    /// An `.mlpackage` that isn't a real, valid Core ML package fails to compile — the error must
    /// surface as `CacheError.compileFailed`, never a crash and never a silently-returned bogus URL.
    func testAnInvalidPackageSurfacesACompileFailure() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompiledModelCacheTests-\(UUID().uuidString)")
            .appendingPathComponent("NotAModel.mlpackage")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not a real model".utf8).write(to: dir.appendingPathComponent("junk.txt"))
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

        XCTAssertThrowsError(try CompiledModelCache.loadableURL(for: dir)) { error in
            guard case CompiledModelCache.CacheError.compileFailed = error else {
                return XCTFail("expected .compileFailed, got \(error)")
            }
        }
    }

    /// Real-resource gated (C04/C08, mirrors `ModelManagerRealLoadSmokeTests`): compiling the real
    /// converted `CLAPAudioEncoder` package twice must return the same cached `.mlmodelc` both
    /// times, proving the second call reuses the cache instead of recompiling a ~130 MB package.
    func testRealPackageCompilesOnceAndIsReusedOrSkips() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let packageURL = repoRoot.appendingPathComponent("Resources/Models/CLAPAudioEncoder.mlpackage")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: packageURL.path),
                          "converted CLAP audio package not on this host — run `make models`")

        let first = try CompiledModelCache.loadableURL(for: packageURL)
        XCTAssertEqual(first.pathExtension, "mlmodelc")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))

        let second = try CompiledModelCache.loadableURL(for: packageURL)
        XCTAssertEqual(first, second, "a second resolve must reuse the cached compile, not produce a new one")
    }
}
#endif
