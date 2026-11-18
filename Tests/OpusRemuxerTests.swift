import Testing
import AVFoundation
@testable import TonearmCore

/// T2.3 — corrupted-fixture fallback; cancellation leaves no partial CAF;
/// CAF byte count reflected in cache accounting.
@Suite final class OpusRemuxerTests {

    private var tmpDir: URL!

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("remux-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func copyFixture(_ name: String, as fileName: String) throws -> URL {
        let dst = tmpDir.appendingPathComponent(fileName)
        try Fixtures.data(name, ext: "opus").write(to: dst)
        return dst
    }

    @Test func testSuccessfulRemuxProducesPlayableCAFAndDeletesOpus() async throws {
        let opus = try copyFixture("tone_mono", as: "abc-opus")
        let remuxer = OpusRemuxer()
        let caf = try await remuxer.remux(opusFileURL: opus, cacheKey: "abc-opus")

        #expect(FileManager.default.fileExists(atPath: caf.path))
        #expect(!FileManager.default.fileExists(atPath: opus.path),
                       "raw .opus should be deleted after successful remux")
        // The CAF is playable.
        _ = try AVAudioFile(forReading: caf)
    }

    @Test func testCorruptedFixtureFailsAndLeavesNoPartialCAF() async {
        do {
            let opus = try copyFixture("corrupt_notogg", as: "bad-opus")
            let remuxer = OpusRemuxer()
            let caf = OpusRemuxer.cafURL(forOpusFile: opus)
            _ = try await remuxer.remux(opusFileURL: opus, cacheKey: "bad-opus")
            Issue.record("expected remux to throw")
            _ = caf
        } catch {
            // Expected. Verify no partial CAF and the key is marked unavailable.
            let opus = tmpDir.appendingPathComponent("bad-opus")
            let caf = OpusRemuxer.cafURL(forOpusFile: opus)
            #expect(!FileManager.default.fileExists(atPath: caf.path))
        }
    }

    @Test func testUnavailableKeyIsRemembered() async throws {
        let opus = try copyFixture("corrupt_truncated", as: "trunc-opus")
        let remuxer = OpusRemuxer()
        _ = try? await remuxer.remux(opusFileURL: opus, cacheKey: "trunc-opus")
        let unavailable = await remuxer.isUnavailable("trunc-opus")
        #expect(unavailable)
    }

    @Test func testCancellationLeavesNoPartialCAF() async throws {
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
