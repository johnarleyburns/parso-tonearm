import Foundation
import Testing

/// Issue #206: `scripts/fetch-models.sh` unpacks pinned archives safely.
/// Fixtures are local archives served over file:// — no network.
@Suite struct ModelFetchScriptTests {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()

    private func sh(_ command: String, cwd: URL) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", command]
        p.currentDirectoryURL = cwd
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// A temp repo with one archive and a one-row lock; returns (repo, run).
    private func fixture(
        archiveName: String, build: String, destination: String, archiveRoot: String?,
        sha: String? = nil
    ) throws -> (URL, () throws -> (Int32, String)) {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let src = repo.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent("Config"), withIntermediateDirectories: true)
        let made = try sh(build, cwd: src)
        #expect(made.0 == 0, "\(made.1)")
        let actual = try sh("shasum -a 256 '\(archiveName)' | awk '{print $1}'", cwd: src).1
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let row = "file://\(src.path)/\(archiveName)  \(sha ?? actual)  \(destination)"
            + (archiveRoot.map { "  \($0)" } ?? "")
        try row.write(to: repo.appendingPathComponent("Config/models.lock"), atomically: true, encoding: .utf8)
        let script = root.appendingPathComponent("scripts/fetch-models.sh").path
        return (repo, { try self.sh("TONEARM_REPO_ROOT='\(repo.path)' bash '\(script)'", cwd: repo) })
    }

    private func existing(_ repo: URL, _ dir: String) throws -> URL {
        let d = repo.appendingPathComponent("Resources/Models/\(dir)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try "old".write(to: d.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        return d
    }

    private func assertOldIntact(_ d: URL, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(FileManager.default.fileExists(atPath: d.appendingPathComponent("old.txt").path),
                      sourceLocation: sourceLocation)
    }

    @Test func testZipMapsLowercaseRootToCanonicalDestination() throws {
        let (repo, run) = try fixture(
            archiveName: "m.zip", build: "mkdir r.mlpackage && echo x > r.mlpackage/a && zip -qr m.zip r.mlpackage",
            destination: "CLAPAudioEncoder.mlpackage", archiveRoot: "r.mlpackage")
        defer { try? FileManager.default.removeItem(at: repo) }
        let result = try run()
        #expect(result.0 == 0, "\(result.1)")
        #expect(FileManager.default.fileExists(
            atPath: repo.appendingPathComponent("Resources/Models/CLAPAudioEncoder.mlpackage/a").path))
        let repeatRun = try run()
        #expect(repeatRun.0 == 0, "\(repeatRun.1)")
        #expect(repeatRun.1.contains("already present"), "\(repeatRun.1)")
    }

    @Test func testThreeFieldTarGzStillWorks() throws {
        let (repo, run) = try fixture(
            archiveName: "D.tar.gz", build: "mkdir D.mlpackage && echo x > D.mlpackage/a && tar -czf D.tar.gz D.mlpackage",
            destination: "D.mlpackage", archiveRoot: nil)
        defer { try? FileManager.default.removeItem(at: repo) }
        let result = try run()
        #expect(result.0 == 0, "\(result.1)")
        #expect(FileManager.default.fileExists(
            atPath: repo.appendingPathComponent("Resources/Models/D.mlpackage/a").path))
    }

    @Test func testChecksumMismatchKeepsExistingDestination() throws {
        let (repo, run) = try fixture(
            archiveName: "m.zip", build: "mkdir r && echo x > r/a && zip -qr m.zip r",
            destination: "C.mlpackage", archiveRoot: "r", sha: String(repeating: "0", count: 64))
        defer { try? FileManager.default.removeItem(at: repo) }
        let old = try existing(repo, "C.mlpackage")
        let result = try run()
        #expect(result.0 != 0)
        assertOldIntact(old)
    }

    @Test func testWrongRootExtraRootAndUnsupportedFormatKeepExistingDestination() throws {
        let cases: [(String, String, String)] = [
            ("m.zip", "mkdir other && echo x > other/a && zip -qr m.zip other", "r"),
            ("m.zip", "mkdir r e && echo x > r/a && echo y > e/a && zip -qr m.zip r e", "r"),
            ("m.rar", "mkdir r && echo x > r/a && zip -qr m.zip r && mv m.zip m.rar", "r"),
        ]
        for (name, build, rootName) in cases {
            let (repo, run) = try fixture(
                archiveName: name, build: build, destination: "C.mlpackage", archiveRoot: rootName)
            defer { try? FileManager.default.removeItem(at: repo) }
            let old = try existing(repo, "C.mlpackage")
            // Pinned-row semantics: force replacement attempt via a stale marker.
            let result = try run()
            #expect(result.0 != 0, "\(name): \(result.1)")
            assertOldIntact(old)
        }
    }

    @Test func testTraversalArchiveIsRejectedWithoutReplacingDestination() throws {
        let (repo, run) = try fixture(
            archiveName: "m.zip",
            build: """
            python3 -I -c "import zipfile; z=zipfile.ZipFile('m.zip','w'); \
            z.writestr('r/a','x'); z.writestr('../evil','x'); z.close()"
            """,
            destination: "C.mlpackage", archiveRoot: "r")
        defer { try? FileManager.default.removeItem(at: repo) }
        let old = try existing(repo, "C.mlpackage")
        let result = try run()
        #expect(result.0 != 0)
        #expect(result.1.contains("traversal"), "\(result.1)")
        assertOldIntact(old)
        #expect(!(FileManager.default.fileExists(
            atPath: repo.appendingPathComponent("Resources/evil").path)))
    }

    @Test func testLockPinsOnlyApprovedClapPair() throws {
        let lock = try String(contentsOf: root.appendingPathComponent("Config/models.lock"), encoding: .utf8)
        #expect(lock.contains("b69c830c05cc006e380c2f7ab938c2c561721be868f3a45613982c046db93b7a"))
        #expect(lock.contains("429a248e33d03b106e4f80a7098c66fdadc022b83eee72710347629fc341fb86"))
        #expect(!(lock.contains("CLAPAudioEncoder.mlpackage.tar.gz")))
        #expect(!(lock.contains("CLAPTextEncoder.mlpackage.tar.gz")))
    }
}
