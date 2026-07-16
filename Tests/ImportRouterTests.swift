import XCTest
@testable import TonearmCore

final class ImportRouterTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportRouterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    func testDirectoryRoutesToFolder() throws {
        let dir = tempDir.appendingPathComponent("MyFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        XCTAssertEqual(ImportRouter.route([dir]), .folder(dir))
    }

    func testAudioFilesRouteToFiles() throws {
        let a = tempDir.appendingPathComponent("a.mp3")
        let b = tempDir.appendingPathComponent("b.flac")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)

        XCTAssertEqual(ImportRouter.route([a, b]), .files([a, b]))
    }

    func testEmptyRoutesToNil() {
        XCTAssertNil(ImportRouter.route([]))
    }
}
