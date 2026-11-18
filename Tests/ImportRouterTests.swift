import Foundation
import Testing
@testable import TonearmCore

@Suite final class ImportRouterTests {

    private var tempDir: URL!

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportRouterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    @Test func testDirectoryRoutesToFolder() throws {
        let dir = tempDir.appendingPathComponent("MyFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        #expect(ImportRouter.route([dir]) == .folder(dir))
    }

    @Test func testAudioFilesRouteToFiles() throws {
        let a = tempDir.appendingPathComponent("a.mp3")
        let b = tempDir.appendingPathComponent("b.flac")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)

        #expect(ImportRouter.route([a, b]) == .files([a, b]))
    }

    @Test func testEmptyRoutesToNil() {
        #expect(ImportRouter.route([]) == nil)
    }
}
