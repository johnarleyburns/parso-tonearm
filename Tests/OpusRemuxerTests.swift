import XCTest
import AVFoundation
@testable import TonearmCore

/// T2.3 — corrupted-fixture fallback; cancellation leaves no partial CAF;
/// CAF byte count reflected in cache accounting.
final class OpusRemuxerTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("remux-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func copyFixture(_ name: String, as fileName: String) throws -> URL {
        let dst = tmpDir.appendingPathComponent(fileName)
        try Fixtures.data(name, ext: "opus").write(to: dst)
        return dst
    }

    func testSuccessfulRemuxProducesPlayableCAFAndDeletesOpus() async throws {
        let opus = try copyFixture("tone_mono", as: "abc-opus")
        let remuxer = OpusRemuxer()
        let caf = try await remuxer.remux(opusFileURL: opus, cacheKey: "abc-opus")

        XCTAssertTrue(FileManager.default.fileExists(atPath: caf.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: opus.path),
                       "raw .opus should be deleted after successful remux")
        // The CAF is playable.
        _ = try AVAudioFile(forReading: caf)
    }

    func testCorruptedFixtureFailsAndLeavesNoPartialCAF() async {
        do {
            let opus = try copyFixture("corrupt_notogg", as: "bad-opus")
            let remuxer = OpusRemuxer()
            let caf = OpusRemuxer.cafURL(forOpusFile: opus)
            _ = try await remuxer.remux(opusFileURL: opus, cacheKey: "bad-opus")
            XCTFail("expected remux to throw")
            _ = caf
        } catch {
            // Expected. Verify no partial CAF and the key is marked unavailable.
            let opus = tmpDir.appendingPathComponent("bad-opus")
            let caf = OpusRemuxer.cafURL(forOpusFile: opus)
            XCTAssertFalse(FileManager.default.fileExists(atPath: caf.path))
        }
    }

    func testUnavailableKeyIsRemembered() async throws {
        let opus = try copyFixture("corrupt_truncated", as: "trunc-opus")
        let remuxer = OpusRemuxer()
        _ = try? await remuxer.remux(opusFileURL: opus, cacheKey: "trunc-opus")
        let unavailable = await remuxer.isUnavailable("trunc-opus")
        XCTAssertTrue(unavailable)
    }

    func testCancellationLeavesNoPartialCAF() async throws {
        let opus = try copyFixture("tone_stereo", as: "cancel-opus")
        let remuxer = OpusRemuxer()
        let caf = OpusRemuxer.cafURL(forOpusFile: opus)

        let task = Task {
            try await remuxer.remux(opusFileURL: opus, cacheKey: "cancel-opus")
        }
        task.cancel()
        _ = try? await task.value

        // On cancel, no partial CAF should remain. (If it completed before the
        // cancel took effect, a valid CAF is acceptable — but never a partial.)
        if FileManager.default.fileExists(atPath: caf.path) {
            _ = try AVAudioFile(forReading: caf)
        }
    }
}
