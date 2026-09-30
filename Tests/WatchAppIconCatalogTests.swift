import Foundation
import XCTest

final class WatchAppIconCatalogTests: XCTestCase {
    /*
     GUARD — do not delete or weaken this test.

     The TonearmWatch icon is the watchOS circle (Icon Composer's 1088 canvas)
     of the shared Resources/AppIcon.icon, compiled with WatchApp/Assets.xcassets.
     If the .icon stops declaring watchOS, or a second icon named AppIcon comes
     back as WatchApp/Assets.xcassets/AppIcon.appiconset, Xcode eventually fails
     with:

       The stickers icon set, app icon set, or icon stack named "AppIcon"
       did not have any applicable content.

     or archive export fails with a missing CFBundleIconName. The fix is to
     re-enable watchOS for AppIcon.icon in Icon Composer, keep it in the
     TonearmWatch sources in project.yml, run
     `bash scripts/verify-watch-icon-catalog.sh`, and build with destinations:
       xcodebuild ... -scheme Tonearm -destination 'generic/platform=iOS Simulator'
       xcodebuild ... -scheme TonearmWatch -destination 'generic/platform=watchOS Simulator'
     Never use `-sdk iphonesimulator` on the multi-platform Tonearm scheme.
     */
    func testWatchAppIconIsWatchOSValid() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let icon = repositoryRoot.appendingPathComponent("Resources/AppIcon.icon")
        let fileManager = FileManager.default

        XCTAssertFalse(
            fileManager.fileExists(atPath: repositoryRoot
                .appendingPathComponent("WatchApp/Assets.xcassets/AppIcon.appiconset").path),
            "WATCH APPICON GUARD FAILED: WatchApp/Assets.xcassets/AppIcon.appiconset exists. The Watch icon comes from Resources/AppIcon.icon; two icons named AppIcon clash. Delete the appiconset and run bash scripts/verify-watch-icon-catalog.sh.")

        let manifestURL = icon.appendingPathComponent("icon.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            XCTFail("WATCH APPICON GUARD FAILED: Resources/AppIcon.icon/icon.json is missing. Restore the Icon Composer file and run bash scripts/verify-watch-icon-catalog.sh.")
            return
        }
        let manifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any],
            "WATCH APPICON GUARD FAILED: AppIcon.icon/icon.json is not a JSON object. Re-save it from Icon Composer.")
        let platforms = manifest["supported-platforms"] as? [String: Any]
        XCTAssertTrue(
            (platforms?["circles"] as? [String] ?? []).contains("watchOS"),
            "WATCH APPICON GUARD FAILED: AppIcon.icon does not declare the watchOS circle. Enable watchOS in Icon Composer and re-save.")

        let project = try String(
            contentsOf: repositoryRoot.appendingPathComponent("project.yml"), encoding: .utf8)
        let watchTarget = project.components(separatedBy: "\n  TonearmWatch:\n").dropFirst().first?
            .components(separatedBy: "\n  Tonearm").first ?? ""
        XCTAssertTrue(
            watchTarget.contains("path: Resources/AppIcon.icon"),
            "WATCH APPICON GUARD FAILED: project.yml no longer lists Resources/AppIcon.icon in the TonearmWatch sources. Add it back and run make project.")

        #if os(macOS)
        try assertActoolCompilesWatchOSIcon(
            inputs: [
                repositoryRoot.appendingPathComponent("WatchApp/Assets.xcassets"),
                icon,
            ])
        #endif
    }

    #if os(macOS)
    private func assertActoolCompilesWatchOSIcon(inputs: [URL]) throws {
        let fileManager = FileManager.default
        let output = fileManager.temporaryDirectory
            .appendingPathComponent("tonearm-watch-icon-test-\(UUID().uuidString)")
        try fileManager.createDirectory(
            at: output.appendingPathComponent("compiled"),
            withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: output) }
        let partialPlist = output.appendingPathComponent("asset-info.plist")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["actool"] + inputs.map(\.path) + [
            "--compile", output.appendingPathComponent("compiled").path,
            "--output-format", "human-readable-text",
            "--notices",
            "--warnings",
            "--output-partial-info-plist", partialPlist.path,
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
        let outputText = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "<no actool output>"
        process.waitUntilExit()

        XCTAssertEqual(
            process.terminationStatus,
            0,
            "WATCH APPICON GUARD FAILED: watchOS actool rejected the Watch icon inputs. Fix: keep Resources/AppIcon.icon valid with watchOS enabled, run bash scripts/verify-watch-icon-catalog.sh, and use destination-based builds instead of -sdk iphonesimulator. actool output:\n\(outputText)")

        let plist = (try? PropertyListSerialization.propertyList(
            from: Data(contentsOf: partialPlist), format: nil)) as? [String: Any]
        let primary = (plist?["CFBundleIcons"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any]
        XCTAssertEqual(
            primary?["CFBundleIconName"] as? String,
            "AppIcon",
            "WATCH APPICON GUARD FAILED: watchOS actool did not write CFBundleIconName=AppIcon, so archive export would fail with a missing Watch icon. Enable watchOS for Resources/AppIcon.icon in Icon Composer.")
    }
    #endif
}
