import Foundation
import XCTest

final class WatchAppIconCatalogTests: XCTestCase {
    /*
     GUARD — do not delete or weaken this test.

     WatchApp/Assets.xcassets belongs to the TonearmWatch watchOS target. If
     its AppIcon set is changed to iOS/universal content, or a referenced PNG
     is removed, Xcode eventually fails with:

       The stickers icon set, app icon set, or icon stack named "AppIcon"
       did not have any applicable content.

     The fix is to keep the catalog watchOS-specific, run
     `bash scripts/verify-watch-icon-catalog.sh`, and build with destinations:
       xcodebuild ... -scheme Tonearm -destination 'generic/platform=iOS Simulator'
       xcodebuild ... -scheme TonearmWatch -destination 'generic/platform=watchOS Simulator'
     Never silence this by adding iOS idioms to the Watch catalog or by using
     `-sdk iphonesimulator` on the multi-platform Tonearm scheme.
     */
    func testWatchAppIconCatalogIsWatchOSValid() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let iconSet = repositoryRoot
            .appendingPathComponent("WatchApp/Assets.xcassets/AppIcon.appiconset")
        let contentsURL = iconSet.appendingPathComponent("Contents.json")
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: contentsURL.path) else {
            XCTFail("WATCH APPICON GUARD FAILED: WatchApp/Assets.xcassets/AppIcon.appiconset/Contents.json is missing. Restore the watchOS AppIcon catalog and run bash scripts/verify-watch-icon-catalog.sh.")
            return
        }

        let contents = try Data(contentsOf: contentsURL)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: contents) as? [String: Any],
            "WATCH APPICON GUARD FAILED: Contents.json is not a JSON object. Restore valid Xcode asset-catalog JSON, then run bash scripts/verify-watch-icon-catalog.sh.")
        let images = try XCTUnwrap(
            object["images"] as? [[String: Any]],
            "WATCH APPICON GUARD FAILED: Contents.json has no images array. Keep the complete watchOS AppIcon entries and run bash scripts/verify-watch-icon-catalog.sh.")

        XCTAssertTrue(
            images.contains { $0["idiom"] as? String == "watch-marketing" },
            "WATCH APPICON GUARD FAILED: the catalog has no watch-marketing icon. Keep the 1024x1024 watchOS marketing icon; do not replace it with an iOS/universal entry.")
        XCTAssertTrue(
            images.contains { $0["idiom"] as? String == "watch" },
            "WATCH APPICON GUARD FAILED: the catalog has no watch icon entries. Keep the watch launcher, notification, settings, and Quick Look entries.")

        for image in images {
            let idiom = image["idiom"] as? String ?? "<missing>"
            XCTAssertTrue(
                idiom == "watch" || idiom == "watch-marketing",
                "WATCH APPICON GUARD FAILED: AppIcon contains '$idiom' content. This catalog is watchOS-only; remove iOS/universal entries and run bash scripts/verify-watch-icon-catalog.sh.")

            guard let filename = image["filename"] as? String else {
                XCTFail("WATCH APPICON GUARD FAILED: a watch AppIcon entry has no filename. Restore the referenced PNG and run bash scripts/verify-watch-icon-catalog.sh.")
                continue
            }
            XCTAssertTrue(
                fileManager.fileExists(atPath: iconSet.appendingPathComponent(filename).path),
                "WATCH APPICON GUARD FAILED: '$filename' is referenced by Contents.json but is missing. Restore that PNG or remove its complete catalog entry, then run bash scripts/verify-watch-icon-catalog.sh.")
        }

        #if os(macOS)
        try assertActoolCompilesWatchOSCatalog(
            iconCatalog: repositoryRoot.appendingPathComponent("WatchApp/Assets.xcassets"))
        #endif
    }

    #if os(macOS)
    private func assertActoolCompilesWatchOSCatalog(iconCatalog: URL) throws {
        let fileManager = FileManager.default
        let output = fileManager.temporaryDirectory
            .appendingPathComponent("tonearm-watch-icon-test-\(UUID().uuidString)")
        try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: output.appendingPathComponent("compiled"),
            withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: output) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "actool", iconCatalog.path,
            "--compile", output.appendingPathComponent("compiled").path,
            "--output-format", "human-readable-text",
            "--notices",
            "--warnings",
            "--output-partial-info-plist", output.appendingPathComponent("asset-info.plist").path,
            "--app-icon", "AppIcon",
            "--compress-pngs",
            "--enable-on-demand-resources", "YES",
            "--development-region", "en",
            "--target-device", "watch",
            "--minimum-deployment-target", "11.0",
            "--platform", "watchos"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            XCTFail("WATCH APPICON GUARD FAILED: could not run watchOS actool (\(error)). Install/select Xcode, then run bash scripts/verify-watch-icon-catalog.sh.")
            return
        }
        process.waitUntilExit()

        let outputText = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "<no actool output>"
        XCTAssertEqual(
            process.terminationStatus,
            0,
            "WATCH APPICON GUARD FAILED: watchOS actool rejected the catalog. Why: the Watch AppIcon has no applicable watchOS content or references invalid assets. Fix: keep WatchApp/Assets.xcassets/AppIcon.appiconset watchOS-only, restore every referenced PNG, run bash scripts/verify-watch-icon-catalog.sh, and use destination-based builds instead of -sdk iphonesimulator. actool output:\n\(outputText)")
    }
    #endif
}
