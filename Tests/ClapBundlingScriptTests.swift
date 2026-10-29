import XCTest

/// Issue #201: CLAP is bundled (no ODR tags) and a release archive fails closed
/// without it. Deterministic fixtures only — no network, no xcodegen.
final class ClapBundlingScriptTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func mkdir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func run(_ script: String, _ args: [String] = [], env: [String: String] = [:])
        throws -> (status: Int32, output: String)
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [root.appendingPathComponent(script).path] + args
        process.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func generate(models: [String], require: Bool) throws -> (Int32, String, URL) {
        let repo = try tempDir()
        for model in models { try mkdir(repo.appendingPathComponent("Resources/Models/\(model)")) }
        var env = ["TONEARM_REPO_ROOT": repo.path, "TONEARM_GENERATE_OVERLAYS_ONLY": "1"]
        env["REQUIRE_BUNDLED_CLAP"] = require ? "1" : "0"
        let result = try run("scripts/generate-project.sh", env: env)
        return (result.status, result.output, repo)
    }

    private func read(_ repo: URL, _ name: String) throws -> String {
        try String(contentsOf: repo.appendingPathComponent("Config/\(name)"), encoding: .utf8)
    }

    private let clap = ["CLAPAudioEncoder.mlpackage", "CLAPTextEncoder.mlpackage"]

    func testBundledOverlayHasCLAPEntriesWithoutResourceTags() throws {
        let (status, output, repo) = try generate(models: clap + ["DemucsStems.mlpackage"], require: true)
        XCTAssertEqual(status, 0, output)
        let bundled = try read(repo, "models-bundled.yml")
        XCTAssertTrue(bundled.contains("Resources/Models/CLAPAudioEncoder.mlpackage"))
        XCTAssertTrue(bundled.contains("Resources/Models/CLAPTextEncoder.mlpackage"))
        XCTAssertFalse(bundled.contains("resourceTags"))
        XCTAssertFalse(bundled.contains("clap-audio"))
        XCTAssertFalse(bundled.contains("demucs"))
    }

    func testOptionalOverlayContainsOnlyDemucsTag() throws {
        let (status, output, repo) = try generate(models: clap + ["DemucsStems.mlpackage"], require: false)
        XCTAssertEqual(status, 0, output)
        let odr = try read(repo, "models-odr.yml")
        XCTAssertTrue(odr.contains("- demucs-stems"))
        XCTAssertFalse(odr.contains("clap"))
        XCTAssertFalse(odr.contains("CLAP"))
    }

    func testMissingModelsWithoutRequirementIsHonestNoOp() throws {
        let (status, output, repo) = try generate(models: [], require: false)
        XCTAssertEqual(status, 0, output)
        XCTAssertTrue(try read(repo, "models-bundled.yml").contains("targets: {}"))
        XCTAssertTrue(try read(repo, "models-odr.yml").contains("targets: {}"))
    }

    func testRequireBundledCLAPFailsWhenEitherPackageMissing() throws {
        for present in [[clap[0]], [clap[1]], []] {
            let (status, output, _) = try generate(models: present, require: true)
            XCTAssertNotEqual(status, 0)
            let missing = clap.filter { !present.contains($0) }
            for name in missing {
                XCTAssertTrue(output.contains("Required bundled CLAP package missing"), output)
                XCTAssertTrue(output.contains(name), output)
            }
            XCTAssertTrue(output.contains("make models"), output)
        }
    }

    func testRequireBundledCLAPSucceedsWithBothPackages() throws {
        let (status, output, _) = try generate(models: clap, require: true)
        XCTAssertEqual(status, 0, output)
    }

    // MARK: - Archive audit

    private func makeArchive(compiled: [String], assetPacks: [String] = []) throws -> URL {
        let archive = try tempDir().appendingPathComponent("Tonearm.xcarchive")
        let app = archive.appendingPathComponent("Products/Applications/Tonearm.app")
        try mkdir(app)
        for name in compiled { try mkdir(app.appendingPathComponent("\(name).mlmodelc")) }
        for pack in assetPacks {
            try mkdir(archive.appendingPathComponent("Products/\(pack).assetpack"))
        }
        return archive
    }

    func testArchiveAuditPassesWithBothCompiledModels() throws {
        let archive = try makeArchive(compiled: ["CLAPAudioEncoder", "CLAPTextEncoder"])
        let result = try run("scripts/audit-clap-archive.sh", [archive.path])
        XCTAssertEqual(result.status, 0, result.output)
    }

    func testArchiveAuditFailsWhenCompiledModelAbsent() throws {
        for present in [["CLAPAudioEncoder"], ["CLAPTextEncoder"], []] {
            let archive = try makeArchive(compiled: present)
            XCTAssertNotEqual(try run("scripts/audit-clap-archive.sh", [archive.path]).status, 0)
        }
    }

    func testArchiveAuditFailsWhenCLAPOnlyInAssetPack() throws {
        let archive = try makeArchive(compiled: [], assetPacks: ["guru.parso.tonearm.clap-audio-abc", "guru.parso.tonearm.clap-text-abc"])
        XCTAssertNotEqual(try run("scripts/audit-clap-archive.sh", [archive.path]).status, 0)
    }

    func testArchiveAuditFailsWhenAssetPackAlsoPresent() throws {
        let archive = try makeArchive(
            compiled: ["CLAPAudioEncoder", "CLAPTextEncoder"], assetPacks: ["guru.parso.tonearm.clap-text-abc"])
        let result = try run("scripts/audit-clap-archive.sh", [archive.path])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("bundled, not an ODR asset pack"))
    }
}
